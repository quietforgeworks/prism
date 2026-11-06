import AppKit

func makeDemoClips() -> [Clip] {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Prism-Demo", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pdfView = DemoPage(frame: NSRect(x: 0, y: 0, width: 500, height: 650))
    let pdf = pdfView.dataWithPDF(inside: pdfView.bounds)
    let file = folder.appendingPathComponent("设计笔记.pdf"); try? pdf.write(to: file)
    let canvas = NSImage(size: NSSize(width: 960, height: 720), flipped: false) { bounds in
        NSColor(srgbRed: 0.92, green: 0.95, blue: 0.97, alpha: 1).setFill(); bounds.fill()
        let colors: [NSColor] = [.systemTeal, .systemBlue, .systemIndigo]
        for (i, color) in colors.enumerated() {
            color.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: 90 + CGFloat(i)*230, y: 145 + CGFloat(i%2)*110, width: 220, height: 280), xRadius: 35, yRadius: 35).fill()
        }
        ("Less, but better." as NSString).draw(at: NSPoint(x: 90, y: 590), withAttributes: [.font: NSFont.systemFont(ofSize: 44, weight: .semibold), .foregroundColor: NSColor(srgbRed: 0.12, green: 0.2, blue: 0.3, alpha: 1)])
        return true
    }
    let png = canvas.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) ?? Data()
    let rich = NSAttributedString(string: "设计，让内容先被看见。\n\n清晰的层次，恰到好处的留白。\n保留复制时的字体、颜色与段落格式。", attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.labelColor])
    let rtf = (try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
    var clips = [
        Clip(source: "访达", bundle: "com.apple.finder", payloads: [Payload(types: [NSPasteboard.PasteboardType.fileURL.rawValue: Data(file.absoluteString.utf8)])]),
        Clip(source: "备忘录", bundle: "com.apple.Notes", payloads: [Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data("把灵感留在手边。\n\n复制一次，随时取回。\n按空格预览，回车粘贴，拖动卡片即可收藏。".utf8)])]),
        Clip(source: "文本编辑", bundle: "com.apple.TextEdit", payloads: [Payload(types: [NSPasteboard.PasteboardType.rtf.rawValue: rtf, NSPasteboard.PasteboardType.string.rawValue: Data(rich.string.utf8)])]),
        Clip(source: "Safari", bundle: "com.apple.Safari", payloads: [Payload(types: [NSPasteboard.PasteboardType.png.rawValue: png])]),
        Clip(source: "Safari", bundle: "com.apple.Safari", payloads: [Payload(types: [NSPasteboard.PasteboardType.URL.rawValue: Data("https://developer.apple.com/design/".utf8), NSPasteboard.PasteboardType.string.rawValue: Data("https://developer.apple.com/design/".utf8)])]),
        Clip(source: "预览", bundle: "com.apple.Preview", payloads: [Payload(types: [NSPasteboard.PasteboardType.pdf.rawValue: pdf])])
    ]
    let count = Int(ProcessInfo.processInfo.environment["PRISM_DEMO_COUNT"] ?? "6") ?? 6
    if count > clips.count {
        for index in clips.count..<min(count, 10000) {
            clips.append(Clip(source: "性能测试", bundle: "local.prism.fixture", payloads: [Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data("第 \(index) 条测试记录\n用于检查长历史列表的卡片复用、搜索和滚动性能。".utf8)])]))
        }
    }
    for i in clips.indices { clips[i].date = Date().addingTimeInterval(-Double(i * 180 + 60)) }
    return clips
}
private final class DemoPage: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor(srgbRed: 0.12, green: 0.22, blue: 0.38, alpha: 1).setFill(); NSRect(x: 0, y: 480, width: 500, height: 170).fill()
        ("Design Notes" as NSString).draw(at: NSPoint(x: 44, y: 548), withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white])
        ("让信息自然流动" as NSString).draw(at: NSPoint(x: 44, y: 504), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
        for i in 0..<9 { NSColor.lightGray.withAlphaComponent(0.4).setFill(); NSRect(x: 44, y: 428-CGFloat(i)*32, width: i%3 == 2 ? 290 : 410, height: 7).fill() }
        ("Prism · 本地示例文件" as NSString).draw(at: NSPoint(x: 44, y: 55), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.gray])
    }
}
