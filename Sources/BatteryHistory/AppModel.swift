import AppKit
import SwiftUI
import ServiceManagement
import IOKit.ps
import BatteryHistoryCore

@MainActor
final class AppModel: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppModel()
    @Published var current: BatteryReading?
    @Published var rate: Double?
    @Published var storageError: String?
    @Published var loginError: String?
    @Published var backfillStatus = "Waiting to check system history"
    @Published var ready = false
    @Published var revision = 0
    @Published var historyVisible = false
    @Published var loginStatus = SMAppService.mainApp.status
    let preview = CommandLine.arguments.contains("--preview")

    private(set) var store: HistoryStore?
    private var session = UUID()
    private var timer: Timer?
    private var checkpointTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var stopping = false
    private var writes: Task<Void, Never>?
    private var historyWindow: NSWindow?
    private var startup: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?

    var statusText: String {
        if let current { return "\(Int(current.percent.rounded()))% · \(current.state.label)" }
        return ready ? "No internal battery found" : "Starting…"
    }

    func start() {
        guard timer == nil else { return }
        let cutoff = Date()
        startup = Task {
            do {
                let url = preview ? FileManager.default.temporaryDirectory
                    .appendingPathComponent("BatteryHistoryPreview-\(UUID())/history.duckdb") : HistoryStore.defaultURL
                store = try await Task.detached { try HistoryStore(url: url) }.value
                if preview, let store {
                    let now = Date(), previewSession = UUID()
                    let demo = (0..<1440).compactMap { minute -> BatteryReading? in
                        // Leave an overnight gap and a short gap in the afternoon.
                        if (180..<480).contains(minute) || (1010..<1040).contains(minute) { return nil }
                        let state: PowerState
                        let percent: Double
                        switch minute {
                        case 0..<180: state = .battery; percent = 93 - Double(minute) * 0.10
                        case 480..<720: state = .battery; percent = 70 - Double(minute - 480) * 0.15
                        case 720..<900: state = .charging; percent = min(100, 34 + Double(minute - 720) * 0.4)
                        case 900..<1080: state = .pluggedIn; percent = 100
                        default: state = .battery; percent = 100 - Double(minute - 1080) * 0.12
                        }
                        return BatteryReading(timestamp: now.addingTimeInterval(Double(minute - 1440) * 60),
                            percent: percent, state: state, session: previewSession)
                    }
                    try await store.append(demo)
                    current = demo.last
                    rate = HistoryAnalysis.rate(Array(demo.suffix(31)))
                    revision += 1
                    openHistory()
                }
            } catch {
                storageError = error.localizedDescription
            }
            ready = true
            if !preview, !stopping {
                collect()
                if let store { startBackfill(store: store, cutoff: cutoff) }
            }
        }
        if preview { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collect() }
        }
        timer?.tolerance = 5
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                self.enqueue { try await store.checkpoint() }
            }
        }
        checkpointTimer?.tolerance = 60
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in model.collect() }
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        let notifications = NSWorkspace.shared.notificationCenter
        observers.append(notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.suspended = true
                self.endSession(reason: "sleep")
            }
        })
        observers.append(notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.session = UUID()
                self.suspended = false
                self.collect()
            }
        })
        if !UserDefaults.standard.bool(forKey: "didConfigureLogin") {
            setLaunchAtLogin(true)
            UserDefaults.standard.set(true, forKey: "didConfigureLogin")
        }
    }

    private func startBackfill(store: HistoryStore, cutoff: Date) {
        backfillStatus = "Checking system history…"
        backfillTask = Task {
            let reader = Task.detached(priority: .utility) {
                try PowerlogSource.read(before: cutoff)
            }
            do {
                let samples = try await withTaskCancellationHandler {
                    try await reader.value
                } onCancel: {
                    reader.cancel()
                }
                try Task.checkCancellation()
                let count = try await store.backfill(samples, before: cutoff)
                backfillStatus = count == 0 ? "No missing system readings to import" : "Imported \(count) system readings"
                if count > 0 { revision += 1 }
            } catch is CancellationError {
                backfillStatus = "System history check cancelled"
            } catch {
                backfillStatus = error.localizedDescription
            }
        }
    }

    func collect() {
        guard ready, !suspended, !stopping else { return }
        let reading = BatterySource.read(session: session)
        if reading == nil, current != nil {
            endSession(reason: "battery unavailable")
            session = UUID()
        }
        current = reading
        guard let reading, let store else { rate = nil; return }
        enqueue { [weak self] in
            try await store.append(reading)
            let recent = try await store.readings(from: reading.timestamp.addingTimeInterval(-1800), to: reading.timestamp)
            self?.rate = HistoryAnalysis.rate(recent)
            self?.revision += 1
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = writes
        writes = Task { [weak self] in
            await previous?.value
            do {
                try await operation()
                self?.storageError = nil
            } catch {
                self?.storageError = error.localizedDescription
            }
        }
    }

    private func endSession(reason: String) {
        guard let store else { return }
        let session = session, now = Date()
        enqueue { try await store.endSession(session, at: now, reason: reason) }
    }

    func stop() async {
        stopping = true
        timer?.invalidate()
        checkpointTimer?.invalidate()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        await startup?.value
        backfillTask?.cancel()
        await backfillTask?.value
        endSession(reason: "quit")
        await writes?.value
        if let store { try? await store.checkpoint() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }

    func openHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Battery History"
            window.minSize = NSSize(width: 720, height: 540)
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.delegate = self
            window.contentView = NSHostingView(rootView: HistoryView(model: self))
            window.center()
            historyWindow = window
        }
        guard let window = historyWindow else { return }
        // Re-order the retained window when it is visible on another Space so
        // moveToActiveSpace applies to this summon without switching desktops.
        if !window.isOnActiveSpace { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        historyVisible = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { historyVisible = false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task {
            await AppModel.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
