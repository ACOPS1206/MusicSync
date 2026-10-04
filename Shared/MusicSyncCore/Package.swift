// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MusicSyncCore", platforms: [.macOS("26.0"), .iOS("26.0")], products: [.library(name: "MusicSyncCore", targets: ["MusicSyncCore"])], targets: [.target(name: "MusicSyncCore"), .testTarget(name: "MusicSyncCoreTests", dependencies: ["MusicSyncCore"])], swiftLanguageModes: [.v5])
