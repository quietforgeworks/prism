import AppKit

/// Temporarily makes the Dock unavailable while the shelf is presented.
///
/// Keep this object on the main thread. Call `begin()` after showing/activating
/// the shelf and `end()` before every path that hides or closes its panel.
/// Repeated calls are harmless; application deactivation, hiding, and termination
/// also end the scope. This never writes the user's Dock preferences.
final class ShelfDockPresentation: NSObject {
    private typealias Options = NSApplication.PresentationOptions
    private static let dockOptions: Options = [.hideDock, .autoHideDock]

    private let application: NSApplication
    private var isPresenting = false
    // nil means that this scope did not change the Dock options.
    private var savedDockOptions: Options?

    override init() {
        precondition(Thread.isMainThread)
        application = .shared
        super.init()
        for name in [NSApplication.willResignActiveNotification,
                     NSApplication.willHideNotification,
                     NSApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(applicationStoppedPresenting(_:)),
                name: name, object: application
            )
        }
    }

    deinit {
        end()
        NotificationCenter.default.removeObserver(self)
    }

    func begin() {
        precondition(Thread.isMainThread)
        guard !isPresenting else { return }
        let current = application.presentationOptions
        // hideDock is valid on its own. In particular, it does not require us to
        // hide the menu bar or prevent switching, hiding, or quitting apps.
        let desired = current.subtracting(Self.dockOptions).union(.hideDock)
        guard Self.isValid(desired) else { return }
        isPresenting = true
        guard desired != current else { return }
        savedDockOptions = current.intersection(Self.dockOptions)
        application.presentationOptions = desired
    }

    func end() {
        precondition(Thread.isMainThread)
        guard isPresenting else { return }
        isPresenting = false
        guard let savedDockOptions else { return }
        self.savedDockOptions = nil

        let current = application.presentationOptions
        // A different Dock value now belongs to another presentation owner.
        // Never restore the entire saved option set: fullScreen and all other
        // unrelated flags may legitimately have changed while the shelf was up.
        guard current.intersection(Self.dockOptions) == .hideDock else { return }
        let restored = current.subtracting(Self.dockOptions).union(savedDockOptions)
        // External code may have added a flag that now requires a hidden Dock.
        // Preserve that owner's valid combination instead of changing its flags
        // or passing an invalid value to AppKit (which raises NSException).
        guard Self.isValid(restored), restored != current else { return }
        application.presentationOptions = restored
    }

    @objc private func applicationStoppedPresenting(_ notification: Notification) {
        end()
    }

    /// AppKit's documented option dependencies; check before either setter call.
    /// https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct
    private static func isValid(_ options: Options) -> Bool {
        if options.contains([.hideDock, .autoHideDock]) { return false }
        if options.contains([.hideMenuBar, .autoHideMenuBar]) { return false }
        if options.contains(.hideMenuBar), !options.contains(.hideDock) { return false }

        let requiresDock: Options = [.autoHideMenuBar, .disableProcessSwitching,
                                     .disableForceQuit, .disableSessionTermination,
                                     .disableMenuBarTransparency]
        if !options.intersection(requiresDock).isEmpty,
           options.intersection(dockOptions).isEmpty { return false }
        if options.contains(.autoHideToolbar),
           !options.contains([.fullScreen, .autoHideMenuBar]) { return false }
        return true
    }
}
