import AppKit
import QuickLookThumbnailing
import Quartz
import PDFKit
import WebKit
import QuartzCore

private let cardIdentifier = NSUserInterfaceItemIdentifier("ClipCard")
private let boardIDType = NSPasteboard.PasteboardType("local.prism.board-id")
private let clipIDType = NSPasteboard.PasteboardType("local.prism.clip-id")
private let boardColors: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemGreen, .systemPink, .systemTeal]

// Attach internal routing metadata to the first real item, never a separate
// text item. In particular NSURL keeps its native representation order/options.
final class ClipDragWriter: NSObject, NSPasteboardWriting {
    private let writer: NSPasteboardWriting
    private let clipIDs: String
    init(writer: NSPasteboardWriting, clipIDs: String) {
        self.writer = writer; self.clipIDs = clipIDs
        super.init()
    }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        writer.writableTypes(for: pasteboard).filter { $0 != clipIDType } + [clipIDType]
    }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == clipIDType ? clipIDs : writer.pasteboardPropertyList(forType: type)
    }
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == clipIDType ? [] : (writer.writingOptions?(forType: type, pasteboard: pasteboard) ?? [])
    }
}

// Keep text legible over busy desktops while retaining real system glass at the rim.
final class ReadableSurfaceView: NSView {
    private let surfaceOpacity: CGFloat
    private let surfaceColor: NSColor
    init(opacity: CGFloat, cornerRadius: CGFloat = 0, color: NSColor = .windowBackgroundColor) {
        surfaceOpacity = opacity; surfaceColor = color
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = cornerRadius; layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        surfaceColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : surfaceOpacity).setFill()
        dirtyRect.fill()
    }
}

/// Optional fill behind shelf controls. It exists only when the user reduces
/// transparency; the default hierarchy and native glass remain unchanged.
private final class ShelfBackgroundFillView: NSView {
    var opacity: CGFloat = 0 { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 22; layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(opacity).setFill()
        dirtyRect.fill()
    }
}

private final class ShelfGlassView: NSView {
    private let glass = NSGlassEffectView()
    private let glassContent = NSView()
    private let shelfContent: NSView
    private let cornerRadius: CGFloat = 22
    private var backgroundFill: ShelfBackgroundFillView?

    init(frame: NSRect, contentView: NSView) {
        shelfContent = contentView
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Use the standard material so macOS controls its preferred glass appearance.
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.contentView = glassContent
        addSubview(glass)
        glassContent.addSubview(shelfContent)
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutContent()
    }

    func applyAppearance(_ settings: PrismAppearanceSettings) {
        let style: NSGlassEffectView.Style = settings.glassStyle == .clear ? .clear : .regular
        if glass.style != style { glass.style = style }
        let fill = CGFloat(1 - min(1, max(0, settings.transparency)))
        if fill <= 0 {
            backgroundFill?.removeFromSuperview(); backgroundFill = nil
        } else {
            if backgroundFill == nil {
                let view = ShelfBackgroundFillView(frame: glassContent.bounds)
                glassContent.addSubview(view, positioned: .below, relativeTo: shelfContent)
                backgroundFill = view
            }
            backgroundFill?.opacity = fill
        }
    }
    func layoutContent() {
        // Extend the native glass below the window so its lower rounded corners
        // are clipped at the screen edge. Controls retain their visible bounds.
        glass.frame = NSRect(
            x: 0,
            y: -cornerRadius,
            width: bounds.width,
            height: bounds.height + cornerRadius
        )
        glassContent.frame = glass.bounds
        backgroundFill?.frame = glassContent.bounds
        shelfContent.frame = NSRect(
            x: 0,
            y: cornerRadius,
            width: bounds.width,
            height: bounds.height
        )
    }
}

/// The panel never leaves its display. Moving the glass inside this clipped
/// viewport prevents a slide from appearing on a display directly below it.
private final class ShelfClipView: NSView {
    let glass: ShelfGlassView
    var visibleFraction: CGFloat {
        guard bounds.height > 0, let layer else { return 0 }
        let translation: CGFloat
        if let animation = layer.animation(forKey: ShelfSlideAnimator.layerAnimationKey) as? CABasicAnimation {
            translation = layer.presentation()?.sublayerTransform.m42
                ?? (animation.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
                ?? layer.sublayerTransform.m42
        } else { translation = layer.sublayerTransform.m42 }
        return min(1, max(0, 1 + translation / bounds.height))
    }

    init(frame: NSRect, contentView: NSView) {
        glass = ShelfGlassView(frame: NSRect(origin: .zero, size: frame.size), contentView: contentView)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(glass)
        layoutContent()
        setVisibleFraction(0)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); layoutContent() }
    func layoutContent() {
        // View geometry remains fixed throughout the slide. Core Animation
        // translates the child layers, preserving the live system glass.
        if glass.frame.size != bounds.size { glass.setFrameSize(bounds.size) }
        glass.layoutContent()
    }
    func setVisibleFraction(_ fraction: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeTranslation(0, -(1 - min(1, max(0, fraction))) * bounds.height, 0)
        CATransaction.commit()
    }

}

final class ShelfPanel: NSPanel {
    var willHide: (() -> Void)?
    var acceptsShelfInput = false
    override var canBecomeKey: Bool { acceptsShelfInput }
    override var canBecomeMain: Bool { false }
    override func orderOut(_ sender: Any?) { willHide?(); super.orderOut(sender) }
    override func close() { willHide?(); super.close() }
}
final class ShelfScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Trackpads use AppKit's native momentum and pixel scrolling unchanged.
        if !event.hasPreciseScrollingDeltas && abs(event.scrollingDeltaX) < 0.01 {
            var origin = contentView.bounds.origin
            origin.x = max(0, min(origin.x - event.scrollingDeltaY * 12, max(0, (documentView?.bounds.width ?? 0) - contentSize.width)))
            contentView.scroll(to: origin); reflectScrolledClipView(contentView)
        } else { super.scrollWheel(with: event) }
    }
}
final class ResizeGrip: NSView {
    weak var shelf: ShelfController?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: 2, width: 36, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func mouseDown(with event: NSEvent) {
        shelf?.prepareForResize()
        guard let window, let screen = window.screen else { return }
        let start = NSEvent.mouseLocation; let frame = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            var f = frame; f.size.height = min(screen.visibleFrame.height * 0.78, max(260, frame.height + NSEvent.mouseLocation.y - start.y))
            window.setFrame(f, display: true); shelf?.layout()
        }
        UserDefaults.standard.set(window.frame.height, forKey: "shelfHeight")
    }
}
final class BoardButton: NSButton, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    var board: UUID?; weak var shelf: ShelfController?
    convenience init(title: String, image: NSImage?, board: UUID?, shelf: ShelfController) {
        self.init(title: title, target: nil, action: nil)
        self.board = board; self.shelf = shelf; self.image = image; imagePosition = .imageLeading
        bezelStyle = .accessoryBarAction; isBordered = false; font = .systemFont(ofSize: 13, weight: .medium)
        target = self; action = #selector(choose); setAccessibilityLabel(title)
        registerForDraggedTypes([boardIDType, clipIDType, .string, .png, .tiff, .fileURL, .URL, .rtf, .html, .pdf])
    }
    @objc func choose() { shelf?.chooseBoard(board) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { contentTintColor = .controlAccentColor; return sender.draggingPasteboard.types?.contains(boardIDType) == true ? .move : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { contentTintColor = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        contentTintColor = nil
        if let value = sender.draggingPasteboard.string(forType: boardIDType), let moving = UUID(uuidString: value), let shelf {
            shelf.moveBoard(moving, before: board); return true
        }
        return shelf?.receive(sender.draggingPasteboard, board: board) ?? false
    }
    override func mouseDown(with event: NSEvent) {
        guard board != nil, let window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        highlight(true)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { highlight(false); choose(); return }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 5 {
                highlight(false); mouseDragged(with: next); return
            }
        }
        highlight(false)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let board else { return }
        let item = NSPasteboardItem(); item.setString(board.uuidString, forType: boardIDType)
        let dragging = NSDraggingItem(pasteboardWriter: item); dragging.setDraggingFrame(bounds, contents: image ?? NSImage(size: bounds.size))
        beginDraggingSession(with: [dragging], event: event, source: self)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let board, let shelf else { return }
        let menu = NSMenu()
        menu.addAction("重命名分组…") { shelf.renameBoard(board) }
        menu.addAction("删除分组…") { shelf.deleteBoard(board) }
        shelf.showContextMenu(menu, event: event, view: self)
    }
}
extension NSMenu {
    @discardableResult func addAction(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.invoke), keyEquivalent: key)
        item.handler = handler; item.target = item; addItem(item); return item
    }
}
final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func invoke() { handler?() }
}

final class ShelfController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let store: ClipStore; let actions: ShelfActions
    private let appearanceProvider: () -> PrismAppearanceSettings
    private(set) var appearanceSettings = PrismAppearanceSettings.default
    private var appearanceNeedsUpdate = false
    let collection = NSCollectionView(); let flow = NSCollectionViewFlowLayout(); let scroll = ShelfScrollView()
    private let root = NSView(); private let toolbar = NSView(); private let tabsScroll = NSScrollView(); private let tabs = NSStackView()
    private let grip = ResizeGrip(); private let empty = NSTextField(wrappingLabelWithString: "")
    private let search = NSSearchField(); private let searchButton = NSButton(); private let more = NSButton(); private let filter = NSPopUpButton()
    private var localMonitor: Any?; private var outsideMonitor: Any?; private var searchWork: DispatchWorkItem?
    private var selection: Set<UUID> = []; private var anchor: UUID?; private var board: UUID?
    private var kind = "全部"; private var source = "全部"; private var days = 0
    private var hasSearch = false; private var preview: NSWindowController?
    private var isLiveScrolling = false; private var refreshAfterInteraction = false
    private var searchToken: ClipSearchToken?
    private var searchGeneration: UInt64 = 0
    private var tabSignature: [String] = []
    private(set) var visibleItems: [Clip] = []
    var selectedClips: [Clip] { visibleItems.filter { selection.contains($0.id) } }
    var isDragging = false
    private var dragSession: NSDraggingSession?
    private var dragSource: ClipCard?
    private let dockPresentation = ShelfDockPresentation()
    private let slideAnimator = ShelfSlideAnimator()
    // isVisible stays true during exit. Input, hotkeys, and asynchronous work
    // must follow the requested state instead of that rendering detail.
    private(set) var shouldBePresented = false
    private var presentationGeneration: UInt64 = 0
    private var presentationScreenID: NSNumber?
    private var presentationScreenFrame: NSRect?
    private var menuDepth = 0
    private var isMenuOpen: Bool { menuDepth > 0 }
    var isInteracting: Bool { isLiveScrolling || isDragging || slideAnimator.isAnimating }
    init(store: ClipStore, actions: ShelfActions, appearanceProvider: @escaping () -> PrismAppearanceSettings = { .default }) {
        self.store = store; self.actions = actions; self.appearanceProvider = appearanceProvider
        let panel = ShelfPanel(contentRect: .init(x: 0, y: 0, width: 1100, height: 374), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .screenSaver
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.title = "Prism · 剪贴板"; panel.setAccessibilityLabel("Prism 剪贴板历史")
        super.init(window: panel)
        // One exit hook covers dismiss, editing, preview, close, and dragging
        // beyond the shelf. Internal drops leave the Dock scope in effect.
        panel.willHide = { [weak self] in self?.panelWillHide() }
        panel.contentView = ShelfClipView(frame: panel.contentView!.bounds, contentView: root)
        grip.shelf = self; root.addSubview(grip); root.addSubview(toolbar)
        configureToolbar()
        flow.scrollDirection = .horizontal; flow.minimumLineSpacing = 16; flow.minimumInteritemSpacing = 16
        flow.sectionInset = NSEdgeInsets(top: 8, left: 22, bottom: 18, right: 22)
        collection.collectionViewLayout = flow; collection.backgroundColors = [.clear]; collection.isSelectable = false
        collection.dataSource = self; collection.delegate = self
        collection.register(CardItem.self, forItemWithIdentifier: cardIdentifier)
        collection.registerForDraggedTypes([clipIDType, .string, .png, .tiff, .fileURL, .URL, .rtf, .html, .pdf])
        scroll.documentView = collection; scroll.drawsBackground = false; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        root.addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        empty.alignment = .center; empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 15); root.addSubview(empty)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: panel)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, self.shouldBePresented else { return e }
            if e.type != .keyDown {
                // Finish a very early click at the settled geometry so AppKit
                // hit testing and drag coordinates agree with the visible card.
                if e.window === self.window, self.slideAnimator.isAnimating { self.prepareForResize() }
                if e.window !== self.window && !self.isMenuOpen && self.preview?.window?.isVisible != true && NSApp.modalWindow == nil { self.dismiss(animated: false) }
                return e
            }
            guard e.window === self.window, NSApp.modalWindow == nil else { return e }
            return self.handleKey(e) ? nil : e
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.shouldBePresented, !self.isDragging, !self.isMenuOpen, self.preview?.window?.isVisible != true, NSApp.modalWindow == nil else { return }
            self.dismiss()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(menuStarted), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated), name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated), name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: .prismAppearanceDidChange, object: nil)
        applyAppearance()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { slideAnimator.cancel(); dockPresentation.end(); NSWorkspace.shared.notificationCenter.removeObserver(self); if let localMonitor { NSEvent.removeMonitor(localMonitor) }; if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) } }
    @objc private func appearanceChanged() {
        if isInteracting { appearanceNeedsUpdate = true; return }
        applyAppearance()
    }
    private func applyAppearance() {
        appearanceNeedsUpdate = false
        let settings = appearanceProvider()
        guard settings != appearanceSettings else { return }
        appearanceSettings = settings
        window?.appearance = settings.windowAppearance
        (window?.contentView as? ShelfClipView)?.glass.applyAppearance(settings)
        for item in collection.visibleItems() {
            guard let card = (item as? CardItem)?.card, let clip = card.clip else { continue }
            card.configure(clip, selected: card.selected, number: card.number, shelf: self)
        }
    }
    @objc private func resized() { layout() }
    @objc private func applicationActivated() { if shouldBePresented { dockPresentation.begin() } }
    @objc private func applicationDeactivated() {
        // Presentation options apply only while Prism is active. Recheck after
        // the activation transition, and let an ongoing native drag finish.
        let generation = presentationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.presentationGeneration, self.shouldBePresented,
                  !NSApp.isActive, !self.isDragging,
                  let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.dismiss()
        }
    }
    @objc private func menuStarted() { menuDepth += 1; if window?.isVisible == true { window?.level = .statusBar } }
    @objc private func menuEnded() { menuDepth = max(0, menuDepth - 1); if menuDepth == 0, window?.isVisible == true { window?.level = isDragging ? .floating : .screenSaver } }
    func showContextMenu(_ menu: NSMenu, event: NSEvent, view: NSView) {
        // AppKit menu windows must sit above the shelf while a menu is tracking.
        window?.level = .statusBar
        defer { if window?.isVisible == true { window?.level = isDragging ? .floating : .screenSaver } }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    func layout() {
        guard let window else { return }
        (window.contentView as? ShelfClipView)?.layoutContent()
        let size = root.bounds.size
        grip.frame = NSRect(x: 0, y: size.height - 9, width: size.width, height: 9)
        toolbar.frame = NSRect(x: 18, y: size.height - 61, width: size.width - 36, height: 50)
        more.frame = NSRect(x: toolbar.bounds.width - 36, y: 9, width: 32, height: 32)
        let searchWidth: CGFloat = hasSearch ? min(260, size.width * 0.24) : 32
        searchButton.isHidden = hasSearch; search.isHidden = !hasSearch; filter.isHidden = !hasSearch
        let tabWidth = min(tabs.fittingSize.width + 4, max(110, toolbar.bounds.width - searchWidth - (hasSearch ? 50 : 0) - 90))
        let total = searchWidth + tabWidth + 14 + (hasSearch ? 36 : 0)
        let start = max(0, (toolbar.bounds.width - total) / 2)
        searchButton.frame = NSRect(x: start, y: 9, width: 32, height: 32)
        search.frame = NSRect(x: start, y: 9, width: searchWidth, height: 32)
        filter.frame = NSRect(x: start + searchWidth + 4, y: 10, width: 30, height: 30)
        tabsScroll.frame = NSRect(x: start + searchWidth + (hasSearch ? 40 : 12), y: 6, width: tabWidth, height: 38)
        tabs.frame = NSRect(x: 0, y: 0, width: max(tabWidth, tabs.fittingSize.width), height: 38)
        scroll.frame = NSRect(x: 0, y: 6, width: size.width, height: size.height - 71)
        let h = max(164, scroll.contentSize.height - 27)
        let itemSize = NSSize(width: min(340, max(225, h * 0.95)), height: h)
        if flow.itemSize != itemSize { flow.itemSize = itemSize; flow.invalidateLayout() }
        empty.frame = NSRect(x: 60, y: size.height * 0.36, width: size.width - 120, height: 64)
    }
    private func configureToolbar() {
        for b in [searchButton, more] { b.bezelStyle = .accessoryBarAction; b.isBordered = false; b.imagePosition = .imageOnly; b.target = self; toolbar.addSubview(b) }
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索"); searchButton.action = #selector(toggleSearch); searchButton.toolTip = "搜索（⌘F）"
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多"); more.action = #selector(showMore); more.toolTip = "更多操作"
        search.placeholderString = "搜索内容、来源或文件名"; search.delegate = self; search.sendsSearchStringImmediately = true
        toolbar.addSubview(search)
        filter.isBordered = false; filter.imagePosition = .imageOnly; filter.pullsDown = true; filter.addItem(withTitle: "")
        filter.item(at: 0)?.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "筛选")
        filter.target = self; filter.action = #selector(filterChanged); filter.toolTip = "筛选类型、来源与时间"; filter.menu?.delegate = self; toolbar.addSubview(filter)
        tabs.orientation = .horizontal; tabs.spacing = 6; tabs.alignment = .centerY
        tabsScroll.drawsBackground = false; tabsScroll.hasHorizontalScroller = false; tabsScroll.documentView = tabs
        toolbar.addSubview(tabsScroll)
    }
    @discardableResult private func buildTabs() -> Bool {
        let signature = [board?.uuidString ?? "history"] + store.boards.map { "\($0.id)|\($0.name)|\($0.color)" }
        guard signature != tabSignature else { return false }
        tabSignature = signature
        tabs.arrangedSubviews.forEach { tabs.removeArrangedSubview($0); $0.removeFromSuperview() }
        let history = BoardButton(title: "剪贴板", image: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil), board: nil, shelf: self)
        history.state = board == nil ? .on : .off; history.isBordered = board == nil; tabs.addArrangedSubview(history)
        for b in store.boards {
            let button = BoardButton(title: b.name, image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil), board: b.id, shelf: self)
            button.contentTintColor = boardColors[abs(b.color) % boardColors.count]; button.state = board == b.id ? .on : .off; button.isBordered = board == b.id
            tabs.addArrangedSubview(button)
        }
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新建分组")!, target: self, action: #selector(newBoard))
        add.isBordered = false; add.bezelStyle = .accessoryBarAction; add.toolTip = "新建收藏分组（⇧⌘N）"; tabs.addArrangedSubview(add)
        return true
    }
    func present() {
        dragSource?.cancelPendingDrag()
        actions.invalidatePendingPaste()
        guard let window, let host = window.contentView as? ShelfClipView,
              let screen = screenAtPointer() else { return }
        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let continuing = window.isVisible && presentationScreenID == screenID
        let fraction = continuing ? host.visibleFraction : 0
        slideAnimator.cancel()
        applyAppearance()
        presentationGeneration &+= 1
        shouldBePresented = true
        presentationScreenID = screenID
        presentationScreenFrame = screen.frame
        (window as? ShelfPanel)?.acceptsShelfInput = true
        window.ignoresMouseEvents = false
        window.level = isMenuOpen ? .statusBar : (isDragging ? .floating : .screenSaver)
        window.setFrame(frame(for: screen), display: false)
        refresh(); layout()
        // Rebase the pixel translation after the new display/height is laid out.
        host.setVisibleFraction(fraction)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless(); window.makeFirstResponder(collection)
        dockPresentation.begin()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        animatePresentation(to: 1)
    }

    private func screenAtPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func frame(for screen: NSScreen) -> NSRect {
        let visible = screen.frame
        let saved = UserDefaults.standard.double(forKey: "shelfHeight")
        let height = min(visible.height * 0.78, max(260, saved > 0 ? saved : 374))
        return NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
    }

    /// Logical dismissal happens now. Animation completion only removes the
    /// old visual surface; it never cancels a later paste or activation request.
    func dismiss(animated: Bool = true, restoringFocus: Bool = false) {
        dragSource?.cancelPendingDrag()
        actions.invalidatePendingPaste()
        preview?.close(); preview = nil
        guard shouldBePresented else {
            // A handoff can require an already exiting surface to vanish now.
            if !animated { window?.orderOut(nil) }
            return
        }
        shouldBePresented = false
        presentationGeneration &+= 1
        slideAnimator.cancel()
        (window as? ShelfPanel)?.acceptsShelfInput = false
        window?.ignoresMouseEvents = true
        window?.makeFirstResponder(nil)
        dockPresentation.end()
        if animated { animatePresentation(to: 0) }
        else { window?.orderOut(nil) }
        if restoringFocus { actions.restoreTargetFocus() }
    }

    private func animatePresentation(to target: CGFloat) {
        guard let window, let host = window.contentView as? ShelfClipView else { return }
        let generation = presentationGeneration
        let start = host.visibleFraction
        let baseDuration: TimeInterval = target == 1 ? 0.20 : 0.15
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 :
            min(baseDuration, max(0.05, baseDuration * Double(abs(target - start))))
        // An empty transparent viewport must not leave a full-size shadow.
        // Restore the normal panel shadow as soon as the entrance finishes.
        window.hasShadow = false
        guard let layer = host.layer else { host.setVisibleFraction(target); return }
        // Submit once to the compositor. No NSView movement, text layout, or
        // main-thread callback is needed for the intermediate frames.
        slideAnimator.animate(layer: layer, from: -(1 - start) * host.bounds.height,
                              to: -(1 - target) * host.bounds.height, duration: duration,
                              curve: target == 1 ? .easeOut : .easeIn,
                              completion: { [weak self, weak window] in
            guard let self, generation == self.presentationGeneration else { return }
            if self.shouldBePresented {
                window?.hasShadow = true
                window?.invalidateShadow()
                self.drainDeferredRefresh()
            } else {
                window?.orderOut(nil)
            }
        })
    }

    private func panelWillHide() {
        // This also handles native close and external-drag exits. Do not touch
        // pending paste generation here: it can belong to a newer request.
        shouldBePresented = false
        presentationGeneration &+= 1
        slideAnimator.cancel()
        (window as? ShelfPanel)?.acceptsShelfInput = false
        window?.ignoresMouseEvents = true
        (window?.contentView as? ShelfClipView)?.setVisibleFraction(0)
        window?.hasShadow = true
        dockPresentation.end()
        drainDeferredRefresh()
    }

    func prepareForResize() {
        guard shouldBePresented else { return }
        presentationGeneration &+= 1
        slideAnimator.cancel()
        (window?.contentView as? ShelfClipView)?.setVisibleFraction(1)
        window?.hasShadow = true
        drainDeferredRefresh()
    }

    @objc private func screenParametersChanged() {
        guard window?.isVisible == true else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == presentationScreenID
        } ?? screenAtPointer()
        guard let screen, screen.frame != presentationScreenFrame else { return }
        guard shouldBePresented else { window?.orderOut(nil); return }
        prepareForResize()
        presentationScreenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        presentationScreenFrame = screen.frame
        window?.setFrame(frame(for: screen), display: true)
        layout()
    }

    @objc private func motionPreferenceChanged() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, slideAnimator.isAnimating else { return }
        slideAnimator.cancel()
        if shouldBePresented { prepareForResize() }
        else { window?.orderOut(nil) }
    }
    func beginDrag(from source: ClipCard) {
        isDragging = true; dragSource = source
        // Native dragging images sit below screenSaver-level windows. Lower the
        // shelf before AppKit creates its drag window, keeping internal targets
        // visible and usable without covering the dragged card.
        window?.level = .floating
    }
    func trackDrag(_ session: NSDraggingSession, at screenPoint: NSPoint) {
        guard isDragging else { return }
        dragSession = session
        hideDuringExternalDrag(at: screenPoint)
    }
    func hideDuringExternalDrag(at screenPoint: NSPoint) {
        guard isDragging, let window, window.isVisible, !NSMouseInRect(screenPoint, window.frame, false) else { return }
        // Keep the drag source/session, preview, and pending actions alive. A
        // cancelled drag stays hidden until the user opens the shelf again.
        window.orderOut(nil)
    }
    func finishDrag() {
        // Restore even after orderOut, cancellation, or an internal board drop.
        window?.level = .screenSaver
        isDragging = false; dragSession = nil; dragSource = nil
        drainDeferredRefresh()
    }
    @objc private func scrollStarted() { isLiveScrolling = true }
    @objc private func scrollEnded() { isLiveScrolling = false; drainDeferredRefresh() }
    private func drainDeferredRefresh() {
        if !isInteracting, appearanceNeedsUpdate { applyAppearance() }
        guard refreshAfterInteraction, !isInteracting else { return }
        refreshAfterInteraction = false
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    func deferCardRefreshIfAnimating() -> Bool {
        guard slideAnimator.isAnimating else { return false }
        refreshAfterInteraction = true
        return true
    }
    private func invalidateSearch() {
        searchGeneration &+= 1
        searchToken?.cancel(); searchToken = nil
    }
    func refresh() {
        invalidateSearch()
        if isInteracting { refreshAfterInteraction = true; return }
        refreshAfterInteraction = false
        // Keep the cached hierarchy for unchanged IDs. Store notifications often
        // describe persistence/indexing, rather than a new visible card.
        if buildTabs() { layout() }
        filter.contentTintColor = kind != "全部" || source != "全部" || days > 0 ? .controlAccentColor : .secondaryLabelColor
        let query = search.stringValue
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyResults(store.search(query: query, kind: kind, app: source, days: days))
        } else {
            let generation = searchGeneration
            searchToken = store.searchAsync(query: query, kind: kind, app: source, days: days) { [weak self] items in
                guard let self, self.searchGeneration == generation else { return }
                self.searchToken = nil
                if self.isInteracting { self.refreshAfterInteraction = true; return }
                self.applyResults(items)
            }
        }
    }
    private func applyResults(_ results: [Clip]) {
        var items = results
        if search.stringValue.isEmpty, let board {
            items = items.filter { $0.boardIDs.contains(board) }
            let order = store.boards.first(where: { $0.id == board })?.itemIDs ?? []
            let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            items.sort { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
        }
        let oldIDs = visibleItems.map(\.id)
        let newIDs = items.map(\.id)
        visibleItems = items
        selection.formIntersection(Set(newIDs))
        if selection.isEmpty, let first = visibleItems.first { selection = [first.id]; anchor = first.id }
        if oldIDs != newIDs {
            collection.reloadData()
        } else {
            // Reconfigure only on-screen cards. Each card compares its small
            // display signature; unchanged content keeps its layer contents.
            for item in collection.visibleItems() {
                guard let item = item as? CardItem, let index = collection.indexPath(for: item)?.item,
                      index < visibleItems.count else { continue }
                let clip = visibleItems[index]
                item.card.configure(clip, selected: selection.contains(clip.id), number: index < 9 ? index + 1 : nil, shelf: self)
            }
        }
        empty.isHidden = !visibleItems.isEmpty
        empty.stringValue = search.stringValue.isEmpty && kind == "全部" && source == "全部" && days == 0 ? (board == nil ? "复制一些内容，就会出现在这里\n文本、图片、链接和文件 · ⇧⌘V 随时唤出" : "把卡片拖到这里，留住常用内容") : "没有找到匹配的内容\n试试其他关键词或清除筛选"
    }
    func chooseBoard(_ id: UUID?) { board = id; search.stringValue = ""; kind = "全部"; source = "全部"; days = 0; selection = []; refresh(); scroll.contentView.scroll(to: .zero) }
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { visibleItems.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: cardIdentifier, for: indexPath) as! CardItem
        let c = visibleItems[indexPath.item]; item.card.configure(c, selected: selection.contains(c.id), number: indexPath.item < 9 ? indexPath.item + 1 : nil, shelf: self)
        return item
    }
    func select(_ c: Clip, event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.shift), let anchor, let a = visibleItems.firstIndex(where: { $0.id == anchor }), let b = visibleItems.firstIndex(where: { $0.id == c.id }) {
            selection = Set(visibleItems[min(a,b)...max(a,b)].map(\.id))
        } else if flags.contains(.command) { if selection.contains(c.id) { selection.remove(c.id) } else { selection.insert(c.id) }; anchor = c.id }
        else { selection = [c.id]; anchor = c.id }
        updateSelection()
    }
    private func updateSelection() {
        for item in collection.visibleItems() { if let card = (item as? CardItem)?.card, let c = card.clip { card.selected = selection.contains(c.id) } }
    }
    func pasteSelection(plain: Bool = false) { let clips = selectedClips; if !clips.isEmpty { actions.paste(clips, plain) } }
    private func move(_ step: Int, extend: Bool) {
        guard !visibleItems.isEmpty else { return }
        let current = visibleItems.firstIndex { $0.id == anchor } ?? 0
        let next = min(visibleItems.count - 1, max(0, current + step)); let c = visibleItems[next]
        if extend { selection.insert(c.id) } else { selection = [c.id] }; anchor = c.id; updateSelection()
        collection.scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }
    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        let key = e.charactersIgnoringModifiers ?? ""
        let editing = window?.firstResponder is NSTextView
        if e.keyCode == 53 { if hasSearch && (!search.stringValue.isEmpty || kind != "全部" || source != "全部" || days != 0) { search.stringValue = ""; kind = "全部"; source = "全部"; days = 0; refresh() } else if hasSearch { hasSearch = false; layout(); window?.makeFirstResponder(collection) } else { dismiss(restoringFocus: true) }; return true }
        if cmd {
            if e.keyCode == 123 || e.keyCode == 124 {
                let boards: [UUID?] = [nil] + store.boards.map { Optional($0.id) }
                let current = boards.firstIndex(where: { $0 == board }) ?? 0
                let step = e.keyCode == 123 ? -1 : 1
                chooseBoard(boards[(current + step + boards.count) % boards.count]); return true
            }
            if let number = Int(key), (1...9).contains(number), visibleItems.count >= number { actions.paste([visibleItems[number - 1]], shift); return true }
            switch key.lowercased() {
            case "f": focusSearch(); return true
            case "a" where !editing: selection = Set(visibleItems.map(\.id)); updateSelection(); return true
            case "c" where !editing: actions.copy(selectedClips, false); return true
            case "e" where !editing: if let c = selectedClips.first { edit(c) }; return true
            case "r" where !editing: if let c = selectedClips.first { rename(c) }; return true
            case "n": if shift { newBoard() } else { edit(nil) }; return true
            default: break
            }
        }
        if e.keyCode == 36 || e.keyCode == 76 { if editing { window?.makeFirstResponder(collection) } else { pasteSelection(plain: shift) }; return true }
        if editing { return false }
        if e.keyCode == 123 || e.keyCode == 126 { move(-1, extend: shift); return true }
        if e.keyCode == 124 || e.keyCode == 125 { move(1, extend: shift); return true }
        if e.keyCode == 49 { if let c = selectedClips.first { showPreview(c) }; return true }
        if e.keyCode == 51 || e.keyCode == 117 { deleteSelection(); return true }
        if e.keyCode == 48 { focusSearch(); return true }
        if !cmd, !e.modifierFlags.contains(.control), let chars = e.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { focusSearch(); search.stringValue += chars; refresh(); return true }
        return false
    }
    @objc private func toggleSearch() { if hasSearch { hasSearch = false; search.stringValue = ""; kind = "全部"; source = "全部"; days = 0; refresh(); layout(); window?.makeFirstResponder(collection) } else { focusSearch() } }
    private func focusSearch() { hasSearch = true; layout(); window?.makeFirstResponder(search) }
    func controlTextDidChange(_ obj: Notification) {
        invalidateSearch(); searchWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.refresh() }; searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === filter.menu { rebuildFilters() }
    }
    private func rebuildFilters() {
        while filter.numberOfItems > 1 { filter.removeItem(at: 1) }
        let menu = filter.menu!
        func section(_ title: String, options: [String], selected: String, apply: @escaping (String) -> Void) {
            menu.addItem(.separator()); let heading = NSMenuItem(title: title, action: nil, keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
            for value in options { let i = menu.addAction(value) { [weak self] in apply(value); self?.refresh() }; i.state = selected == value ? .on : .off }
        }
        section("类型", options: ["全部", "文本", "富文本", "图片", "文件", "链接", "PDF", "数据"], selected: kind) { [weak self] in self?.kind = $0 }
        section("来源", options: ["全部"] + Array(Set(store.clips.map(\.source))).sorted(), selected: source) { [weak self] in self?.source = $0 }
        section("时间", options: ["全部", "今天", "最近 7 天", "最近 30 天"], selected: days == 0 ? "全部" : days == 1 ? "今天" : "最近 \(days) 天") { [weak self] in self?.days = $0 == "全部" ? 0 : $0 == "今天" ? 1 : $0.contains("7") ? 7 : 30 }
        filter.contentTintColor = kind != "全部" || source != "全部" || days > 0 ? .controlAccentColor : .secondaryLabelColor
    }
    @objc private func filterChanged() {}
    @objc private func showMore() {
        let menu = NSMenu()
        menu.addAction("新建文本…", key: "n") { [weak self] in self?.edit(nil) }
        menu.addAction(actions.isPaused() ? "继续记录" : "暂停记录") { [weak self] in self?.actions.pauseToggle() }
        menu.addAction(actions.isStack() ? "结束连续粘贴" : "开始连续粘贴  ⇧⌘C") { [weak self] in self?.actions.stackToggle() }
        menu.addItem(.separator())
        menu.addAction("导出备份…") { [weak self] in self?.actions.export() }
        menu.addAction("导入备份…") { [weak self] in self?.actions.import() }
        menu.addAction("清除历史记录…") { [weak self] in self?.actions.clear() }
        menu.addItem(.separator()); menu.addAction("设置…", key: ",") { [weak self] in self?.actions.settings() }
        menu.addAction("退出 Prism", key: "q") { [weak self] in self?.actions.quit() }
        window?.level = .statusBar
        defer { if window?.isVisible == true { window?.level = isDragging ? .floating : .screenSaver } }
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.minY), in: toolbar)
    }
    func contextMenu(_ c: Clip) -> NSMenu {
        if !selection.contains(c.id) { selection = [c.id]; anchor = c.id; updateSelection() }
        let menu = NSMenu()
        let target = actions.targetName()
        let paste = menu.addAction(target.isEmpty ? "粘贴" : "粘贴到 \(target)", key: "\r") { [weak self] in self?.pasteSelection() }
        paste.keyEquivalentModifierMask = []
        let plain = menu.addAction("以纯文本粘贴", key: "\r") { [weak self] in self?.pasteSelection(plain: true) }
        plain.keyEquivalentModifierMask = [.shift]; plain.isEnabled = ["文本", "富文本", "链接", "文件"].contains(c.kind) || (c.kind == "图片" && !c.recognizedText.isEmpty)
        menu.addAction("复制", key: "c") { [weak self] in guard let self else { return }; self.actions.copy(self.selectedClips, false) }
        menu.addItem(.separator())
        menu.addAction("编辑", key: "e") { [weak self] in self?.edit(c) }.isEnabled = ["文本", "富文本", "链接", "图片"].contains(c.kind)
        menu.addAction("重命名", key: "r") { [weak self] in self?.rename(c) }
        let delete = menu.addAction("删除", key: "\u{8}") { [weak self] in self?.deleteSelection() }; delete.keyEquivalentModifierMask = []
        menu.addItem(.separator())
        let pin = NSMenuItem(title: "固定", action: nil, keyEquivalent: ""); let submenu = NSMenu()
        for b in store.boards { let item = submenu.addAction(b.name) { [weak self] in guard let self else { return }; self.store.pin(self.selection, board: b.id) }; item.state = c.boardIDs.contains(b.id) ? .on : .off }
        if !c.boardIDs.isEmpty { submenu.addAction("取消固定") { [weak self] in guard let self else { return }; self.store.pin(self.selection, board: self.board, remove: true) }; submenu.addItem(.separator()) }
        submenu.addAction("新建分组…") { [weak self] in self?.newBoard() }; pin.submenu = submenu; menu.addItem(pin)
        menu.addItem(.separator())
        let preview = menu.addAction("预览", key: " ") { [weak self] in self?.showPreview(c) }; preview.keyEquivalentModifierMask = []
        menu.addAction("分享…") { [weak self] in self?.share(c) }
        let more = NSMenuItem(title: "更多", action: nil, keyEquivalent: ""); let extra = NSMenu()
        extra.addAction("加入连续粘贴") { [weak self] in guard let self else { return }; self.actions.enqueue(self.selectedClips) }
        if (c.kind == "图片" && !c.recognizedText.isEmpty) { extra.addAction("复制图片中的文字") { [weak self] in guard let self else { return }; let text = Clip(source: "Prism", bundle: "local.prism.clipboard", payloads: [Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data(c.recognizedText.utf8)])]); self.actions.copy([text], true) } }
        if !c.files.isEmpty { extra.addAction("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(c.files) } }
        if c.kind == "链接", let url = URL(string: c.text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { extra.addAction("打开链接") { NSWorkspace.shared.open(url) } }
        more.submenu = extra; menu.addItem(more)
        return menu
    }
    private var sharingPicker: NSSharingServicePicker?
    private func share(_ c: Clip) {
        let id = c.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var items: [Any] = []
            if !c.files.isEmpty { items = c.files }
            else if c.kind == "图片", let payloads = try? c.loadPayloads(), let bytes = payloads.compactMap({ $0.data(.png) ?? $0.data(.tiff) }).first, let image = NSImage(data: bytes) { items = [image] }
            else if c.kind == "链接", let url = URL(string: c.text) { items = [url] }
            else if !c.text.isEmpty { items = [c.text] }
            DispatchQueue.main.async {
                guard let self, !items.isEmpty else { return }
                let card = self.collection.visibleItems().compactMap { ($0 as? CardItem)?.card }.first { $0.clip?.id == id }
                let view = card ?? self.collection
                self.window?.level = .statusBar
                self.sharingPicker = NSSharingServicePicker(items: items)
                self.sharingPicker?.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            }
        }
    }
    private func deleteSelection() { if let board { store.pin(selection, board: board, remove: true) } else { store.remove(selection) }; selection = []; refresh() }
    @discardableResult func receive(_ pasteboard: NSPasteboard, board: UUID?) -> Bool {
        if let data = pasteboard.string(forType: clipIDType) {
            let ids = Set(data.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            if let board { store.pin(ids, board: board) }
            return !ids.isEmpty
        }
        guard let c = ClipStore.read(pasteboard, source: "拖入的内容", bundle: "") else { return false }
        store.add(c, board: board); return true
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation { .copy }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        if let board, let value = draggingInfo.draggingPasteboard.string(forType: clipIDType) {
            let ids = value.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            store.pin(Set(ids), board: board)
            let before = indexPath.item < visibleItems.count ? visibleItems[indexPath.item].id : nil
            store.reorder(ids: ids, board: board, before: before); return true
        }
        return receive(draggingInfo.draggingPasteboard, board: board)
    }
    func moveBoard(_ moving: UUID, before target: UUID?) {
        guard moving != target, let index = store.boards.firstIndex(where: { $0.id == moving }) else { return }
        let b = store.boards.remove(at: index)
        let destination = target.flatMap { target in store.boards.firstIndex(where: { $0.id == target }) } ?? store.boards.count
        store.boards.insert(b, at: destination); store.save()
    }
    @objc func newBoard() {
        guard let value = ask("新建分组", value: "", placeholder: "分组名称"), !value.isEmpty else { return }
        let new = Board(name: value, color: store.boards.count % boardColors.count); store.boards.append(new); store.save(); chooseBoard(new.id)
    }
    func renameBoard(_ id: UUID) {
        guard let i = store.boards.firstIndex(where: { $0.id == id }), let name = ask("重命名分组", value: store.boards[i].name), !name.isEmpty else { return }
        store.boards[i].name = name; store.save()
    }
    func deleteBoard(_ id: UUID) {
        let alert = NSAlert(); alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1); alert.messageText = "删除这个分组？"; alert.informativeText = "其中的记录仍会保留在剪贴板历史中。"; alert.addButton(withTitle: "删除分组"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.boards.removeAll { $0.id == id }; store.pin(Set(store.clips.filter { $0.boardIDs.contains(id) }.map(\.id)), board: id, remove: true)
        if board == id { board = nil }; store.save()
    }
    private func ask(_ title: String, value: String, placeholder: String = "") -> String? {
        let alert = NSAlert(); alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1); alert.messageText = title
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 320, height: 26); field.placeholderString = placeholder
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    func rename(_ c: Clip) { if let title = ask("重命名", value: c.title, placeholder: c.heading) { var c = c; c.title = title; store.update(c) } }
    func edit(_ clip: Clip?) {
        dismiss(animated: false)
        let commit: ([Payload]) -> Void = { [weak self] payloads in
            guard let self else { return }
            var c = Clip(source: clip?.source ?? "Prism", bundle: clip?.bundle ?? "local.prism.clipboard", payloads: payloads)
            if let clip { c.id = clip.id; c.date = clip.date; c.title = clip.title; c.boardIDs = clip.boardIDs; self.store.update(c) } else { self.store.add(c, board: self.board) }
        }
        let editor: NSWindowController
        if let clip, clip.kind == "图片" { editor = ImageEditorController(clip: clip, onSave: commit) }
        else { editor = EditorController(clip: clip, onSave: commit) }
        preview = editor; editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
    }
    func showPreview(_ c: Clip) { dismiss(animated: false); let p = PreviewController(clip: c); preview = p; p.showWindow(nil); p.window?.makeKeyAndOrderFront(nil) }

}

final class CardItem: NSCollectionViewItem {
    var card: ClipCard { view as! ClipCard }
    override func loadView() { view = ClipCard() }
    override func prepareForReuse() { super.prepareForReuse(); card.reset() }
}
/// One text layout per reused card, sized to the visible body. Selection never
/// invalidates this layout or the card backing store.
private final class CardTextLayout {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()
    private var size = NSSize.zero
    init() {
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        manager.allowsNonContiguousLayout = true
        manager.addTextContainer(container); storage.addLayoutManager(manager)
    }
    func setText(_ text: String) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]))
    }
    func draw(in rect: NSRect) {
        if size != rect.size { size = rect.size; container.containerSize = size }
        let range = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: range, at: rect.origin)
        manager.drawGlyphs(forGlyphRange: range, at: rect.origin)
    }
}

final class ClipCard: NSView, NSDraggingSource {
    private let selectionBorder = CAShapeLayer()
    private let bodyText = CardTextLayout()
    private var layoutSize = NSSize.zero
    private var relativeText = ""
    private var footerText = ""
    private var deferredContentUpdate = false
    private var cardAccent = NSColor.systemBlue
    private var appearanceSettings = PrismAppearanceSettings.default
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.22, green: 0.29, blue: 0.43, alpha: 1),
        NSColor(srgbRed: 0.31, green: 0.43, blue: 0.54, alpha: 1),
        NSColor(srgbRed: 0.29, green: 0.43, blue: 0.41, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.37, blue: 0.52, alpha: 1)
    ]
    private static let symbols: [String: NSImage] = {
        let names = ["doc.fill", "photo.fill", "link", "text.alignleft", "photo", "doc.richtext", "doc", "doc.on.clipboard", "pin.fill"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil).map { (name, $0) }
        })
    }()
    private static let headerSymbols: [String: NSImage] = {
        symbols.compactMapValues { $0.withSymbolConfiguration(.init(pointSize: 18, weight: .medium).applying(.init(paletteColors: [.white]))) }
    }()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 3; layer?.shadowOffset = NSSize(width: 0, height: -1)
        selectionBorder.fillColor = nil; selectionBorder.lineWidth = 2; selectionBorder.isHidden = true
        layer?.addSublayer(selectionBorder)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityHelp("按回车粘贴，空格预览。可以拖到其他应用或收藏分组。")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        if layoutSize != bounds.size { layoutSize = bounds.size; needsDisplay = true }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionBorder.frame = bounds
        selectionBorder.path = CGPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), cornerWidth: 15, cornerHeight: 15, transform: nil)
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), cornerWidth: 14, cornerHeight: 14, transform: nil)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        bodyText.setText(String(clip?.textPreview.prefix(3000) ?? ""))
        updateSelectionBorder(); needsDisplay = true
    }
    var clip: Clip?; weak var shelf: ShelfController?
    var selected = false { didSet { if oldValue != selected { updateSelectionBorder() } } }
    var number: Int?
    private var thumbnail: NSImage?; private var icon: NSImage?; private var mouseOrigin = NSPoint.zero
    private var isDrag = false; private var deferredClick: NSEvent?; private var generation = UUID()
    private var loading: Operation?; private var iconLoading: Operation?
    private var pendingDoubleClick: Bool?
    private var dragShelf: ShelfController?
    private var pendingDragID: UUID?
    private var pendingDragEvent: NSEvent?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    private func updateSelectionBorder() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionBorder.strokeColor = NSColor.controlAccentColor.cgColor
        selectionBorder.isHidden = !selected
        CATransaction.commit()
        setAccessibilityValue(selected ? "已选中" : "")
    }
    func reset() {
        cancelPendingDrag()
        loading?.cancel(); iconLoading?.cancel(); loading = nil; iconLoading = nil
        generation = UUID(); clip = nil; thumbnail = nil; icon = nil; shelf = nil
        pendingDoubleClick = nil; number = nil; selected = false; deferredContentUpdate = false; bodyText.setText("")
    }
    func configure(_ c: Clip, selected: Bool, number: Int?, shelf: ShelfController) {
        let old = clip
        let isNew = old?.id != c.id || old?.fingerprint != c.fingerprint || old?.bundle != c.bundle
        let elapsed = max(0, Int(-c.date.timeIntervalSinceNow))
        let relative = elapsed < 60 ? "刚刚" : elapsed < 3600 ? "\(elapsed / 60) 分钟前" : elapsed < 86400 ? "\(elapsed / 3600) 小时前" : "\(elapsed / 86400) 天前"
        let appearanceChanged = appearanceSettings != shelf.appearanceSettings
        appearanceSettings = shelf.appearanceSettings
        let contentChanged = isNew || appearanceChanged || old?.heading != c.heading || old?.textPreview != c.textPreview ||
            old?.boardIDs != c.boardIDs || old?.characterCount != c.characterCount || old?.isIndexed != c.isIndexed ||
            relativeText != relative || self.number != number
        clip = c; self.selected = selected; self.number = number; self.shelf = shelf
        if contentChanged {
            relativeText = relative
            bodyText.setText(String(c.textPreview.prefix(3000)))
            if c.kind == "文件" { footerText = c.files.first?.lastPathComponent ?? "文件" }
            else if ["文本", "富文本", "链接"].contains(c.kind) { footerText = c.isIndexed ? "\(c.characterCount.formatted()) 个字符" : "正在索引…" }
            else { footerText = ByteCountFormatter.string(fromByteCount: Int64(c.byteCount), countStyle: .file) }
            var value: UInt64 = 5381; for b in c.bundle.utf8 { value = value &* 33 &+ UInt64(b) }
            let originalAccent = c.kind == "文件" ? NSColor(srgbRed: 0.28, green: 0.43, blue: 0.65, alpha: 1) : Self.palette[Int(value % UInt64(Self.palette.count))]
            cardAccent = appearanceSettings.headerColor(fallback: originalAccent)
            setAccessibilityLabel("\(c.heading)，\(c.source)，\(c.textPreview.prefix(100))")
            needsDisplay = true
        }
        if deferredContentUpdate { deferredContentUpdate = false; needsDisplay = true }
        if isNew {
            loading?.cancel(); iconLoading?.cancel(); thumbnail = nil; icon = nil
            generation = UUID(); let token = generation
            if ["图片", "PDF", "文件"].contains(c.kind) {
                loading = ThumbnailCache.shared.load(c) { [weak self] image in
                    guard let self, self.generation == token else { return }
                    self.loading = nil
                    if let image { self.thumbnail = image; self.imageDidLoad() }
                }
            }
            if !c.bundle.isEmpty {
                iconLoading = ThumbnailCache.shared.icon(c.bundle) { [weak self] image in
                    guard let self, self.generation == token else { return }
                    self.iconLoading = nil
                    if let image { self.icon = image; self.imageDidLoad() }
                }
            }
        }
    }
    private func imageDidLoad() {
        if shelf?.deferCardRefreshIfAnimating() == true { deferredContentUpdate = true }
        else { needsDisplay = true }
    }
    override func accessibilityPerformPress() -> Bool { guard let clip, let shelf else { return false }; shelf.actions.paste([clip], false); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = clip else { return }
        let frame = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
        NSColor.controlBackgroundColor.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState(); path.addClip()
        let header = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 55)
        cardAccent.setFill(); header.fill()
        drawText(c.heading, rect: NSRect(x: frame.minX + 15, y: frame.minY + 10, width: frame.width - 67, height: 21), size: 14.5, weight: .semibold, color: .white)
        drawText(relativeText, rect: NSRect(x: frame.minX + 15, y: frame.minY + 32, width: frame.width - 67, height: 16), size: 11, color: .white.withAlphaComponent(0.85))
        let iconRect = NSRect(x: frame.maxX - 47, y: frame.minY + 11, width: 32, height: 32)
        if let icon {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium])
        } else {
            let symbol = c.kind == "文件" ? "doc.fill" : c.kind == "图片" ? "photo.fill" : c.kind == "链接" ? "link" : "text.alignleft"
            NSColor.white.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: iconRect, xRadius: 8, yRadius: 8).fill()
            Self.headerSymbols[symbol]?.draw(in: iconRect.insetBy(dx: 7, dy: 7), from: .zero, operation: .sourceOver, fraction: 0.95, respectFlipped: true, hints: nil)
        }
        let body = NSRect(x: frame.minX + 15, y: header.maxY + 14, width: frame.width - 30, height: max(0, frame.height - 100))
        if let thumbnail {
            if c.kind == "图片" { drawChecker(body) }
            let ratio = min(body.width / max(1, thumbnail.size.width), body.height / max(1, thumbnail.size.height))
            let size = NSSize(width: thumbnail.size.width * ratio, height: thumbnail.size.height * ratio)
            let rect = NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height)
            thumbnail.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium])
        } else if ["文本", "富文本", "链接"].contains(c.kind) {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: body).addClip()
            bodyText.draw(in: body)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let symbol = c.kind == "图片" ? "photo" : c.kind == "PDF" ? "doc.richtext" : c.kind == "文件" ? "doc" : "doc.on.clipboard"
            Self.symbols[symbol]?.draw(in: NSRect(x: body.midX - 25, y: body.midY - 28, width: 50, height: 56), from: .zero, operation: .sourceOver, fraction: 0.32, respectFlipped: true, hints: nil)
        }
        drawText(footerText, rect: NSRect(x: frame.minX + 15, y: frame.maxY - 25, width: frame.width - 62, height: 17), size: 11, color: .secondaryLabelColor)
        if !c.boardIDs.isEmpty { Self.symbols["pin.fill"]?.draw(in: NSRect(x: frame.maxX - 48, y: frame.maxY - 23, width: 11, height: 11), from: .zero, operation: .sourceOver, fraction: 0.55, respectFlipped: true, hints: nil) }
        if let number { drawText("\(number)", rect: NSRect(x: frame.maxX - 29, y: frame.maxY - 25, width: 17, height: 17), size: 11, weight: .medium, color: .tertiaryLabelColor, alignment: .right) }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke(); path.lineWidth = 0.5; path.stroke()
    }
    private func drawChecker(_ rect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.14).setFill()
        let checker = NSBezierPath()
        for y in stride(from: rect.minY, to: rect.maxY, by: 12) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 12) where (Int((x-rect.minX)/12) + Int((y-rect.minY)/12)) % 2 == 0 {
                checker.appendRect(NSRect(x: x, y: y, width: min(12, rect.maxX-x), height: min(12, rect.maxY-y)))
            }
        }
        checker.fill()
    }
    private func drawText(_ text: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func mouseDown(with event: NSEvent) {
        cancelPendingDrag()
        guard let clip else { return }; mouseOrigin = convert(event.locationInWindow, from: nil); isDrag = false
        deferredClick = nil; pendingDoubleClick = nil
        let hasModifier = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        if !hasModifier, let shelf, shelf.selectedClips.count > 1, shelf.selectedClips.contains(where: { $0.id == clip.id }) { deferredClick = event }
        else { shelf?.select(clip, event: event) }
        // A second mouse-down can still become a double-click-and-drag.
        if event.clickCount == 2 { pendingDoubleClick = event.modifierFlags.contains(.shift) }
    }
    override func mouseUp(with event: NSEvent) {
        if pendingDragID != nil {
            cancelPendingDrag(); deferredClick = nil; pendingDoubleClick = nil
            return
        }
        if !isDrag, let plain = pendingDoubleClick {
            pendingDoubleClick = nil; deferredClick = nil
            shelf?.pasteSelection(plain: plain); return
        }
        if !isDrag, let click = deferredClick, let clip { shelf?.select(clip, event: click) }
        deferredClick = nil; pendingDoubleClick = nil
    }
    override func mouseDragged(with event: NSEvent) {
        if pendingDragID != nil { pendingDragEvent = event; return }
        let point = convert(event.locationInWindow, from: nil)
        guard !isDrag, hypot(point.x - mouseOrigin.x, point.y - mouseOrigin.y) > 5, let shelf else { return }
        isDrag = true; deferredClick = nil; pendingDoubleClick = nil
        let clips = shelf.selectedClips
        let items: [NSPasteboardWriting]
        do { items = try clips.flatMap { try $0.pasteboardWriters(forDragging: true) } }
        catch { isDrag = false; shelf.actions.reportError("无法拖出记录：\(error.localizedDescription)"); return }
        guard !items.isEmpty else { isDrag = false; return }
        let clipIDs = clips.map { $0.id.uuidString }.joined(separator: ",")
        let request = UUID()
        pendingDragID = request; pendingDragEvent = event
        // Protect the source during asynchronous disk preparation just as during
        // the native session. Never start a session after release/cancel/reuse.
        dragShelf = shelf; shelf.beginDrag(from: self)
        ImageDragPreparation.prepare(items) { [weak self] result in
            guard let self, self.pendingDragID == request else { return }
            guard self.dragShelf === shelf, shelf.shouldBePresented,
                  NSEvent.pressedMouseButtons & 1 != 0, let latestEvent = self.pendingDragEvent else {
                self.cancelPendingDrag(); return
            }
            switch result {
            case .failure(let error):
                self.cancelPendingDrag()
                shelf.actions.reportError("无法准备图片拖放：\(error.localizedDescription)")
            case .success(let writers):
                self.pendingDragID = nil; self.pendingDragEvent = nil
                self.beginPreparedDrag(writers, clipIDs: clipIDs, event: latestEvent, shelf: shelf)
            }
        }
    }
    fileprivate func cancelPendingDrag() {
        guard pendingDragID != nil else { return }
        pendingDragID = nil; pendingDragEvent = nil; isDrag = false
        dragShelf?.finishDrag(); dragShelf = nil
    }
    private func beginPreparedDrag(_ writers: [NSPasteboardWriting], clipIDs: String, event: NSEvent, shelf: ShelfController) {
        var items = writers
        guard !items.isEmpty else { isDrag = false; shelf.finishDrag(); dragShelf = nil; return }
        if let promise = items[0] as? ImageDragPromiseProvider {
            // Keep the provider itself on the pasteboard; AppKit owns its native
            // promise lifecycle, including writes requested after mouse-up.
            promise.clipIDs = clipIDs
        } else {
            items[0] = ClipDragWriter(writer: items[0], clipIDs: clipIDs)
        }
        let dragImage = NSImage(size: bounds.size); dragImage.lockFocus(); displayIgnoringOpacity(bounds, in: NSGraphicsContext.current!); dragImage.unlockFocus()
        let dragging = items.enumerated().map { index, item -> NSDraggingItem in
            let drag = NSDraggingItem(pasteboardWriter: item)
            drag.setDraggingFrame(bounds.offsetBy(dx: CGFloat(index) * 4, dy: CGFloat(index) * 4), contents: index == 0 ? dragImage : NSImage(size: NSSize(width: 1, height: 1)))
            return drag
        }
        // These mutual references last only for the drag. The collection may
        // recycle this card while the panel is hidden or a board accepts it.
        let session = beginDraggingSession(with: dragging, event: event, source: self); session.animatesToStartingPositionsOnCancelOrFail = true
        shelf.trackDrag(session, at: session.draggingLocation)
    }
    override func rightMouseDown(with event: NSEvent) { guard let clip, let shelf else { return }; shelf.showContextMenu(shelf.contextMenu(clip), event: event, view: self) }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { dragShelf?.trackDrag(session, at: session.draggingLocation) }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Judge the cursor, independent of where the card's drag image begins.
        dragShelf?.trackDrag(session, at: session.draggingLocation)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragShelf?.finishDrag(); dragShelf = nil; isDrag = false; deferredClick = nil
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

final class EditorController: NSWindowController {
    private let text = NSTextView(); private var onSave: ([Payload]) -> Void
    init(clip: Clip?, onSave: @escaping ([Payload]) -> Void) {
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = clip == nil ? "新建文本" : "编辑文本"; window.center(); window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        let host = window.contentView!
        let note = NSTextField(labelWithString: clip?.kind == "富文本" ? "保留文本格式 · 支持系统书写工具" : "文本仅保存在此 Mac 上")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 11); note.frame = NSRect(x: 20, y: 19, width: 360, height: 18); note.autoresizingMask = [.maxYMargin, .width]; host.addSubview(note)
        let save = NSButton(title: "保存", target: self, action: #selector(commit)); save.bezelStyle = .rounded; save.keyEquivalent = "\r"; save.frame = NSRect(x: 520, y: 12, width: 80, height: 32); save.autoresizingMask = [.minXMargin, .maxYMargin]; host.addSubview(save)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 588, height: 368)); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        text.frame = scroll.contentView.bounds; text.isRichText = clip?.kind == "富文本"; text.font = .systemFont(ofSize: 15); text.textContainerInset = NSSize(width: 12, height: 14); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        if let data = clip?.payloads.first?.data(.rtf), let rich = NSAttributedString(rtf: data, documentAttributes: nil) { text.textStorage?.setAttributedString(rich) }
        else if let data = clip?.payloads.first?.data(.html), let rich = NSAttributedString(html: data, documentAttributes: nil) { text.textStorage?.setAttributedString(rich) }
        else { text.string = clip?.text ?? "" }; scroll.documentView = text; host.addSubview(scroll); window.initialFirstResponder = text
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func commit() {
        var types = [NSPasteboard.PasteboardType.string.rawValue: Data(text.string.utf8)]
        if text.isRichText {
            let range = NSRange(location: 0, length: text.string.utf16.count)
            if let rtf = text.rtf(from: range) { types[NSPasteboard.PasteboardType.rtf.rawValue] = rtf }
            if let html = try? text.attributedString().data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) { types[NSPasteboard.PasteboardType.html.rawValue] = html }
        }
        onSave([Payload(types: types)]); close()
    }
}
final class PreviewController: NSWindowController, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let clip: Clip
    init(clip: Clip) {
        self.clip = clip
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = clip.title.isEmpty ? "\(clip.kind) · \(clip.source)" : clip.title; window.center()
        super.init(window: window)
        let root = window.contentView!; let area = root.bounds
        if let pdf = clip.pdf, let document = PDFDocument(data: pdf) {
            let view = PDFView(frame: area); view.document = document; view.autoScales = true; view.autoresizingMask = [.width, .height]; root.addSubview(view)
        } else if clip.kind == "图片" {
            let view = NSImageView(frame: area.insetBy(dx: 20, dy: 20)); view.imageScaling = .scaleProportionallyUpOrDown; view.autoresizingMask = [.width, .height]; root.addSubview(view)
            ThumbnailCache.shared.queue.addOperation { let image = clip.image; DispatchQueue.main.async { view.image = image } }
        } else if clip.kind == "链接", let url = URL(string: clip.text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: area, configuration: configuration); web.autoresizingMask = [.width, .height]; root.addSubview(web); web.load(URLRequest(url: url))
        } else if !clip.files.isEmpty {
            let scroll = NSScrollView(frame: area); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = NSTextView(frame: area); text.isEditable = false; text.font = .systemFont(ofSize: 15); text.textContainerInset = NSSize(width: 24, height: 24)
            text.string = clip.files.map { $0.path + (FileManager.default.fileExists(atPath: $0.path) ? "" : "  （原文件已移动或删除）") }.joined(separator: "\n\n")
            scroll.documentView = text; root.addSubview(scroll)
            let quick = NSButton(title: "快速查看文件", target: self, action: #selector(showFileQuickLook)); quick.bezelStyle = .rounded; quick.frame = NSRect(x: 24, y: 16, width: 140, height: 32); quick.autoresizingMask = [.maxYMargin]; root.addSubview(quick)
        } else {
            let scroll = NSScrollView(frame: area); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = NSTextView(frame: area); text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 15); text.textContainerInset = NSSize(width: 24, height: 24); text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
            if let rtf = clip.payloads.first?.data(.rtf), let rich = NSAttributedString(rtf: rtf, documentAttributes: nil) { text.textStorage?.setAttributedString(rich) }
            else if let html = clip.payloads.first?.data(.html), let rich = NSAttributedString(html: html, documentAttributes: nil) { text.textStorage?.setAttributedString(rich) }
            else { text.string = clip.text.isEmpty ? "\(clip.payloads.flatMap { $0.types.keys }.joined(separator: "\n"))\n\n此内容保留了原始应用的数据格式。" : clip.text }
            scroll.documentView = text; root.addSubview(scroll)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func showFileQuickLook() { guard let panel = QLPreviewPanel.shared() else { return }; panel.dataSource = self; panel.delegate = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil) }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { clip.files.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { clip.files[index] as NSURL }
    override func close() { if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.dataSource === self { QLPreviewPanel.shared()?.orderOut(nil); QLPreviewPanel.shared()?.dataSource = nil }; super.close() }
}
