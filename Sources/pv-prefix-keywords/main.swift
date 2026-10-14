import Foundation
import Darwin
import PhotoVaultCore

// pv-prefix-keywords: marks the keywords already in a vault's photos as one
// tool's, in the vault's catalog, once (see KeywordPrefixer). A separate
// command in the project; it is never built into PhotoVault.app or copied onto
// a vault.

let usage = """
usage: pv-prefix-keywords --vault <vault> --prefix <prefix> --label <name> [--version <v>] [--dry-run] [--yes]

Marks every keyword in the vault's photos that has no declared prefix as one
tool's: with --prefix ext --label "OtherTagger", PhotoVault shows them under OtherTagger
instead of as a person's own. Recorded in the vault's catalog; the photos
themselves aren't changed. Run it once, with PhotoVault closed. It shows how
many photos it will mark and asks before starting. Photos already marked are
left alone, so it can't be applied twice.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func number(_ n: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }

/// A PhotoVault running from this vault, if any: it holds the catalog open,
/// and its own scan would race the rewrite.
func runningPhotoVault(in root: URL) -> pid_t? {
    let app = root.appendingPathComponent("PhotoVault.app").path + "/"
    var pids = [pid_t](repeating: 0, count: 8192)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(count)) where pid > 0 {
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasPrefix(app) { return pid }
    }
    return nil
}

var args = Array(CommandLine.arguments.dropFirst())
var vault: String?, prefix: String?, label: String?, version: String?
var dryRun = false, yes = false
while !args.isEmpty {
    let option = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(option) needs a value.\n\n\(usage)", code: 64) }
        return args.removeFirst()
    }
    switch option {
    case "--vault": vault = value()
    case "--prefix": prefix = value()
    case "--label": label = value()
    case "--version": version = value()
    case "--dry-run": dryRun = true
    case "--yes": yes = true
    case "-h", "--help": print(usage); exit(0)
    default: fail("Unknown option \(option).\n\n\(usage)", code: 64)
    }
}
guard let vault, let prefix, let label else { fail(usage, code: 64) }

let root = URL(fileURLWithPath: vault).standardizedFileURL.resolvingSymlinksInPath()
let catalogURL = VolumeLocator.catalogDir(root).appendingPathComponent("catalog.sqlite")
guard FileManager.default.fileExists(atPath: catalogURL.path) else { fail("No PhotoVault catalog in \(root.path).") }
if let pid = runningPhotoVault(in: root) { fail("PhotoVault is open from this vault (process \(pid)). Quit it first.") }

let prefixer: KeywordPrefixer
do { prefixer = try KeywordPrefixer(prefix: prefix, label: label, version: version) } catch { fail(error.localizedDescription) }
let name = prefixer.record.tool

let catalog: Catalog
do {
    catalog = try Catalog(url: catalogURL, tmpDir: VolumeLocator.catalogDir(root).appendingPathComponent("tmp"))
} catch {
    fail("Couldn't open the catalog: \(error.localizedDescription)")
}
// The app's clean-shutdown flag is the app's: left exactly as it was.
let wasClean = (try? catalog.meta("clean_shutdown")) == "1"
func finish(_ code: Int32) -> Never {
    catalog.closeCleanly(markingClean: wasClean)
    exit(code)
}

print("Vault: \(root.path)")
print("Reading the keywords in every photo…")
let survey: KeywordPrefixer.Survey
do { survey = try prefixer.survey(root: root, catalog: catalog) } catch {
    print("Couldn't read the vault: \(error.localizedDescription)")
    finish(1)
}
let n = survey.toMark.count
print("""
\(number(n)) \(n == 1 ? "photo has" : "photos have") keywords with no declared prefix — \(number(survey.keywords)) in all.
PhotoVault will show them under \(name). Recorded in the catalog: the photos aren't changed.
\(number(survey.alreadyMarked)) are marked as \(name)'s already and are left alone.
\(number(survey.nothingToMark)) have no keywords of their own.
""")
guard n > 0 else { print("Nothing to do."); finish(0) }
guard !dryRun else { print("Dry run: nothing changed."); finish(0) }
if !yes {
    print("Mark the keywords in \(number(n)) photos as \(name)'s? Type yes to go ahead: ", terminator: "")
    fflush(stdout)
    guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
        print("Nothing changed.")
        finish(0)
    }
}

let start = Date()
let failures = prefixer.apply(survey.toMark, root: root, catalog: catalog) { done, total in
    if done % 100 == 0 || done == total {
        print("\r  \(number(done)) of \(number(total))", terminator: "")
        fflush(stdout)
    }
}
print("")
let seconds = Date().timeIntervalSince(start)
print("Done: \(number(n - failures.count)) photos marked in \(Int(seconds.rounded())) s.")
if !failures.isEmpty {
    print("\(number(failures.count)) couldn't be marked:")
    for f in failures.prefix(20) { print("  \(f)") }
    finish(1)
}
finish(0)
