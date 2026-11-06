import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

private final class PrismSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class PrismShortcutRecorder: NSButton {
    var binding: PrismHotkey { didSet { if !recording { title = binding.display } } }
    var onRecord: ((PrismHotkey) -> String?)?
    var onError: ((String) -> Void)?
    private var recording = false
    init(_ binding: PrismHotkey) {
        self.binding = binding
        super.init(frame: .zero)
        title = binding.display; bezelStyle = .rounded; font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        target = self; action = #selector(beginRecording)
        widthAnchor.constraint(equalToConstant: 155).isActive = true
        setAccessibilityLabel("录制全局快捷键，当前为 " + binding.display)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func beginRecording() { recording = true; title = "按下新快捷键…"; window?.makeFirstResponder(self) }
    override func resignFirstResponder() -> Bool { recording = false; title = binding.display; return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { recording = false; title = binding.display; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            onError?("请至少包含 Command、Control 或 Option，按 Esc 取消。"); return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let names: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        let candidate = PrismHotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label)
        if let error = onRecord?(candidate) { onError?(error) }
        else { binding = candidate; onError?("") }
        recording = false; title = binding.display
    }
}

private final class SettingsSurface: NSView {
    enum Kind { case content, group }
    private let kind: Kind
    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        if kind == .group { layer?.cornerRadius = 10; layer?.masksToBounds = true }
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { kind == .content }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor.textBackgroundColor
        let fill = kind == .content ? base : (base.blended(withFraction: 0.045, of: .labelColor) ?? .windowBackgroundColor)
        fill.setFill(); dirtyRect.fill()
    }
}

private final class SettingsIconView: NSView {
    var color = NSColor.systemGray { didSet { needsDisplay = true } }
    var symbol = "gearshape.fill" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?
            .draw(in: bounds.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private final class SettingsNavigationCell: NSTableCellView {
    let icon = SettingsIconView()
    let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        textField = label
        for child in [icon, label] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PrismSettingsController: NSWindowController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Page: Int, CaseIterable {
        case general, appearance, keyboard, privacy, storage
        var title: String {
            switch self {
            case .general: return "通用"
            case .appearance: return "外观"
            case .keyboard: return "键盘快捷键"
            case .privacy: return "隐私与规则"
            case .storage: return "存储与备份"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .appearance: return "paintpalette.fill"
            case .keyboard: return "keyboard.fill"
            case .privacy: return "hand.raised.fill"
            case .storage: return "internaldrive.fill"
            }
        }
        var color: NSColor {
            switch self {
            case .general: return .systemGray
            case .appearance: return .systemPurple
            case .keyboard: return .systemBlue
            case .privacy: return .systemBlue
            case .storage: return .systemOrange
            }
        }
        var keywords: String {
            switch self {
            case .general: return "后台 记录 采集 登录 启动 菜单栏 音效 粘贴 纯文本"
            case .appearance: return "主题 浅色 深色 系统 配色 颜色 自定义 玻璃 材质 清透 透明度 背景"
            case .keyboard: return "快捷键 键盘 录制 全局 连续粘贴 收藏板 快速粘贴"
            case .privacy: return "规则 权限 辅助功能 自动粘贴 隐私 排除 应用 密码 安全"
            case .storage: return "历史 期限 条数 磁盘 容量 存储 备份 导入 导出 清空"
            }
        }
    }
    private weak var appDelegate: PrismAppDelegate?
    private let tabs = NSTabView()
    private let navigation = NSTableView()
    private let search = NSSearchField()
    private let noMatches = NSTextField(labelWithString: "没有匹配的设置")
    private let pageTitle = NSTextField(labelWithString: "通用")
    private var filteredPages = Page.allCases
    private var currentPage = Page.general
    private var updatingNavigation = false
    private let days = NSPopUpButton()
    private let limit = NSTextField()
    private let disk = NSTextField()
    private let background = NSSwitch()
    private let menuBar = NSSwitch()
    private let sound = NSSwitch()
    private let plain = NSSwitch()
    private let login = NSSwitch()
    private let pasteTarget = NSPopUpButton()
    private let permissions = NSTextField(wrappingLabelWithString: "")
    private let excluded = NSTextView()
    private let shortcutError = NSTextField(wrappingLabelWithString: "")
    private let shelfShortcut: PrismShortcutRecorder
    private let stackShortcut: PrismShortcutRecorder
    private let appearanceMode = NSPopUpButton()
    private let cardColorMode = NSPopUpButton()
    private let cardColor = NSColorWell()
    private let glassStyle = NSPopUpButton()
    private let transparency = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let transparencyValue = NSTextField(labelWithString: "100%")
    private var updating = false

    init(owner: PrismAppDelegate) {
        appDelegate = owner
        shelfShortcut = PrismShortcutRecorder(owner.preferences.hotkey(1))
        stackShortcut = PrismShortcutRecorder(owner.preferences.hotkey(2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 870, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Prism 设置"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isOpaque = true; window.backgroundColor = .textBackgroundColor
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 800, height: 570)
        super.init(window: window)
        build()
        window.setContentSize(NSSize(width: 870, height: 660)); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func text(_ value: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        return field
    }
    private func row(_ title: String, detail: String = "", control: NSView) -> NSView {
        let labels = NSStackView(); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        let titleLabel = text(title, size: 13); titleLabel.textColor = .labelColor
        labels.addArrangedSubview(titleLabel)
        if !detail.isEmpty { labels.addArrangedSubview(text(detail)) }
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSView(); let slot = NSView()
        for view in [labels, slot] { view.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(view) }
        control.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(control)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setAccessibilityLabel(title)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.trailingAnchor.constraint(equalTo: slot.leadingAnchor, constant: -18),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
            slot.widthAnchor.constraint(equalToConstant: 180),
            slot.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            slot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            slot.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            slot.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),
            control.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: slot.leadingAnchor),
            control.topAnchor.constraint(equalTo: slot.topAnchor), control.bottomAnchor.constraint(equalTo: slot.bottomAnchor)
        ])
        return row
    }
    private func insetNote(_ value: String) -> NSView {
        let note = text(value), wrapper = NSView()
        note.translatesAutoresizingMaskIntoConstraints = false; wrapper.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor), note.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            note.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 10), note.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -10)
        ])
        return wrapper
    }
    private func group(_ views: [NSView]) -> NSView {
        let view = SettingsSurface(.group)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 3), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3)
        ])
        for (index, child) in views.enumerated() {
            if index > 0 {
                let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return view
    }
    private func page() -> (NSView, NSStackView) {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        let document = PrismSettingsDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -26)
        ])
        return (scroll, stack)
    }
    private func append(_ view: NSView, to stack: NSStackView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    private func appendAction(_ button: NSButton, to stack: NSStackView) {
        let row = NSView(); button.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor), button.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor), button.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        append(row, to: stack)
    }
    private func section(_ title: String, to stack: NSStackView) { append(text(title, size: 12, bold: true), to: stack) }
    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded
        return button
    }

    private func build() {
        guard let window else { return }
        let sidebar = NSVisualEffectView(); sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow; sidebar.state = .followsWindowActiveState
        let sidebarController = NSViewController(); sidebarController.view = sidebar
        let content = SettingsSurface(.content)
        let contentController = NSViewController(); contentController.view = content
        let split = NSSplitViewController(); split.splitView.isVertical = true; split.splitView.dividerStyle = .thin
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 220; sidebarItem.maximumThickness = 220; sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(NSSplitViewItem(viewController: contentController))
        window.contentViewController = split

        search.placeholderString = "搜索设置"; search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索设置分类"); search.setAccessibilityIdentifier("settings-search")
        search.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(search)
        navigation.style = .sourceList; navigation.headerView = nil; navigation.backgroundColor = .clear
        navigation.rowHeight = 36; navigation.intercellSpacing = NSSize(width: 0, height: 3)
        navigation.focusRingType = .none; navigation.allowsEmptySelection = true
        navigation.dataSource = self; navigation.delegate = self
        navigation.setAccessibilityLabel("设置分类"); navigation.setAccessibilityIdentifier("settings-navigation")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page")); column.resizingMask = .autoresizingMask
        navigation.addTableColumn(column); navigation.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let navScroll = NSScrollView(); navScroll.documentView = navigation; navScroll.drawsBackground = false; navScroll.hasVerticalScroller = false
        navScroll.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(navScroll)
        noMatches.font = .systemFont(ofSize: 12); noMatches.textColor = .secondaryLabelColor; noMatches.isHidden = true
        noMatches.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(noMatches)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor, constant: 18), search.heightAnchor.constraint(equalToConstant: 28),
            navScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10), navScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            navScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 18), navScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
            noMatches.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20), noMatches.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 28)
        ])
        navigation.frame = NSRect(x: 0, y: 0, width: 200, height: 210); navigation.autoresizingMask = [.width]
        pageTitle.font = .systemFont(ofSize: 20, weight: .semibold); pageTitle.textColor = .labelColor
        pageTitle.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(pageTitle)
        tabs.tabViewType = .noTabsNoBorder; tabs.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(tabs)
        NSLayoutConstraint.activate([
            pageTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26), pageTitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            pageTitle.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            tabs.topAnchor.constraint(equalTo: pageTitle.bottomAnchor, constant: 22),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26), tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        buildGeneral(); buildAppearance(); buildKeyboard(); buildPrivacy(); buildStorage()
        navigation.reloadData(); navigation.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        selectPage(.general); refreshState()
    }

    private func addTab(_ view: NSView) { let item = NSTabViewItem(); item.view = view; tabs.addTabViewItem(item) }
    private func buildGeneral() {
        let (view, root) = page()
        for control in [background, menuBar, sound, plain, login] { control.target = self; control.action = #selector(changed(_:)) }
        section("记录与启动", to: root)
        append(group([
            row("后台记录", detail: "关闭后暂停采集，已有历史仍可使用。", control: background),
            row("登录时启动", control: login),
            row("显示菜单栏图标", detail: "隐藏后仍可通过全局快捷键唤出 Prism。", control: menuBar),
            row("音效", detail: "记录新内容时播放提示音。", control: sound)
        ]), to: root)
        section("粘贴", to: root)
        pasteTarget.addItems(withTitles: ["到原活动应用", "仅复制到剪贴板"]); pasteTarget.target = self; pasteTarget.action = #selector(changed(_:))
        append(group([
            row("选择记录后", detail: "自动粘贴需要在隐私与规则中开启权限。", control: pasteTarget),
            row("始终以纯文本粘贴", detail: "富文本取正文，图片取已识别文字，文件取路径。", control: plain)
        ]), to: root)
        addTab(view)
    }
    private func buildAppearance() {
        let (view, root) = page()
        for (popup, values) in [
            (appearanceMode, PrismAppearanceSettings.Mode.allCases.map { ($0.title, $0.rawValue) }),
            (cardColorMode, PrismAppearanceSettings.CardColorMode.allCases.map { ($0.title, $0.rawValue) }),
            (glassStyle, PrismAppearanceSettings.GlassStyle.allCases.map { ($0.title, $0.rawValue) })
        ] {
            for (title, raw) in values { popup.addItem(withTitle: title); popup.lastItem?.representedObject = raw }
            popup.target = self; popup.action = #selector(appearanceChanged(_:))
        }
        appearanceMode.setAccessibilityIdentifier("appearance-mode")
        cardColorMode.setAccessibilityIdentifier("appearance-card-mode")
        glassStyle.setAccessibilityIdentifier("appearance-glass")
        cardColor.setAccessibilityIdentifier("appearance-color")
        cardColor.colorWellStyle = .minimal; cardColor.supportsAlpha = false
        cardColor.target = self; cardColor.action = #selector(appearanceChanged(_:))
        cardColor.widthAnchor.constraint(equalToConstant: 54).isActive = true; cardColor.heightAnchor.constraint(equalToConstant: 26).isActive = true
        append(group([row("外观模式", control: appearanceMode)]), to: root)
        section("卡片", to: root)
        append(group([
            row("卡片配色", control: cardColorMode),
            row("自定义颜色", detail: "标题颜色会自动保持文字清晰。", control: cardColor)
        ]), to: root)
        section("浮层背景", to: root)
        transparency.target = self; transparency.action = #selector(appearanceChanged(_:)); transparency.isContinuous = true
        transparency.setAccessibilityLabel("背景透明度"); transparency.setAccessibilityIdentifier("appearance-transparency")
        transparency.widthAnchor.constraint(equalToConstant: 126).isActive = true
        transparencyValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); transparencyValue.alignment = .right
        transparencyValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let opacityControl = NSStackView(views: [transparency, transparencyValue]); opacityControl.spacing = 8; opacityControl.alignment = .centerY
        append(group([
            row("玻璃材质", control: glassStyle),
            row("背景透明度", control: opacityControl)
        ]), to: root)
        append(text("在系统玻璃效果上调节，卡片正文保持不透明。100% 保留当前玻璃效果；减少透明度等辅助功能设置优先。"), to: root)
        let reset = button("恢复默认外观", action: #selector(resetAppearance))
        reset.setAccessibilityIdentifier("appearance-reset")
        appendAction(reset, to: root)
        addTab(view)
    }
    private func buildKeyboard() {
        let (view, root) = page()
        shelfShortcut.onRecord = { [weak self] in self?.appDelegate?.changeHotkey($0, id: 1) }
        stackShortcut.onRecord = { [weak self] in self?.appDelegate?.changeHotkey($0, id: 2) }
        for recorder in [shelfShortcut, stackShortcut] {
            recorder.onError = { [weak self] message in
                self?.shortcutError.stringValue = message; self?.shortcutError.isHidden = message.isEmpty
            }
        }
        append(text("点击快捷键开始录制，按 Esc 取消。"), to: root)
        append(group([row("打开 Prism", control: shelfShortcut), row("开始 / 结束连续粘贴", control: stackShortcut)]), to: root)
        shortcutError.textColor = .systemRed; shortcutError.font = .systemFont(ofSize: 12); shortcutError.isHidden = true
        append(shortcutError, to: root)
        section("浮层内操作", to: root)
        append(group([
            row("下一个收藏板", control: text("⌘ →", size: 13, bold: true)),
            row("上一个收藏板", control: text("⌘ ←", size: 13, bold: true)),
            row("快速粘贴", control: text("⌘ 1 … 9", size: 13, bold: true)),
            row("纯文本模式", control: text("⇧ Return", size: 13, bold: true))
        ]), to: root)
        append(text("连续粘贴：开启后按顺序复制多项内容，再用 ⌘V 依次粘贴。也可将选中的历史记录加入队列；队列用完后自动结束。"), to: root)
        appendAction(button("恢复默认全局快捷键", action: #selector(resetShortcuts)), to: root)
        addTab(view)
    }
    private func buildPrivacy() {
        let (view, root) = page()
        section("权限", to: root)
        permissions.font = .systemFont(ofSize: 12); permissions.textColor = .secondaryLabelColor
        permissions.maximumNumberOfLines = 0; permissions.lineBreakMode = .byWordWrapping
        let status = NSView(); permissions.translatesAutoresizingMaskIntoConstraints = false; status.addSubview(permissions)
        NSLayoutConstraint.activate([
            permissions.leadingAnchor.constraint(equalTo: status.leadingAnchor), permissions.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            permissions.topAnchor.constraint(equalTo: status.topAnchor, constant: 8), permissions.bottomAnchor.constraint(equalTo: status.bottomAnchor, constant: -8)
        ])
        append(group([
            row("辅助功能", detail: "用于自动粘贴和连续粘贴。", control: button("开启权限…", action: #selector(requestPermission))),
            status
        ]), to: root)
        section("记录规则", to: root)
        append(group([insetNote("密码管理器、系统密码与钥匙串应用，以及标记为隐藏、临时或敏感的内容，默认不会记录。安全输入开启时也会暂停采集。")]), to: root)
        section("排除的应用", to: root)
        append(text("每行填写一个应用名称或 Bundle ID，支持 com.example.*。"), to: root)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        excluded.isRichText = false; excluded.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        excluded.isAutomaticQuoteSubstitutionEnabled = false; excluded.isAutomaticDashSubstitutionEnabled = false
        excluded.textContainerInset = NSSize(width: 10, height: 10); excluded.delegate = self
        excluded.isVerticallyResizable = true; excluded.isHorizontallyResizable = false
        excluded.autoresizingMask = [.width]; excluded.textContainer?.widthTracksTextView = true
        excluded.setAccessibilityLabel("排除的应用，每行一个名称或 Bundle ID")
        scroll.documentView = excluded; scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        append(scroll, to: root)
        appendAction(button("添加应用…", action: #selector(addApplication)), to: root)
        append(text("更改只影响之后的记录。已有内容可从历史面板删除。"), to: root)
        addTab(view)
    }
    private func buildStorage() {
        let (view, root) = page()
        section("保留历史", to: root)
        for (title, value) in [("1 天", 1), ("1 周", 7), ("1 个月", 30), ("3 个月", 90), ("1 年", 365), ("永久", 0)] {
            days.addItem(withTitle: title); days.lastItem?.representedObject = value
        }
        days.target = self; days.action = #selector(changed(_:))
        for field in [limit, disk] {
            let formatter = NumberFormatter(); formatter.numberStyle = .none; formatter.minimum = 0; formatter.maximum = 1000000
            field.formatter = formatter; field.target = self; field.action = #selector(changed(_:))
            (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        append(group([
            row("历史期限", control: days),
            row("最多保存条数", detail: "0 表示不限。", control: limit),
            row("磁盘上限 · MB", detail: "0 表示不限；收藏内容始终保留。", control: disk)
        ]), to: root)
        section("备份", to: root)
        append(group([
            row("导出备份", detail: "包含完整原始内容与收藏分组。", control: button("导出…", action: #selector(exportBackup))),
            row("导入备份", control: button("导入…", action: #selector(importBackup)))
        ]), to: root)
        append(text("文件记录只保存原文件地址，不能替代文件本身的备份。单次剪贴板上限为 100 MB。"), to: root)
        section("历史记录", to: root)
        append(group([row("清空历史", detail: "清理前会显示确认提示。", control: button("清空…", action: #selector(clearHistory)))]), to: root)
        addTab(view)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredPages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < filteredPages.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("settings-navigation")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsNavigationCell) ?? SettingsNavigationCell(frame: .zero)
        let page = filteredPages[row]
        cell.identifier = identifier; cell.label.stringValue = page.title; cell.icon.symbol = page.symbol; cell.icon.color = page.color
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingNavigation, navigation.selectedRow >= 0, navigation.selectedRow < filteredPages.count else { return }
        selectPage(filteredPages[navigation.selectedRow])
    }
    private func selectPage(_ page: Page) {
        currentPage = page; pageTitle.stringValue = page.title
        tabs.selectTabViewItem(at: page.rawValue); refreshState()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === search else { return }
        let tokens = search.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
        filteredPages = Page.allCases.filter { page in tokens.allSatisfy { (page.title + " " + page.keywords).localizedStandardContains($0) } }
        updatingNavigation = true
        navigation.reloadData(); navigation.deselectAll(nil)
        noMatches.isHidden = !filteredPages.isEmpty
        let selected = filteredPages.firstIndex(of: currentPage) ?? (filteredPages.isEmpty ? nil : 0)
        if let selected { navigation.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        updatingNavigation = false
        if let selected { selectPage(filteredPages[selected]) }
    }
    func refreshState() {
        guard let appDelegate else { return }
        updating = true; defer { updating = false }
        let prefs = appDelegate.preferences
        if let item = days.itemArray.first(where: { ($0.representedObject as? Int) == prefs.days }) { days.select(item) }
        if limit.currentEditor() == nil { limit.integerValue = prefs.limit }
        if disk.currentEditor() == nil { disk.integerValue = prefs.diskMB }
        if window?.firstResponder !== excluded { excluded.string = prefs.excluded }
        background.state = prefs.paused ? .off : .on; menuBar.state = prefs.showMenuBar ? .on : .off
        sound.state = prefs.soundEffects ? .on : .off; plain.state = prefs.alwaysPlainText ? .on : .off
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        pasteTarget.selectItem(at: prefs.automaticPaste ? 0 : 1)
        let postPermission = CGPreflightPostEventAccess() ? "已开启" : "未开启"
        let accessibilityPermission = AXIsProcessTrusted() ? "已开启" : "未开启"
        permissions.stringValue = "自动粘贴许可：\(postPermission)\n辅助功能访问：\(accessibilityPermission)"
        shelfShortcut.binding = prefs.hotkey(1); stackShortcut.binding = prefs.hotkey(2)
        refreshAppearance(prefs.appearance)
    }
    private func refreshAppearance(_ value: PrismAppearanceSettings) {
        func select(_ popup: NSPopUpButton, _ raw: String) { popup.select(popup.itemArray.first { ($0.representedObject as? String) == raw }) }
        select(appearanceMode, value.mode.rawValue); select(cardColorMode, value.cardColorMode.rawValue); select(glassStyle, value.glassStyle.rawValue)
        cardColor.color = value.customColor; cardColor.isEnabled = value.cardColorMode == .custom
        transparency.doubleValue = value.transparency * 100
        transparencyValue.stringValue = "\(Int((value.transparency * 100).rounded()))%"
        window?.appearance = value.windowAppearance
    }
    @objc private func appearanceChanged(_ sender: NSControl) {
        guard !updating, let prefs = appDelegate?.preferences else { return }
        var value = prefs.appearance
        if sender === appearanceMode, let raw = appearanceMode.selectedItem?.representedObject as? String, let mode = PrismAppearanceSettings.Mode(rawValue: raw) { value.mode = mode }
        else if sender === cardColorMode, let raw = cardColorMode.selectedItem?.representedObject as? String, let mode = PrismAppearanceSettings.CardColorMode(rawValue: raw) { value.cardColorMode = mode }
        else if sender === cardColor { value.setCustomColor(cardColor.color) }
        else if sender === glassStyle, let raw = glassStyle.selectedItem?.representedObject as? String, let style = PrismAppearanceSettings.GlassStyle(rawValue: raw) { value.glassStyle = style }
        else if sender === transparency { value.transparency = transparency.doubleValue / 100 }
        else { return }
        prefs.appearance = value
        cardColor.isEnabled = value.cardColorMode == .custom
        transparencyValue.stringValue = "\(Int((value.transparency * 100).rounded()))%"
        window?.appearance = value.windowAppearance
    }
    @objc private func resetAppearance() {
        guard let prefs = appDelegate?.preferences else { return }
        cardColor.deactivate(); prefs.appearance = .default; refreshState()
    }
    @objc private func changed(_ sender: NSControl) {
        guard !updating, let appDelegate else { return }
        if sender === login { appDelegate.setLoginItem(login.state == .on); return }
        if sender === background { appDelegate.setCaptureEnabled(background.state == .on); return }
        if sender === menuBar { _ = appDelegate.setMenuVisible(menuBar.state == .on); refreshState(); return }
        let prefs = appDelegate.preferences
        if sender === days { prefs.days = days.selectedItem?.representedObject as? Int ?? 30 }
        else if sender === limit { prefs.limit = limit.integerValue }
        else if sender === disk { prefs.diskMB = disk.integerValue }
        else if sender === sound { prefs.soundEffects = sound.state == .on }
        else if sender === plain { prefs.alwaysPlainText = plain.state == .on }
        else if sender === pasteTarget { prefs.automaticPaste = pasteTarget.indexOfSelectedItem == 0 }
        else { return }
        appDelegate.preferencesChanged()
    }
    func textDidChange(_ notification: Notification) {
        guard !updating, notification.object as? NSTextView === excluded else { return }
        appDelegate?.preferences.excluded = excluded.string
    }
    @objc private func resetShortcuts() { appDelegate?.resetHotkeys(); shortcutError.stringValue = ""; shortcutError.isHidden = true; refreshState() }
    @objc private func requestPermission() { appDelegate?.requestAccessibility() }
    @objc private func exportBackup() { appDelegate?.exportArchive() }
    @objc private func importBackup() { appDelegate?.importArchive() }
    @objc private func clearHistory() { appDelegate?.clearHistory() }
    @objc private func addApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var entries = excluded.string.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier, !entries.contains(id) { entries.append(id) } }
        excluded.string = entries.joined(separator: "\n"); appDelegate?.preferences.excluded = excluded.string
    }
}
