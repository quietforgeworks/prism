import AppKit

private struct AppearanceTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func appearanceRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppearanceTestFailure(description: message) }
}

/// An isolated preferences suite; never reads or writes the user's settings.
func testAppearancePreferences() throws {
    let suite = "local.prism.appearance-test.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw AppearanceTestFailure(description: "Cannot create appearance test suite")
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    try appearanceRequire(PrismAppearanceSettings.load(from: defaults) == .default, "Absent appearance must retain original defaults")
    let original = PrismAppearanceSettings.default
    try appearanceRequire(original.mode == .system && original.cardColorMode == .original && original.glassStyle == .standard && original.transparency == 1, "Appearance defaults changed")
    try appearanceRequire(original.windowAppearance == nil, "Default appearance must follow macOS")
    let fallback = NSColor(srgbRed: 0.9, green: 0.7, blue: 0.4, alpha: 0.6)
    try appearanceRequire(original.headerColor(fallback: fallback) === fallback, "Original palette must return the exact caller color")

    defaults.set(["retained clip"], forKey: "history")
    defaults.set("command+shift+v", forKey: "hotkeys")
    var custom = original
    custom.mode = .dark
    custom.cardColorMode = .custom
    custom.glassStyle = .clear
    custom.transparency = 0.35
    custom.setCustomColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.3))
    try appearanceRequire(custom.customColorHex == "336699" && custom.customColor.alphaComponent == 1, "Custom RGB serialization must discard alpha")
    custom.save(to: defaults)
    try appearanceRequire(PrismAppearanceSettings.load(from: defaults) == custom, "Appearance preferences did not round trip")
    try appearanceRequire(custom.windowAppearance?.name == .darkAqua, "Dark appearance mapping failed")
    custom.mode = .light
    try appearanceRequire(custom.windowAppearance?.name == .aqua, "Light appearance mapping failed")
    try appearanceRequire(Set(defaults.persistentDomain(forName: suite)!.keys) == Set(["history", "hotkeys", "PrismAppearance.v1"]), "Appearance must use a single namespaced entry")

    defaults.set(["mode": "invalid", "cardColorMode": "unknown", "glassStyle": "unknown", "transparency": Double.nan, "customColorHex": "invalid"], forKey: "PrismAppearance.v1")
    try appearanceRequire(PrismAppearanceSettings.load(from: defaults) == .default, "Invalid fields must use original defaults")
    for (input, expected) in [(-1.0, 0.0), (2.0, 1.0), (Double.infinity, 1.0)] {
        defaults.set(["transparency": input], forKey: "PrismAppearance.v1")
        try appearanceRequire(PrismAppearanceSettings.load(from: defaults).transparency == expected, "Transparency was not normalized")
    }
    defaults.set(["transparency": "wrong type", "customColorHex": " #abcdef "], forKey: "PrismAppearance.v1")
    let normalized = PrismAppearanceSettings.load(from: defaults)
    try appearanceRequire(normalized.transparency == 1 && normalized.customColorHex == "ABCDEF", "Preference normalization failed")
    custom.transparency = .nan
    custom.customColorHex = "bad"
    custom.save(to: defaults)
    let saved = PrismAppearanceSettings.load(from: defaults)
    try appearanceRequire(saved.transparency == 1 && saved.customColorHex == original.customColorHex, "Save must normalize invalid direct assignments")

    for hex in ["FFFFFF", "FFFF00", "00FF00", "FF0000", "0000FF", "000000", "4F6E89"] {
        custom.customColorHex = hex
        let header = custom.headerColor(fallback: fallback).usingColorSpace(.sRGB)!
        let linear = [header.redComponent, header.greenComponent, header.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        let luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        try appearanceRequire(luminance <= 0.180001 && header.alphaComponent == 1, "Custom header must preserve readable white text")
    }
    PrismAppearanceSettings.default.save(to: defaults)
    try appearanceRequire(PrismAppearanceSettings.load(from: defaults) == .default, "Restoring appearance did not restore the defaults")
    try appearanceRequire(defaults.stringArray(forKey: "history") == ["retained clip"] && defaults.string(forKey: "hotkeys") == "command+shift+v", "Restoring appearance altered unrelated preferences")
}
