import Foundation

// PhotoVault Installer: makes a new vault, or puts PhotoVault on an existing
// one. With no arguments it opens its window; Headless has the command-line
// form, which the tests and Scripts/build-installer.sh use.
if let status = MainActor.assumeIsolated({ Headless.run(CommandLine.arguments) }) { exit(status) }
InstallerApp.main()
