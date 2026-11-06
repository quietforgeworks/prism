import AppKit

/// Appearance preferences have their own domain entry so restoring them cannot
/// reset clipboard history, shortcuts, or other application preferences.
struct PrismAppearanceSettings: Equatable {
    enum Mode: String, CaseIterable {
        case system, light, dark
        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }
    }
    enum CardColorMode: String, CaseIterable {
        case original, custom
        var title: String { self == .original ? "原始配色" : "自定义颜色" }
    }
    enum GlassStyle: String, CaseIterable {
        case standard, clear
        var title: String { self == .standard ? "标准" : "清透" }
    }

    var mode: Mode = .system
    var cardColorMode: CardColorMode = .original
    var glassStyle: GlassStyle = .standard
    /// One retains the original native glass. Lower values request backing fill;
    /// the view never uses this value to fade text or the complete card.
    var transparency: Double = 1
    var customColorHex: String = "4F6E89"

    static let `default` = PrismAppearanceSettings()
    private static let defaultsKey = "PrismAppearance.v1"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.dictionary(forKey: defaultsKey) else { return .default }
        var settings = Self.default
        if let raw = data["mode"] as? String, let value = Mode(rawValue: raw) { settings.mode = value }
        if let raw = data["cardColorMode"] as? String, let value = CardColorMode(rawValue: raw) { settings.cardColorMode = value }
        if let raw = data["glassStyle"] as? String, let value = GlassStyle(rawValue: raw) { settings.glassStyle = value }
        if let value = data["transparency"] as? Double { settings.transparency = normalizedTransparency(value) }
        if let value = data["customColorHex"] as? String { settings.customColorHex = normalizedHex(value) }
        return settings
    }

    func save(to defaults: UserDefaults) {
        defaults.set([
            "mode": mode.rawValue,
            "cardColorMode": cardColorMode.rawValue,
            "glassStyle": glassStyle.rawValue,
            "transparency": Self.normalizedTransparency(transparency),
            "customColorHex": Self.normalizedHex(customColorHex)
        ], forKey: Self.defaultsKey)
    }

    var windowAppearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var customColor: NSColor {
        let hex = Self.normalizedHex(customColorHex)
        let rgb = UInt32(hex, radix: 16)!
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    mutating func setCustomColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy({ $0.isFinite }) else { return }
        customColorHex = components.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }

    /// The original branch returns the caller's color unchanged. Custom colors
    /// are opaque and darkened only as needed for white header text (4.5:1).
    func headerColor(fallback: NSColor) -> NSColor {
        guard cardColorMode == .custom else { return fallback }
        let rgb = customColor
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        func luminance(_ scale: CGFloat) -> CGFloat {
            let linear = channels.map { component -> CGFloat in
                let value = component * scale
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        var scale: CGFloat = 1
        if luminance(1) > 0.18 {
            var low: CGFloat = 0
            var high: CGFloat = 1
            for _ in 0..<32 {
                let middle = (low + high) / 2
                if luminance(middle) <= 0.18 { low = middle } else { high = middle }
            }
            scale = low
        }
        return NSColor(srgbRed: channels[0] * scale, green: channels[1] * scale,
                       blue: channels[2] * scale, alpha: 1)
    }

    private static func normalizedTransparency(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : Self.default.transparency
    }

    private static func normalizedHex(_ value: String) -> String {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.utf8.count == 6, hex.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return Self.default.customColorHex }
        return hex.uppercased()
    }
}

extension Notification.Name {
    static let prismAppearanceDidChange = Notification.Name("PrismAppearanceDidChange")
}
