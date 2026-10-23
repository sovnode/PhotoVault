import SwiftUI
import AppKit

/// Help › PhotoVault User Manual: the manual's chapters down the side, the
/// chosen one on the right, and a search across all of them. Its own window,
/// so it can stay open beside the photos.
///
/// The text is `UserManual.chapters` (UserManualText.swift), written in a
/// small part of Markdown: "## " and "### " headings, paragraphs, "- " and
/// "1. " lists, and bold, italic and code within a line. The last chapter,
/// Keyboard Shortcuts, is built from `Shortcut`, so it always matches the
/// menus.
struct UserManualView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var query = ""

    private var chapters: [UserManual.Chapter] { UserManual.all }

    /// Chapters whose text has every word searched for.
    private var shown: [UserManual.Chapter] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return chapters }
        return chapters.filter { chapter in
            let text = (chapter.title + " " + chapter.searchText).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(shown, selection: Binding(get: { model.manualChapter }, set: { if let id = $0 { model.manualChapter = id } })) { chapter in
                Label(chapter.title, systemImage: chapter.symbol).tag(chapter.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search the manual")
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            let chapter = chapters.first { $0.id == model.manualChapter } ?? chapters[0]
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(chapter.title)
                            .font(.largeTitle.weight(.semibold))
                            .padding(.bottom, 4)
                            .id("top")
                        if chapter.id == UserManual.shortcutsID {
                            ShortcutList()
                        } else {
                            ForEach(Array(UserManual.blocks(chapter.markdown).enumerated()), id: \.offset) { _, block in
                                ManualBlockView(block: block, highlight: query)
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: model.manualChapter) { _, _ in reader.scrollTo("top", anchor: .top) }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(ManualWindowSetup())
    }
}

/// The manual's window: nothing saved outside the vault, like the main one.
private struct ManualWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, window.isRestorable else { return }
            window.isRestorable = false
            window.tabbingMode = .disallowed
            SmokeHooks.placeOnRequestedScreen(window)
        }
    }
}

/// One block of a chapter.
enum ManualBlock: Equatable {
    case heading(String)
    case subheading(String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
}

private struct ManualBlockView: View {
    let block: ManualBlock
    let highlight: String

    var body: some View {
        switch block {
        case .heading(let text):
            inline(text).font(.title2.weight(.semibold)).padding(.top, 14)
        case .subheading(let text):
            inline(text).font(.headline).padding(.top, 6)
        case .paragraph(let text):
            inline(text).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n + 1).").monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                        inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Bold, italic and code within a line, as Markdown has them.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// The Keyboard Shortcuts chapter: every shortcut, by where it works, from
/// the same list the menus use.
private struct ShortcutList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Every shortcut, by where it works. The menus show them too, beside each command, and buttons show theirs when the pointer rests on them.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Shortcut.Place.allCases, id: \.self) { place in
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.rawValue).font(.title3.weight(.semibold))
                    ForEach(Shortcut.allCases.filter { $0.place == place }, id: \.self) { s in
                        HStack {
                            Text(s.title)
                            Spacer(minLength: 16)
                            Text(s.label).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
            Text("More keys").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(UserManual.moreKeys, id: \.0) { key, what in
                    HStack(alignment: .firstTextBaseline) {
                        Text(what).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 16)
                        Text(key).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
    }
}

extension UserManual {
    struct Chapter: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let markdown: String
        var searchText: String { markdown }
    }

    static let shortcutsID = "shortcuts"

    /// Every chapter, the shortcuts last.
    static var all: [Chapter] {
        chapters + [Chapter(id: shortcutsID, title: "Keyboard Shortcuts", symbol: "keyboard",
                            markdown: Shortcut.allCases.map { "\($0.title) \($0.label)" }.joined(separator: "\n")
                                + "\n" + moreKeys.map { "\($0.1) \($0.0)" }.joined(separator: "\n"))]
    }

    /// Keys that aren't menu commands, and so aren't in `Shortcut`.
    static let moreKeys: [(String, String)] = [
        ("← → ↑ ↓", "In the grid, with one photo picked: pick the photo beside, above or below it"),
        ("⇧", "Shift on its own: open the photo picked in the grid; in the viewer, go back to the library"),
        ("↩", "In the sidebar: rename the album or smart album picked"),
        ("Pinch", "Zoom a photo or video, or change the thumbnails' size in the grid"),
        ("Two fingers", "Move a zoomed photo or video about"),
    ]

    /// A chapter's Markdown as blocks.
    static func blocks(_ markdown: String) -> [ManualBlock] {
        var out: [ManualBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { out.append(.numbered(numbered)); numbered = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("### ") { flush(); out.append(.subheading(String(line.dropFirst(4)))); continue }
            if line.hasPrefix("## ") { flush(); out.append(.heading(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { flush(); out.append(.heading(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !paragraph.isEmpty || !numbered.isEmpty { let b = bullets; bullets = []; flush(); bullets = b }
                bullets.append(String(line.dropFirst(2)))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                if !paragraph.isEmpty || !bullets.isEmpty { let n = numbered; numbered = []; flush(); numbered = n }
                numbered.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }
            // A line carrying on a list item, or a paragraph.
            if !bullets.isEmpty, paragraph.isEmpty, raw.hasPrefix("  ") {
                bullets[bullets.count - 1] += " " + line
            } else if !numbered.isEmpty, paragraph.isEmpty, raw.hasPrefix("  ") {
                numbered[numbered.count - 1] += " " + line
            } else {
                if !bullets.isEmpty || !numbered.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return out
    }
}
