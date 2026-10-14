// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoVault",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PhotoVaultCore"),
        // Keeps an app's window geometry and defaults out of ~/Library/Preferences:
        // PhotoVault's, and its installer's.
        .target(name: "QuietPreferences"),
        .executableTarget(name: "PhotoVault", dependencies: ["PhotoVaultCore", "QuietPreferences"]),
        // PhotoVault Installer: makes a new vault, or puts PhotoVault on one.
        .target(name: "PhotoVaultSetup"),
        .executableTarget(name: "PhotoVaultInstaller", dependencies: ["PhotoVaultSetup", "QuietPreferences"]),
        // A one-off command for a vault whose photos already carry a tool's
        // keywords. Its own product: never built into
        // PhotoVault.app or copied onto a vault.
        .executableTarget(name: "pv-prefix-keywords", dependencies: ["PhotoVaultCore"]),
        .testTarget(name: "PhotoVaultCoreTests", dependencies: ["PhotoVaultCore"]),
        // The app's own views. Needs Xcode: the app target uses SwiftUI's @State
        // macro, whose plugin isn't in the Command Line Tools.
        .testTarget(name: "PhotoVaultAppTests", dependencies: ["PhotoVault", "PhotoVaultCore", "QuietPreferences"]),
        .testTarget(name: "PhotoVaultSetupTests", dependencies: ["PhotoVaultSetup"]),
    ]
)
