import AppKit
import ImageIO
import UniformTypeIdentifiers

private enum ImageEditError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class ImageEditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width { result.origin.x = (documentView.frame.width - result.width) / 2 }
        if documentView.frame.height < result.height { result.origin.y = (documentView.frame.height - result.height) / 2 }
        return result
    }
}

private final class ImageEditCanvas: NSView {
    var bitmap: CGImage? {
        didSet {
            displayImage = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            frame.size = bitmap.map { NSSize(width: $0.width, height: $0.height) } ?? NSSize(width: 1, height: 1)
            selection = nil; needsDisplay = true
        }
    }
    var selection: NSRect? { didSet { onSelection?(selection); needsDisplay = true } }
    var canSelect = true
    var onSelection: ((NSRect?) -> Void)?
    private var displayImage: NSImage?
    private var dragStart: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: canSelect ? .crosshair : .arrow) }
    override func draw(_ dirtyRect: NSRect) {
        guard let displayImage else { return }
        let scale = max(0.01, enclosingScrollView?.magnification ?? 1)
        let tile: CGFloat = 12 / scale
        NSColor.white.setFill(); dirtyRect.fill()
        NSColor(white: 0.88, alpha: 1).setFill()
        let visible = dirtyRect.intersection(bounds)
        if !visible.isEmpty {
            let startX = floor(visible.minX / tile) * tile, startY = floor(visible.minY / tile) * tile
            for y in stride(from: startY, to: visible.maxY, by: tile) {
                for x in stride(from: startX, to: visible.maxX, by: tile) where (Int((x / tile).rounded()) + Int((y / tile).rounded())) % 2 == 0 {
                    NSRect(x: x, y: y, width: tile, height: tile).fill()
                }
            }
        }
        displayImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: [.interpolation: scale >= 1 ? NSImageInterpolation.none : NSImageInterpolation.high])
        if let selection, selection.width > 0, selection.height > 0 {
            let shade = NSBezierPath(rect: bounds); shade.appendRect(selection); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.42).setFill(); shade.fill()
            let outline = NSBezierPath(rect: selection); outline.lineWidth = 1.5 / scale
            NSColor.black.withAlphaComponent(0.8).setStroke(); outline.stroke()
            outline.setLineDash([5 / scale, 4 / scale], count: 2, phase: 0)
            NSColor.white.setStroke(); outline.stroke()
        }
    }
    private func clamped(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(bounds.maxX, max(0, point.x)), y: min(bounds.maxY, max(0, point.y)))
    }
    override func mouseDown(with event: NSEvent) {
        guard canSelect, bitmap != nil else { return }
        window?.makeFirstResponder(self); dragStart = clamped(event); selection = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard canSelect, let start = dragStart else { return }
        autoscroll(with: event)
        let point = clamped(event)
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(start.x - point.x), height: abs(start.y - point.y)).integral.intersection(bounds)
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { mouseDragged(with: event) }
        dragStart = nil
        if let selection, selection.width < 1 || selection.height < 1 { self.selection = nil }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selection = nil } else { super.keyDown(with: event) }
    }
}

final class ImageEditorController: NSWindowController, NSWindowDelegate {
    private let canvas = ImageEditCanvas()
    private let scroll = NSScrollView()
    private let toolbar = NSStackView()
    private let detail = NSTextField(labelWithString: "正在读取原始图片…")
    private let notice = NSTextField(labelWithString: "拖动框选裁剪范围；关闭窗口可取消。无损保存，保持编辑后的像素尺寸。")
    private let spinner = NSProgressIndicator()
    private var rotateLeft: NSButton!, rotateRight: NSButton!, crop: NSButton!, restore: NSButton!, save: NSButton!
    private var fit: NSButton!, zoomOut: NSButton!, zoomIn: NSButton!
    private let queue = DispatchQueue(label: "local.prism.image-editor", qos: .userInitiated)
    private var original: CGImage?
    private var originalPayloads: [Payload] = []
    private var itemIndex = 0
    private var working = false
    private var changed = false
    private var generation = UUID()
    private var zoomObservation: NSKeyValueObservation?
    private let onSave: ([Payload]) -> Void
    private static let maxPixels = 40_000_000

    init(clip: Clip, onSave: @escaping ([Payload]) -> Void) {
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = clip.title.isEmpty ? "编辑图片" : "编辑图片 · \(clip.title)"
        window.minSize = NSSize(width: 780, height: 480); window.center()
        super.init(window: window); window.delegate = self
        configure()
        working = true; updateControls(); spinner.startAnimation(nil)
        let token = generation
        queue.async { [weak self] in
            do {
                let payloads = try clip.loadPayloads()
                let loaded = try Self.decodeOriginal(payloads)
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.originalPayloads = payloads; self.itemIndex = loaded.index; self.original = loaded.image
                    self.canvas.bitmap = loaded.image; self.working = false; self.spinner.stopAnimation(nil)
                    if loaded.animated { self.notice.stringValue = "动图将编辑第一帧；无损保存为静态图片。其他剪贴板项目保持不变。" }
                    else if payloads.count > 1 { self.notice.stringValue = "正在编辑第一张图片；其他剪贴板项目保持不变。无损保存。" }
                    self.fitImage(); self.updateControls()
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.finish(error: error, token: token) } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        guard let root = window?.contentView else { return }
        toolbar.orientation = .horizontal; toolbar.spacing = 8; toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(toolbar)
        func button(_ title: String, _ symbol: String, _ selector: Selector) -> NSButton {
            let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: selector)
            button.bezelStyle = .rounded; button.imagePosition = .imageLeading; toolbar.addArrangedSubview(button); return button
        }
        rotateLeft = button("左转", "rotate.left", #selector(turnLeft))
        rotateRight = button("右转", "rotate.right", #selector(turnRight))
        crop = button("裁剪所选", "crop", #selector(applyCrop))
        restore = button("还原", "arrow.uturn.backward", #selector(resetImage))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer)
        zoomOut = button("", "minus.magnifyingglass", #selector(smaller)); zoomOut.setAccessibilityLabel("缩小")
        fit = button("适合窗口", "arrow.down.right.and.arrow.up.left", #selector(fitImage))
        zoomIn = button("", "plus.magnifyingglass", #selector(larger)); zoomIn.setAccessibilityLabel("放大")
        save = button("保存", "checkmark", #selector(commit)); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.contentView = ImageEditorClipView()
        scroll.documentView = canvas; scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.allowsMagnification = true; scroll.minMagnification = 0.01; scroll.maxMagnification = 8
        scroll.drawsBackground = true; scroll.backgroundColor = .underPageBackgroundColor
        root.addSubview(scroll)
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(detail)
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor; notice.lineBreakMode = .byTruncatingTail
        notice.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(notice)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(spinner)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), toolbar.heightAnchor.constraint(equalToConstant: 32),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -62),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -34),
            notice.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), notice.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            notice.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            spinner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), spinner.centerYAnchor.constraint(equalTo: detail.centerYAnchor)
        ])
        canvas.onSelection = { [weak self] _ in self?.updateControls() }
        zoomObservation = scroll.observe(\.magnification, options: [.new]) { [weak self] _, _ in self?.updateDetail() }
    }

    private func updateDetail() {
        guard let image = canvas.bitmap else { return }
        let selection = canvas.selection.map { " · 所选 \(Int($0.width)) × \(Int($0.height))" } ?? ""
        detail.stringValue = "\(image.width) × \(image.height) 像素 · \(Int((scroll.magnification * 100).rounded()))%\(selection)"
    }
    private func updateControls() {
        let ready = canvas.bitmap != nil && !working
        [rotateLeft, rotateRight, fit, zoomOut, zoomIn].forEach { $0?.isEnabled = ready }
        crop.isEnabled = ready && canvas.selection != nil
        restore.isEnabled = ready && changed
        save.isEnabled = ready && changed
        canvas.canSelect = ready; canvas.window?.invalidateCursorRects(for: canvas)
        updateDetail()
    }
    @objc private func fitImage() {
        guard let image = canvas.bitmap else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let area = scroll.contentSize
        let scale = min(1, min(max(1, area.width - 20) / CGFloat(image.width), max(1, area.height - 20) / CGFloat(image.height)))
        scroll.setMagnification(max(scroll.minMagnification, scale), centeredAt: NSPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2))
        updateDetail()
    }
    @objc private func smaller() { scroll.magnification = max(scroll.minMagnification, scroll.magnification / 1.25); updateDetail() }
    @objc private func larger() { scroll.magnification = min(scroll.maxMagnification, scroll.magnification * 1.25); updateDetail() }
    @objc private func turnLeft() { transform { try Self.rotate($0, clockwise: false) } }
    @objc private func turnRight() { transform { try Self.rotate($0, clockwise: true) } }
    @objc private func applyCrop() {
        guard let rect = canvas.selection, rect.width >= 1, rect.height >= 1 else { return }
        transform {
            guard let result = $0.cropping(to: rect) else { throw ImageEditError.message("无法裁剪所选范围。") }
            return result
        }
    }
    @objc private func resetImage() {
        guard !working, let original else { return }
        canvas.bitmap = original; changed = false; fitImage(); updateControls()
    }
    private func transform(_ operation: @escaping (CGImage) throws -> CGImage) {
        guard !working, let image = canvas.bitmap else { return }
        working = true; updateControls(); spinner.startAnimation(nil); let token = generation
        queue.async { [weak self] in
            do {
                let result = try operation(image)
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.canvas.bitmap = result; self.changed = true; self.working = false; self.spinner.stopAnimation(nil)
                    self.fitImage(); self.updateControls()
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.finish(error: error, token: token) } }
        }
    }
    @objc private func commit() {
        guard !working, changed, let image = canvas.bitmap else { return }
        working = true; updateControls(); spinner.startAnimation(nil)
        let token = generation, payloads = originalPayloads, index = itemIndex
        queue.async { [weak self] in
            do {
                let png = try Self.encode(image, as: .png)
                let otherBytes = payloads.enumerated().filter { $0.offset != index }.reduce(0) { $0 + $1.element.types.values.reduce(0) { $0 + $1.count } }
                guard png.count <= ClipStore.maxBytes - min(otherBytes, ClipStore.maxBytes) else {
                    throw ImageEditError.message("编辑后的记录超过 100 MB 保存上限。请缩小裁剪范围；原始记录尚未修改。")
                }
                var types = [NSPasteboard.PasteboardType.png.rawValue: png]
                // PNG alone is lossless and portable. Only retain a second complete
                // representation when the complete multi-item record stays in budget.
                if image.width * image.height * 4 < ClipStore.maxBytes - png.count - otherBytes {
                    let tiff = try Self.encode(image, as: .tiff)
                    if png.count + tiff.count + otherBytes <= ClipStore.maxBytes { types[NSPasteboard.PasteboardType.tiff.rawValue] = tiff }
                }
                var result = payloads
                result[index] = Payload(types: types)
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.onSave(result); self.close()
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.finish(error: error, token: token) } }
        }
    }
    private func finish(error: Error, token: UUID) {
        guard generation == token else { return }
        working = false; spinner.stopAnimation(nil)
        detail.stringValue = error.localizedDescription; updateControls()
        // Keep the failure visible when an image is still available to edit.
        notice.stringValue = error.localizedDescription
    }
    func windowWillClose(_ notification: Notification) { generation = UUID() }

    private static func decodeOriginal(_ payloads: [Payload]) throws -> (image: CGImage, index: Int, animated: Bool) {
        for (index, payload) in payloads.enumerated() {
            let preferred = [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue]
            let types = preferred + payload.types.keys.filter { !preferred.contains($0) }.sorted()
            var candidates: [(source: CGImageSource, width: Int, height: Int)] = []
            for type in types {
                guard let bytes = payload.types[type], let uti = UTType(type), uti.conforms(to: .image),
                      let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = (values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { continue }
                guard width > 0, height > 0, width <= maxPixels / height else {
                    throw ImageEditError.message("图片超过编辑器的 4000 万像素上限。原始内容保持不变，未生成缩小版本。")
                }
                candidates.append((source, width, height))
            }
            // A clipboard can contain a small PNG alongside a full-size TIFF.
            // Choose the largest original representation in this image item.
            guard let selected = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(selected.width, selected.height)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(selected.source, 0, options as CFDictionary),
                  image.width * image.height == selected.width * selected.height else {
                throw ImageEditError.message("无法按原始像素尺寸解码这张图片。原始内容保持不变。")
            }
            guard image.bitsPerComponent <= 16 else { throw ImageEditError.message("当前编辑器不支持这张高位深图片。原始内容保持不变。") }
            return (image, index, CGImageSourceGetCount(selected.source) > 1)
        }
        throw ImageEditError.message("没有找到可编辑的原始图片。")
    }
    private static func rotate(_ image: CGImage, clockwise: Bool) throws -> CGImage {
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : CGBitmapInfo.byteOrder32Big.rawValue)
        guard let context = CGContext(data: nil, width: image.height, height: image.width,
            bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else {
            throw ImageEditError.message("无法为原始像素尺寸分配旋转空间。原始内容保持不变。")
        }
        context.interpolationQuality = .none; context.setShouldAntialias(false)
        if clockwise { context.translateBy(x: 0, y: CGFloat(image.width)); context.rotate(by: -.pi / 2) }
        else { context.translateBy(x: CGFloat(image.height), y: 0); context.rotate(by: .pi / 2) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ImageEditError.message("旋转失败。") }
        return result
    }
    private static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageEditError.message("无法创建图片编码器。")
        }
        let properties: CFDictionary? = type == .tiff ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ImageEditError.message("图片保存失败，原记录未修改。") }
        return data as Data
    }
}
