import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

struct ShelfActions {
    var paste: ([Clip], Bool) -> Void
    var copy: ([Clip], Bool) -> Void
    var enqueue: ([Clip]) -> Void
    var settings: () -> Void
    var pauseToggle: () -> Void
    var stackToggle: () -> Void
    var clear: () -> Void
    var export: () -> Void
    var `import`: () -> Void
    var quit: () -> Void
    var isPaused: () -> Bool
    var isStack: () -> Bool
    var targetName: () -> String
    var invalidatePendingPaste: () -> Void
    var restoreTargetFocus: () -> Void = {}
    var reportError: (String) -> Void = { _ in NSSound.beep() }
}

struct PrismHotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    var display: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + label
    }
    var cocoaFlags: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }
    static let shelf = PrismHotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), label: "V")
    static let stack = PrismHotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey), label: "C")
}

final class PrismPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["historyDays": 30, "historyLimit": 1000, "diskLimitMB": 512, "automaticPaste": true, "excludedApplications": "", "capturePaused": false, "showMenuBar": true, "soundEffects": false, "alwaysPlainText": false])
    }
    var days: Int { get { defaults.integer(forKey: "historyDays") } set { defaults.set(newValue, forKey: "historyDays") } }
    var limit: Int { get { defaults.integer(forKey: "historyLimit") } set { defaults.set(max(0, newValue), forKey: "historyLimit") } }
    var diskMB: Int { get { defaults.integer(forKey: "diskLimitMB") } set { defaults.set(max(0, newValue), forKey: "diskLimitMB") } }
    var automaticPaste: Bool { get { defaults.bool(forKey: "automaticPaste") } set { defaults.set(newValue, forKey: "automaticPaste") } }
    var excluded: String { get { defaults.string(forKey: "excludedApplications") ?? "" } set { defaults.set(newValue, forKey: "excludedApplications") } }
    var paused: Bool { get { defaults.bool(forKey: "capturePaused") } set { defaults.set(newValue, forKey: "capturePaused") } }
    var showMenuBar: Bool { get { defaults.bool(forKey: "showMenuBar") } set { defaults.set(newValue, forKey: "showMenuBar") } }
    var soundEffects: Bool { get { defaults.bool(forKey: "soundEffects") } set { defaults.set(newValue, forKey: "soundEffects") } }
    var alwaysPlainText: Bool { get { defaults.bool(forKey: "alwaysPlainText") } set { defaults.set(newValue, forKey: "alwaysPlainText") } }
    var appearance: PrismAppearanceSettings {
        get { PrismAppearanceSettings.load(from: defaults) }
        set {
            guard newValue != appearance else { return }
            newValue.save(to: defaults)
            NotificationCenter.default.post(name: .prismAppearanceDidChange, object: self)
        }
    }
    func hotkey(_ id: UInt32) -> PrismHotkey {
        let base = id == 1 ? PrismHotkey.shelf : .stack
        let prefix = "hotkey\(id)"
        guard defaults.object(forKey: prefix + "Code") != nil else { return base }
        return PrismHotkey(keyCode: UInt32(defaults.integer(forKey: prefix + "Code")), modifiers: UInt32(defaults.integer(forKey: prefix + "Modifiers")), label: defaults.string(forKey: prefix + "Label") ?? base.label)
    }
    func setHotkey(_ value: PrismHotkey, id: UInt32) {
        let prefix = "hotkey\(id)"
        defaults.set(Int(value.keyCode), forKey: prefix + "Code"); defaults.set(Int(value.modifiers), forKey: prefix + "Modifiers"); defaults.set(value.label, forKey: prefix + "Label")
    }
    func excludes(bundle: String, name: String) -> Bool {
        let values = excluded.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        return values.contains { value in
            if value.hasSuffix(".*") { return bundle.lowercased().hasPrefix(String(value.dropLast())) }
            return bundle.lowercased() == value || name.lowercased() == value
        }
    }
}

@main
struct PrismApplication {
    static func main() {
        if CommandLine.arguments.contains("--diagnostics") {
            let bundle = Bundle.main
            let diagnostics: [String: Any] = [
                "accessibilityTrusted": AXIsProcessTrusted(),
                "postEventAccess": CGPreflightPostEventAccess(),
                "bundlePath": bundle.bundleURL.path,
                "bundleIdentifier": bundle.bundleIdentifier as Any? ?? NSNull(),
                "automaticPaste": UserDefaults.standard.object(forKey: "automaticPaste") as? Bool ?? true,
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0a]))
            } catch {
                fputs("Unable to encode Prism diagnostics.\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--self-test") { exit(runSelfTests()) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = PrismAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class PrismAppDelegate: NSObject, NSApplicationDelegate {
    let preferences: PrismPreferences
    let store: ClipStore
    private let isDemo: Bool
    private var shelf: ShelfController!
    private var settingsController: PrismSettingsController?
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var lastChangeCount = 0
    private var observedApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var targetApp: NSRunningApplication?
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyHandler: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private struct StackEntry {
        let id: UUID
        var snapshot: Clip?
    }
    private var stackQueue: [StackEntry] = []
    private var stackCollecting = true
    private var stackFlushScheduled = false
    private var copyProbeGeneration: UInt64 = 0
    private var stackEnabled = false
    private var stackBusy = false
    private var stackTransferPending = false
    private var stackShortcutHeld = false
    private var stackSession: UInt64 = 0
    private var stackAwaitingPaste: NSRunningApplication?
    private var stackWaitGeneration: UInt64 = 0
    private var stackConsumedInStroke = false
    private var refreshScheduled = false
    private var pendingPasteGeneration: UInt64 = 0
    private var automaticPastePending = false
    private var toastPanel: NSPanel?
    private var toastGeneration: UInt64 = 0
    private var maintenanceTicks = 0
    private var archiveBusy = false
    private let archiveQueue = DispatchQueue(label: "local.prism.archive", qos: .utility)
    private let captureQueue = DispatchQueue(label: "local.prism.clipboard.capture", qos: .utility)
    private var capturesInFlight = 0
    private var captureBytesInFlight = 0
    private var captureInFlight: Bool { capturesInFlight > 0 }
    private let transientByteBudget = 128 * 1024 * 1024
    private var pendingCapture: CaptureRequest?
    private var captureGeneration: UInt64 = 0
    private struct CaptureRequest {
        let count: Int
        let app: NSRunningApplication
        let source: String
        let bundle: String
        let generation: UInt64
        let stackSession: UInt64?
    }
    private let injectedEventTag: Int64 = 0x505249534D
    private let passwordApplications = ["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.", "com.agilebits.", "com.bitwarden.", "com.dashlane.", "com.lastpass.", "de.kykeepass.", "com.keepass", "org.keepass", "com.strongbox", "com.enpass.", "in.sinew.Enpass", "me.proton.pass", "com.nordpass"]

    override init() {
        isDemo = CommandLine.arguments.contains("--demo")
        let defaults = isDemo ? UserDefaults(suiteName: "local.prism.clipboard.demo")! : .standard
        preferences = PrismPreferences(defaults: defaults)
        let demoDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Prism-Demo-Store", isDirectory: true)
        store = ClipStore(directory: isDemo ? demoDirectory : nil)
        super.init()
        if isDemo { preferences.paused = true }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        observedApp = NSWorkspace.shared.frontmostApplication
        if observedApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { observedApp = nil }
        lastExternalApp = observedApp
        let actions = ShelfActions(
            paste: { [weak self] in self?.paste($0, plainText: $1) },
            copy: { [weak self] clips, plain in
                guard let self else { return }
                self.writeClipboard(clips, plainText: plain)
            },
            enqueue: { [weak self] in self?.enqueue($0) },
            settings: { [weak self] in self?.showSettings() },
            pauseToggle: { [weak self] in self?.togglePause() },
            stackToggle: { [weak self] in self?.toggleStack() },
            clear: { [weak self] in self?.clearHistory() },
            export: { [weak self] in self?.exportArchive() },
            import: { [weak self] in self?.importArchive() },
            quit: { NSApp.terminate(nil) },
            isPaused: { [weak self] in self?.preferences.paused ?? false },
            isStack: { [weak self] in self?.stackEnabled ?? false },
            targetName: { [weak self] in
                guard let self else { return "原应用" }
                return self.preferences.automaticPaste ? (self.targetApp?.localizedName ?? "原应用") : "剪贴板"
            },
            invalidatePendingPaste: { [weak self] in
                self?.pendingPasteGeneration &+= 1
                self?.automaticPastePending = false
            },
            restoreTargetFocus: { [weak self] in
                guard let self, self.isOwn(NSWorkspace.shared.frontmostApplication),
                      let target = self.targetApp, !target.isTerminated, !self.isOwn(target) else { return }
                NSApp.yieldActivation(to: target)
                target.activate(options: [])
            },
            reportError: { [weak self] in self?.toast($0) }
        )
        shelf = ShelfController(store: store, actions: actions, appearanceProvider: { [weak self] in
            self?.preferences.appearance ?? .default
        })
        store.onChange = { [weak self] in self?.scheduleShelfRefresh() }
        store.onError = { [weak self] in self?.toast($0) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatus()
        if isDemo {
            if store.clips.isEmpty { makeDemoClips().reversed().forEach { store.add($0) } }
            DispatchQueue.main.async { [weak self] in self?.shelf.present() }
            return
        }
        lastChangeCount = NSPasteboard.general.changeCount
        registerHotKeys()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            // Old copy probes may never label a new foreground application's data.
            self.copyProbeGeneration &+= 1
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.observedApp = app
            if let app, !self.isOwn(app) { self.lastExternalApp = app }
            self.pollClipboard(source: app)
        }
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.pollClipboard()
            guard let self else { return }
            self.maintenanceTicks += 1
            if self.maintenanceTicks % 134 == 0 { self.enforceLimits() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        enforceLimits()
        if !UserDefaults.standard.bool(forKey: "PrismHasLaunched") {
            UserDefaults.standard.set(true, forKey: "PrismHasLaunched")
            DispatchQueue.main.async { [weak self] in self?.toggleShelf() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.flush() else {
            alert("记录尚未保存，Prism 暂未退出", store.lastError ?? "请检查磁盘空间与文件夹访问权限，然后再次退出。")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingPasteGeneration &+= 1
        timer?.invalidate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        hotKeys.values.forEach { UnregisterEventHotKey($0) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        removeEventTap()
        store.flush()
    }

    private func isOwn(_ app: NSRunningApplication?) -> Bool { app?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
    private func isBlocked(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return true }
        let bundle = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""
        return passwordApplications.contains { bundle.lowercased().hasPrefix($0.lowercased()) } || preferences.excludes(bundle: bundle, name: name)
    }

    private func pollClipboard(source: NSRunningApplication? = nil, forceSnapshot: Bool = false) {
        guard !isDemo else { return }
        let pb = NSPasteboard.general
        if !captureInFlight, !shelf.isInteracting, let pending = pendingCapture {
            pendingCapture = nil
            if pb.changeCount == pending.count, pending.generation == captureGeneration, !preferences.paused { beginCapture(pending); return }
        }
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        if automaticPastePending { toast("剪贴板已更新，已取消此次自动粘贴") }
        automaticPastePending = false
        pendingPasteGeneration &+= 1
        lastChangeCount = currentCount
        guard !preferences.paused else { return }
        let app = source ?? observedApp ?? NSWorkspace.shared.frontmostApplication
        guard let app, !isOwn(app), !isBlocked(app), !IsSecureEventInputEnabled() else { return }
        let request = CaptureRequest(count: currentCount, app: app, source: app.localizedName ?? "未知应用", bundle: app.bundleIdentifier ?? "", generation: captureGeneration, stackSession: stackEnabled ? stackSession : nil)
        if (!forceSnapshot && captureInFlight) || shelf.isInteracting { pendingCapture = request }
        else { beginCapture(request) }
    }

    private func beginCapture(_ request: CaptureRequest) {
        // NSPasteboard and its provider caches stay on the main thread. Only immutable
        // captured data, fingerprinting and subsequent persistence cross queues.
        let pb = NSPasteboard.general
        guard pb.changeCount == request.count,
              let captured = ClipStore.read(pb, source: request.source, bundle: request.bundle),
              pb.changeCount == request.count else { resolveStackPasteIfReady(); return }
        let reservation = captured.temporaryCaptureReservation
        guard reservation <= transientByteBudget - captureBytesInFlight else {
            pendingCapture = request
            if stackEnabled, stackCollecting { stackCollecting = false; toast("连续粘贴收集已暂停，请先粘贴已有队列") }
            return
        }
        if pendingCapture?.count == request.count { pendingCapture = nil }
        capturesInFlight += 1; captureBytesInFlight += reservation
        captureQueue.async { [weak self] in
            let captured = autoreleasepool { () -> Clip in
                let snapshot = captured.preservingTemporaryFiles()
                _ = snapshot.fingerprint
                return snapshot
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.capturesInFlight -= 1; self.captureBytesInFlight -= reservation
                if request.generation == self.captureGeneration,
                   !self.preferences.paused, !self.isBlocked(request.app) {
                    let id = self.store.add(captured)
                    if self.stackEnabled, request.stackSession == self.stackSession { self.appendStack(id: id) }
                    if self.preferences.soundEffects { NSSound(named: "Tink")?.play() }
                    self.enforceLimits()
                }
                if !self.captureInFlight {
                    let pending = self.pendingCapture
                    self.pendingCapture = nil
                    if let pending, pending.generation == self.captureGeneration,
                       !self.preferences.paused, NSPasteboard.general.changeCount == pending.count {
                        if self.shelf.isInteracting { self.pendingCapture = pending }
                        else { self.beginCapture(pending) }
                    } else { self.pollClipboard() }
                }
                self.resolveStackPasteIfReady()
            }
        }
    }

    private func enforceLimits() {
        // Pending queue entries refer to store-owned inline data until the asynchronous
        // flush gives them a leased disk snapshot. Do not prune that data in between.
        guard !stackQueue.contains(where: { $0.snapshot == nil }) else { return }
        store.prune(days: preferences.days, limit: preferences.limit)
        store.enforceDiskLimit(megabytes: preferences.diskMB)
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu() }
        else { toggleShelf() }
    }

    @objc private func toggleShelf() {
        automaticPastePending = false
        pendingPasteGeneration &+= 1
        if shelf.shouldBePresented { shelf.dismiss(restoringFocus: true); return }
        pollClipboard()
        if let front = NSWorkspace.shared.frontmostApplication, !isOwn(front) {
            targetApp = front
            lastExternalApp = front
        } else {
            targetApp = lastExternalApp?.isTerminated == false ? lastExternalApp : nil
        }
        shelf.present()
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        @discardableResult func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.target = self; menu.addItem(i); return i
        }
        let open = item("打开 Prism", #selector(toggleShelf)); open.keyEquivalent = preferences.hotkey(1).label.lowercased(); open.keyEquivalentModifierMask = preferences.hotkey(1).cocoaFlags
        menu.addItem(.separator())
        item(preferences.paused ? "继续记录剪贴板" : "暂停记录剪贴板", #selector(togglePause)).state = preferences.paused ? .on : .off
        let stack = item(stackEnabled ? "结束连续粘贴（\(stackQueue.count) 项待粘贴）" : "开始连续粘贴", #selector(toggleStack))
        stack.keyEquivalent = preferences.hotkey(2).label.lowercased(); stack.keyEquivalentModifierMask = preferences.hotkey(2).cocoaFlags
        if stackEnabled { stack.state = .on }
        menu.addItem(.separator())
        item("设置…", #selector(showSettings), key: ",")
        item("导出备份…", #selector(exportArchive))
        item("导入备份…", #selector(importArchive))
        item("清空历史记录…", #selector(clearHistory))
        menu.addItem(.separator())
        item("退出 Prism", #selector(quit), key: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatus() {
        guard statusItem != nil else { return }
        let symbol = preferences.paused ? "pause.rectangle" : (stackEnabled ? "square.stack.3d.up" : "clipboard")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Prism")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = stackEnabled ? " \(stackQueue.count)" : ""
        statusItem.isVisible = preferences.showMenuBar
        statusItem.button?.toolTip = "Prism · \(preferences.hotkey(1).display) 打开历史" + (preferences.paused ? " · 记录已暂停" : "") + (stackEnabled ? " · 连续粘贴 \(stackQueue.count) 项" : "")
        scheduleShelfRefresh()
    }

    private func scheduleShelfRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.shelf?.shouldBePresented == true { self.shelf.refresh() }
        }
    }

    @objc private func togglePause() {
        automaticPastePending = false
        pendingPasteGeneration &+= 1
        captureGeneration &+= 1
        pendingCapture = nil
        preferences.paused.toggle()
        if !isDemo { lastChangeCount = NSPasteboard.general.changeCount }
        updateStatus()
        toast(preferences.paused ? "已暂停记录剪贴板" : "已恢复记录剪贴板")
        settingsController?.refreshState()
    }

    private func registerHotKeys() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let owner = Unmanaged<PrismAppDelegate>.fromOpaque(userData).takeUnretainedValue()
            if id.id == 1 { owner.toggleShelf() }
            else if id.id == 2 { owner.toggleStack() }
            return noErr
        }, 1, &eventSpec, context, &hotKeyHandler)
        guard result == noErr else { preferences.showMenuBar = true; updateStatus(); toast("全局快捷键暂不可用，可从菜单栏打开 Prism"); return }
        for id in [UInt32(1), UInt32(2)] {
            let binding = preferences.hotkey(id)
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x5052534D, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { hotKeys[id] = ref }
            else { preferences.showMenuBar = true; toast("\(binding.display) 已被其他应用占用，请使用菜单栏") }
        }
        updateStatus()
    }

    func changeHotkey(_ value: PrismHotkey, id: UInt32) -> String? {
        let other = preferences.hotkey(id == 1 ? 2 : 1)
        if value.keyCode == other.keyCode && value.modifiers == other.modifiers { return "两个全局快捷键不能相同。" }
        let old = preferences.hotkey(id)
        if old.keyCode == value.keyCode && old.modifiers == value.modifiers, isDemo || hotKeys[id] != nil { return nil }
        if !isDemo {
            guard hotKeyHandler != nil else { return "快捷键尚未初始化，请重新打开 Prism 后再试。" }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x5052534D, id: id), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { return "此快捷键已被系统或其他应用占用，原快捷键已保留。" }
            if let oldRef = hotKeys[id] { UnregisterEventHotKey(oldRef) }
            hotKeys[id] = ref
        }
        preferences.setHotkey(value, id: id); updateStatus(); return nil
    }

    func setMenuVisible(_ visible: Bool) -> Bool {
        guard visible || hotKeys[1] != nil else { toast("请先设置可用的全局唤出快捷键，再隐藏菜单栏图标"); return false }
        preferences.showMenuBar = visible; updateStatus(); return true
    }

    func resetHotkeys() {
        hotKeys.values.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
        preferences.setHotkey(.shelf, id: 1); preferences.setHotkey(.stack, id: 2)
        if !isDemo { registerHotKeys() }
        settingsController?.refreshState()
    }

    func setCaptureEnabled(_ enabled: Bool) { if preferences.paused == enabled { togglePause() } }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard shelf?.shouldBePresented != true else { return true }
        if !flag {
            if isDemo { shelf.present() }
            else { showSettings() }
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settingsController?.refreshState()
    }

    private func installMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem(); main.addItem(applicationItem)
        let application = NSMenu(title: "Prism"); applicationItem.submenu = application
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        add(application, "关于 Prism", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        application.addItem(.separator())
        add(application, "设置…", #selector(showSettings), key: ",", target: self)
        application.addItem(.separator())
        add(application, "隐藏 Prism", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        add(application, "隐藏其他应用", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp)
        add(application, "显示全部", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        application.addItem(.separator())
        add(application, "退出 Prism", #selector(quit), key: "q", target: self)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        add(edit, "撤销", Selector(("undo:")), key: "z")
        add(edit, "重做", Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), key: "x")
        add(edit, "复制", #selector(NSText.copy(_:)), key: "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), key: "v")
        add(edit, "全选", #selector(NSText.selectAll(_:)), key: "a")
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); main.addItem(windowItem)
        let window = NSMenu(title: "窗口"); windowItem.submenu = window
        add(window, "剪贴板历史", #selector(toggleShelf), target: self)
        window.addItem(.separator())
        add(window, "关闭窗口", #selector(NSWindow.performClose(_:)), key: "w")
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        NSApp.windowsMenu = window; NSApp.mainMenu = main
    }

    private func writeClipboard(_ clips: [Clip], plainText: Bool,
                                isCurrent: @escaping () -> Bool = { true },
                                completion: @escaping (Bool) -> Void = { _ in }) {
        automaticPastePending = false
        pendingPasteGeneration &+= 1
        guard !isDemo else { toast("演示模式不会更改系统剪贴板"); completion(false); return }
        guard !clips.isEmpty else { completion(false); return }
        let generation = pendingPasteGeneration
        let expectedCount = NSPasteboard.general.changeCount
        let publish: (Result<PreparedTransfer, Error>) -> Void = { [weak self] result in
            guard let self else { completion(false); return }
            guard generation == self.pendingPasteGeneration, isCurrent() else { completion(false); return }
            guard NSPasteboard.general.changeCount == expectedCount else {
                self.toast("剪贴板已更新，请重新选择要复制的记录")
                completion(false); return
            }
            do {
                let transfer = try result.get()
                let objects = transfer.writers
                guard !objects.isEmpty else {
                    self.toast(transfer.unavailableClipIDs.isEmpty ? "记录内容无法读取" : "文件已失效")
                    self.shelf.requestFileAvailabilityRefresh()
                    completion(false)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                let success = pb.writeObjects(objects)
                self.lastChangeCount = pb.changeCount
                if !success { self.toast("无法写入系统剪贴板，请再试一次") }
                if success, !transfer.unavailableClipIDs.isEmpty {
                    self.toast("已跳过 \(transfer.unavailableClipIDs.count) 条失效记录")
                    self.shelf.requestFileAvailabilityRefresh()
                }
                completion(success)
            } catch {
                self.toast("无法读取记录内容：\(error.localizedDescription)")
                completion(false)
            }
        }
        if plainText {
            let text = clips.map { clip -> String in
                if !clip.files.isEmpty { return clip.files.map(\.path).joined(separator: "\n") }
                if !clip.text.isEmpty { return clip.text }
                return clip.recognizedText
            }.filter { !$0.isEmpty }.joined(separator: "\n")
            guard !text.isEmpty else { toast("这些记录没有可复制的文本"); completion(false); return }
            let item = NSPasteboardItem(); item.setString(text, forType: .string)
            publish(.success(PreparedTransfer(writers: [item], clipIDs: clips.map(\.id), unavailableClipIDs: [])))
        } else {
            FileTransferPreparation.prepareSelection(clips: clips, forDragging: false, completion: publish)
        }
    }

    private func paste(_ clips: [Clip], plainText: Bool) {
        let target = targetApp
        writeClipboard(clips, plainText: plainText || preferences.alwaysPlainText, completion: { [weak self] success in
            guard let self, success else { return }
            self.completePaste(to: target)
        })
    }

    private func completePaste(to target: NSRunningApplication?) {
        shelf.dismiss(animated: false)
        guard let target, !target.isTerminated, !isOwn(target) else { toast("已复制，切换到目标应用后按 ⌘V 粘贴"); return }
        NSApp.yieldActivation(to: target)
        target.activate(options: [])
        guard preferences.automaticPaste else { toast("已复制，按 ⌘V 粘贴"); return }
        guard CGPreflightPostEventAccess() else { toast("已复制。当前版本缺少事件发送许可，请在系统设置中重新允许 Prism"); return }
        pendingPasteGeneration &+= 1
        let generation = pendingPasteGeneration
        automaticPastePending = true
        sendPasteWhenActive(target, generation: generation, expectedChangeCount: lastChangeCount, attempts: 10)
    }

    private func sendPasteWhenActive(_ target: NSRunningApplication, generation: UInt64, expectedChangeCount: Int, attempts: Int, stableTicks: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, generation == self.pendingPasteGeneration else { return }
            guard NSPasteboard.general.changeCount == expectedChangeCount else { self.automaticPastePending = false; self.toast("剪贴板已更新，已取消此次自动粘贴"); return }
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
            let consecutiveTicks = isFrontmost ? stableTicks + 1 : 0
            if consecutiveTicks >= 2, !target.isTerminated {
                guard NSPasteboard.general.changeCount == expectedChangeCount else { self.automaticPastePending = false; self.toast("剪贴板已更新，已取消此次自动粘贴"); return }
                self.automaticPastePending = false
                guard !IsSecureEventInputEnabled() else { self.toast("当前处于安全输入状态，已复制，请手动按 ⌘V 粘贴"); return }
                _ = self.sendPasteEvent(to: target)
            } else if attempts > 0, !target.isTerminated {
                self.sendPasteWhenActive(target, generation: generation, expectedChangeCount: expectedChangeCount, attempts: attempts - 1, stableTicks: consecutiveTicks)
            } else { self.automaticPastePending = false; self.toast("已复制，切换到目标应用后按 ⌘V 粘贴") }
        }
    }

    // A successful post has no acknowledgement that the receiving app consumed it.
    @discardableResult private func sendPasteEvent(to target: NSRunningApplication) -> Bool {
        guard CGPreflightPostEventAccess() else {
            toast("当前版本缺少事件发送许可，请在系统设置中重新允许 Prism。内容已复制，可手动按 ⌘V")
            return false
        }
        guard !IsSecureEventInputEnabled() else {
            toast("当前处于安全输入状态，请手动按 ⌘V 粘贴")
            return false
        }
        guard !target.isTerminated, !isOwn(target),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            toast("已复制，请切换到目标应用后按 ⌘V 粘贴")
            return false
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            toast("无法发送粘贴快捷键，请手动按 ⌘V 粘贴")
            return false
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: injectedEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: injectedEventTag)
        down.postToPid(target.processIdentifier)
        up.postToPid(target.processIdentifier)
        return true
    }

    @objc private func toggleStack() {
        automaticPastePending = false
        pendingPasteGeneration &+= 1
        if stackEnabled {
            endStack()
            toast("已结束连续粘贴")
            return
        }
        guard startStack() else { return }
        stackQueue.removeAll()
        shelf.dismiss(animated: false)
        if let target = targetApp, isOwn(NSWorkspace.shared.frontmostApplication) {
            NSApp.yieldActivation(to: target); target.activate(options: [])
        }
        toast("连续粘贴已开启：依次复制，再用 ⌘V 逐条粘贴")
    }

    private func startStack() -> Bool {
        guard !isDemo else { toast("演示模式不启用全局连续粘贴"); return false }
        guard !IsSecureEventInputEnabled() else { toast("当前处于安全输入状态，请结束密码输入后再开启"); return false }
        guard CGPreflightPostEventAccess() else { requestAccessibility(); return false }
        guard AXIsProcessTrusted() else { requestAccessibility(); return false }
        guard installEventTap() else { toast("无法监听粘贴快捷键，请在系统设置中允许辅助功能"); return false }
        pollClipboard()
        stackSession &+= 1
        stackEnabled = true
        updateStatus()
        return true
    }

    private func enqueue(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        if !stackEnabled, !startStack() { return }
        for clip in clips { appendStack(id: clip.id) }
        updateStatus()
        if stackCollecting { toast("已加入连续粘贴，共 \(stackQueue.count) 项；按 ⌘V 逐条粘贴") }
    }

    private func appendStack(id: UUID) {
        guard stackCollecting else { return }
        refreshStackSnapshots()
        guard let clip = store.clips.first(where: { $0.id == id }) else { return }
        let bound = store.diskBoundClip(id: id)
        let sizes = Dictionary(uniqueKeysWithValues: store.clips.map { ($0.id, $0.byteCount) })
        let pendingBytes = stackQueue.reduce(0) { total, entry in
            total + (entry.snapshot == nil ? (sizes[entry.id] ?? 0) : 0)
        }
        guard stackQueue.count < 500, pendingBytes + (bound == nil ? clip.byteCount : 0) <= transientByteBudget else {
            stackCollecting = false
            toast("连续粘贴收集已暂停：队列最多 500 项，待保存内容最多 128 MB。已有队列已保留。")
            return
        }
        stackQueue.append(StackEntry(id: id, snapshot: bound))
        updateStatus()
        guard !stackFlushScheduled, bound == nil else { return }
        stackFlushScheduled = true
        store.flush { [weak self] success in
            guard let self else { return }
            self.stackFlushScheduled = false
            self.refreshStackSnapshots()
            if success { self.enforceLimits() }
            else { self.stackCollecting = false; self.toast("连续粘贴收集已暂停：记录尚未保存，已有队列已保留") }
        }
    }

    private func refreshStackSnapshots() {
        let available = Dictionary(uniqueKeysWithValues: store.clips.filter(\.isDiskBound).map { ($0.id, $0) })
        for index in stackQueue.indices where stackQueue[index].snapshot == nil {
            stackQueue[index].snapshot = available[stackQueue[index].id]
        }
    }

    private func endStack() {
        stackTransferPending = false
        stackEnabled = false
        stackQueue.removeAll()
        stackBusy = false
        stackShortcutHeld = false
        stackAwaitingPaste = nil
        stackWaitGeneration &+= 1
        stackSession &+= 1
        stackCollecting = true
        copyProbeGeneration &+= 1
        removeEventTap()
        updateStatus()
    }

    private func installEventTap() -> Bool {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true); return true }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, userData in
            guard let userData else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<PrismAppDelegate>.fromOpaque(userData).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if owner.stackEnabled, let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard owner.stackEnabled,
                  event.getIntegerValueField(.eventSourceUserData) != owner.injectedEventTag else { return Unmanaged.passUnretained(event) }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let isCopy = key == Int64(kVK_ANSI_C) || key == Int64(kVK_ANSI_X)
            if isCopy, event.flags.contains(.maskCommand), event.flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty {
                let app = NSWorkspace.shared.frontmostApplication
                if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { [weak owner] in owner?.probeCopy(source: app) }
                } else if type == .keyUp {
                    DispatchQueue.main.async { [weak owner] in owner?.pollClipboard(source: app, forceSnapshot: true) }
                }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyUp, owner.stackShortcutHeld,
               event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V) {
                owner.stackShortcutHeld = false
                owner.finishStackStroke()
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V),
                  event.flags.contains(.maskCommand),
                  event.flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty else { return Unmanaged.passUnretained(event) }
            // Auto-repeat must not consume the next record or paste the previous record again.
            if owner.stackBusy { return nil }
            let hasPendingCopy = owner.captureInFlight || owner.pendingCapture != nil || NSPasteboard.general.changeCount != owner.lastChangeCount
            guard !owner.stackQueue.isEmpty || hasPendingCopy else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            let app = NSWorkspace.shared.frontmostApplication
            guard !owner.isOwn(app), !owner.isBlocked(app), !IsSecureEventInputEnabled() else { return Unmanaged.passUnretained(event) }
            owner.stackBusy = true
            owner.stackShortcutHeld = true
            owner.stackConsumedInStroke = false
            DispatchQueue.main.async { [weak owner] in owner?.prepareStackPaste(target: app) }
            return nil
        }, userInfo: context) else { return false }
        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapSource { CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func probeCopy(source: NSRunningApplication?) {
        guard stackEnabled, stackCollecting, !isOwn(source), !isBlocked(source) else { return }
        copyProbeGeneration &+= 1
        let generation = copyProbeGeneration
        for delay in [0.0, 0.01, 0.03, 0.05, 0.07, 0.09, 0.11, 0.13, 0.15, 0.17, 0.19, 0.20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.stackEnabled, self.copyProbeGeneration == generation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == source?.processIdentifier else { return }
                self.pollClipboard(source: source, forceSnapshot: true)
            }
        }
    }

    private func prepareStackPaste(target: NSRunningApplication?) {
        guard stackEnabled, let target else { stackBusy = false; return }
        stackAwaitingPaste = target
        stackWaitGeneration &+= 1
        let generation = stackWaitGeneration
        // Capture a just-copied item before the queue replaces the clipboard. The
        // event tap itself stays cheap and never waits for providers or hashing.
        pollClipboard()
        resolveStackPasteIfReady()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.stackWaitGeneration == generation, self.stackAwaitingPaste != nil else { return }
            self.stackAwaitingPaste = nil; self.stackBusy = false; self.stackShortcutHeld = false
            self.toast("正在读取剪贴板，请稍后再按 ⌘V")
        }
    }

    private func resolveStackPasteIfReady() {
        guard stackEnabled, !captureInFlight, pendingCapture == nil, let target = stackAwaitingPaste else { return }
        stackAwaitingPaste = nil
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            stackBusy = false; return
        }
        if stackQueue.isEmpty {
            _ = sendPasteEvent(to: target)
            if !stackShortcutHeld { finishStackStroke() }
        } else { consumeStack(target: target) }
    }

    private func consumeStack(target: NSRunningApplication?) {
        refreshStackSnapshots()
        guard stackEnabled else { stackBusy = false; return }
        var skipped = 0
        while let first = stackQueue.first,
              first.snapshot == nil, !store.clips.contains(where: { $0.id == first.id }) {
            stackQueue.removeFirst(); skipped += 1
        }
        if skipped > 0 { updateStatus(); toast("已跳过 \(skipped) 项已删除的记录") }
        guard let entry = stackQueue.first,
              let clip = entry.snapshot ?? store.clips.first(where: { $0.id == entry.id }) else {
            endStack(); return
        }
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            stackBusy = false; toast("连续粘贴未完成，请再按一次 ⌘V"); return
        }
        let session = stackSession
        stackTransferPending = true
        writeClipboard([clip], plainText: false, isCurrent: { [weak self] in
            guard let self else { return false }
            return self.stackEnabled && self.stackSession == session && self.stackQueue.first?.id == entry.id &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        }) { [weak self] success in
            guard let self, self.stackSession == session else { return }
            self.stackTransferPending = false
            if success, self.sendPasteEvent(to: target) {
                self.stackConsumedInStroke = true
                self.stackQueue.removeFirst()
                self.updateStatus()
            } else { self.stackBusy = false }
            if !self.stackShortcutHeld { self.finishStackStroke() }
        }
    }

    private func finishStackStroke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.stackEnabled, !self.stackShortcutHeld, !self.stackTransferPending, self.stackAwaitingPaste == nil else { return }
            self.stackBusy = false
            if self.stackQueue.isEmpty, self.stackConsumedInStroke { self.endStack() }
        }
    }

    private func removeEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        eventTap = nil; eventTapSource = nil
    }

    @objc func showSettings() {
        automaticPastePending = false
        pendingPasteGeneration &+= 1
        shelf?.dismiss(animated: false)
        if settingsController == nil { settingsController = PrismSettingsController(owner: self) }
        settingsController?.refreshState()
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    func preferencesChanged() { captureGeneration &+= 1; pendingCapture = nil; enforceLimits(); settingsController?.refreshState() }

    func requestAccessibility() {
        guard !isDemo else { toast("演示模式不申请系统权限"); return }
        shelf?.dismiss(animated: false)
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        toast("请在系统设置 → 隐私与安全性 → 辅助功能中允许 Prism")
        settingsController?.refreshState()
    }

    func setLoginItem(_ enabled: Bool) {
        guard !isDemo else { settingsController?.refreshState(); return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert("无法更新登录启动", error.localizedDescription + "\n请先将 Prism.app 放入“应用程序”文件夹并从那里打开。")
        }
        settingsController?.refreshState()
    }

    @objc func clearHistory() {
        shelf?.dismiss(animated: false)
        let alert = NSAlert()
        alert.messageText = "清空历史记录？"
        alert.informativeText = "已加入收藏板的记录会保留。此操作无法撤销。"
        alert.addButton(withTitle: "清空历史"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.remove(Set(store.clips.filter { $0.boardIDs.isEmpty }.map(\.id))) }
    }

    @objc func exportArchive() {
        guard !archiveBusy else { toast("备份操作正在进行，请稍候"); return }
        shelf?.dismiss(animated: false)
        let panel = NSSavePanel(); panel.title = "导出 Prism 备份"
        panel.allowedContentTypes = [UTType(exportedAs: "local.prism.backup", conformingTo: .package)]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "Prism-\(formatter.string(from: Date())).prismbackup"
        panel.message = "备份包含完整原始剪贴板内容，请保存到可信的位置。"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = Archive(clips: store.clips, boards: store.boards)
        archiveBusy = true; toast("正在导出备份…")
        archiveQueue.async { [weak self] in
            do {
                try ClipStore.exportBackup(snapshot, to: url)
                DispatchQueue.main.async { self?.archiveBusy = false; self?.toast("备份已导出") }
            } catch { DispatchQueue.main.async { self?.archiveBusy = false; self?.alert("导出失败", error.localizedDescription) } }
        }
    }

    @objc func importArchive() {
        guard !archiveBusy else { toast("备份操作正在进行，请稍候"); return }
        shelf?.dismiss(animated: false)
        let panel = NSOpenPanel(); panel.title = "导入 Prism 备份"
        panel.allowedContentTypes = [.json, UTType(exportedAs: "local.prism.backup", conformingTo: .package), .folder]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "选择 .prismbackup 备份；也可导入旧版 JSON 备份。"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveBusy = true
        archiveQueue.async { [weak self] in
            do {
                if url.pathExtension.lowercased() == "json" {
                    let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url, options: .mappedIfSafe))
                    guard archive.version == 1 else { throw NSError(domain: "Prism", code: 1, userInfo: [NSLocalizedDescriptionKey: "此备份版本暂不受支持。"]) }
                    guard archive.clips.allSatisfy({ $0.byteCount <= ClipStore.maxBytes }) else { throw NSError(domain: "Prism", code: 2, userInfo: [NSLocalizedDescriptionKey: "备份包含超过 100 MB 的单条记录，未导入任何内容。"]) }
                    archive.clips.forEach { _ = $0.fingerprint }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.store.importArchive(archive)
                        self.store.flush { [weak self] success in
                            self?.archiveBusy = false
                            if success { self?.enforceLimits(); self?.toast("已导入 \(archive.clips.count) 项记录") }
                            else { self?.alert("导入内容尚未保存", self?.store.lastError ?? "请检查磁盘空间。") }
                        }
                    }
                } else {
                    let manifest = try ClipStore.readBackupManifest(at: url)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.store.importArchive(Archive(clips: [], boards: manifest.boards))
                        self.importBackupEntries(Array(manifest.clips.reversed()), at: url, index: 0)
                    }
                }
            } catch { DispatchQueue.main.async { self?.archiveBusy = false; self?.alert("导入失败", error.localizedDescription) } }
        }
    }

    private func importBackupEntries(_ entries: [BackupEntry], at url: URL, index: Int) {
        guard index < entries.count else {
            store.flush { [weak self] success in
                guard let self else { return }
                self.archiveBusy = false
                if success { self.enforceLimits(); self.scheduleShelfRefresh(); self.toast("已导入 \(entries.count) 项记录") }
                else { self.alert("导入内容尚未保存", self.store.lastError ?? "请检查磁盘空间。") }
            }
            return
        }
        archiveQueue.async { [weak self] in
            do {
                let clip = try autoreleasepool { () throws -> Clip in
                    let clip = try ClipStore.readBackupClip(entry: entries[index], at: url)
                    _ = clip.fingerprint; return clip
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.store.add(clip)
                    // Persist and release this payload before loading the next item.
                    self.store.flush { [weak self] success in
                        guard let self else { return }
                        if success { self.importBackupEntries(entries, at: url, index: index + 1) }
                        else { self.archiveBusy = false; self.alert("导入未完成", self.store.lastError ?? "当前记录无法保存；之前导入的记录已保留。") }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.archiveBusy = false
                    self?.alert("导入未完成", "已保留之前导入的 \(index) 项。\n" + error.localizedDescription)
                }
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    private func toast(_ text: String) {
        toastGeneration &+= 1
        let generation = toastGeneration
        toastPanel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .labelColor
        label.maximumNumberOfLines = 3; label.lineBreakMode = .byWordWrapping
        let width = min(540, max(250, label.intrinsicContentSize.width + 40))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 66), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .statusBar
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 16; effect.layer?.masksToBounds = true
        panel.contentView = effect
        label.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20), label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20), label.centerYAnchor.constraint(equalTo: effect.centerYAnchor)])
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.minY + 58)) }
        toastPanel = panel; panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { [weak self] in
            guard let self, generation == self.toastGeneration else { return }
            self.toastPanel?.orderOut(nil); self.toastPanel = nil
        }
    }
}

