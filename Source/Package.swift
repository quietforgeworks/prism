// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Prism",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Prism", targets: ["Prism"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .executableTarget(name: "Prism", dependencies: ["CSQLite"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
