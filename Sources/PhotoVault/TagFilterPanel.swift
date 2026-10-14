import SwiftUI
import PhotoVaultCore

/// A smart album's tag rules, edited over the top of its grid. Done
/// hides the panel; Edit Filter in the toolbar brings it back.
///
/// Clicks change a local copy at once, so two quick clicks always land as
/// include then exclude, whatever the catalog is doing; the album is saved a
/// moment later, and the grid below follows.
///
/// Thousands of tags stay manageable: groups start closed, a "Most used" row
/// sits on top, an open group shows its dozen most used tags first, rare tags
/// fold away, and searching opens only the groups with a match.
struct TagFilterPanel: View {
    @EnvironmentObject var model: LibraryModel
    let album: SmartAlbum

    @State private var rules = TagRules()
    @State private var name = ""
    @State private var search = ""
    @State private var open: Set<String> = []
    @State private var showAll: Set<String> = []
    @State private var showRare = false
    @State private var showHidden = false
    @State private var save: Task<Void, Never>?
    @State private var unsaved = false

    private static let topN = 12
    static let rareBelow = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Album name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .onSubmit(commitName)
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Click a tag or group once to include it, again to exclude it, once more to clear it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                // Two columns, each scrolling on its own: what's chosen collects
                // on the right, so the tag list never moves under the pointer.
                ScrollView { browser.padding(.trailing, 8) }
                    .frame(maxWidth: .infinity)
                Divider()
                ScrollView { summary }
                    .frame(width: 236)
            }
        }
        .padding(12)
        .frame(height: 420)
        .background(.bar)
        .onAppear(perform: load)
        .onChange(of: album.id) { _, _ in load() }
        .onDisappear(perform: flushSave)
    }

    // MARK: - Tags

    private var query: String { TagKey.key(search) }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search \(model.tagCounts.count) tags", text: $search)
                .textFieldStyle(.roundedBorder)
            if model.tagCounts.isEmpty {
                Text("No photo in this vault has tags yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if query.isEmpty {
                Text("Most used").font(.caption).foregroundStyle(.secondary)
                FlowLayout { ForEach(model.mostUsedTags(Self.topN), id: \.key) { tagChip($0) } }
            }
            ForEach(model.tagGroupLists) { group in groupView(group) }
            if !query.isEmpty, noMatches {
                Text("No tag matches “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if query.isEmpty, !model.hiddenTags.isEmpty {
                hiddenTags
            }
            if query.isEmpty, !model.tagCounts.isEmpty {
                Toggle("Show rare tags (on fewer than \(Self.rareBelow) photos)", isOn: $showRare)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .padding(.top, 4)
            }
        }
    }

    private var noMatches: Bool {
        !model.tagGroupLists.contains { $0.tags.contains { $0.key.contains(query) } }
    }

    @ViewBuilder
    private func groupView(_ group: LibraryModel.TagGroupList) -> some View {
        let common = group.tags.filter { showRare || $0.photos >= Self.rareBelow }
        let matching = query.isEmpty ? common : group.tags.filter { $0.key.contains(query) }
        if query.isEmpty || !matching.isEmpty {
            let isOpen = !query.isEmpty || open.contains(group.name)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Button {
                        toggle(&open, group.name)
                    } label: {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isOpen ? "Hide this group's tags" : "Show this group's tags")
                    RuleChip(label: group.name, state: rules.state(.group, group.name)) { cycle(.group, group.name) }
                    Text(group.tags.count == 1 ? "1 tag" : "\(group.tags.count) tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isOpen {
                    let expanded = !query.isEmpty || showAll.contains(group.name)
                    FlowLayout {
                        ForEach(expanded ? matching : Array(matching.prefix(Self.topN)), id: \.key) { tagChip($0) }
                    }
                    .padding(.leading, 22)
                    if query.isEmpty, matching.count > Self.topN {
                        Button(showAll.contains(group.name) ? "Show fewer" : "Show all \(matching.count)") {
                            toggle(&showAll, group.name)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.leading, 22)
                    }
                    let rare = group.tags.count - common.count
                    if query.isEmpty, rare > 0 {
                        Text(rare == 1 ? "1 rare tag hidden" : "\(rare) rare tags hidden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
            }
        }
    }

    private func tagChip(_ tag: TagCount) -> some View {
        RuleChip(label: TagKey.display(tag.name), count: tag.photos, state: rules.state(.tag, tag.key)) {
            cycle(.tag, tag.key)
        }
        .contextMenu {
            Button("Hide Tag") { Task { await model.setTagHidden(tag.key, true) } }
        }
    }

    /// Tags hidden from the lists — junk like `photo (medium)` — kept out of
    /// the way but still usable, and shown again from their right-click menu.
    /// Nothing is deleted.
    @ViewBuilder
    private var hiddenTags: some View {
        Button(showHidden ? "Hide the hidden tags"
                          : (model.hiddenTags.count == 1 ? "Show 1 hidden tag" : "Show \(model.hiddenTags.count) hidden tags")) {
            showHidden.toggle()
        }
        .buttonStyle(.link)
        .font(.caption)
        if showHidden {
            FlowLayout {
                ForEach(model.hiddenTags.sorted(), id: \.self) { key in
                    RuleChip(label: TagKey.display(model.tagName(key)), count: model.tagByKey[key]?.photos,
                             state: rules.state(.tag, key)) { cycle(.tag, key) }
                        .contextMenu {
                            Button("Show Tag") { Task { await model.setTagHidden(key, false) } }
                        }
                }
            }
        }
    }

    // MARK: - Chosen rules

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In this filter").font(.caption).foregroundStyle(.secondary)
            if rules.items.isEmpty {
                Text("Tags and groups you include or exclude collect here, whatever the search box says.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rules.items, id: \.self) { item in
                        RuleChip(label: label(item),
                                 count: item.kind == .tag ? model.tagByKey[item.name]?.photos : nil,
                                 state: item.state) { cycle(item.kind, item.name) }
                    }
                }
            }
            HStack {
                Text("Include").font(.caption).frame(width: 52, alignment: .leading)
                Picker("Include", selection: Binding(get: { rules.include }, set: { rules.include = $0; scheduleSave() })) {
                    Text("All").tag(TagRules.Match.all)
                    Text("Any").tag(TagRules.Match.any)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            .help("All: a photo needs every included tag. Any: one is enough.")
            HStack {
                Text("Exclude").font(.caption).frame(width: 52, alignment: .leading)
                Picker("Exclude", selection: Binding(get: { rules.exclude }, set: { rules.exclude = $0; scheduleSave() })) {
                    Text("Any").tag(TagRules.Match.any)
                    Text("All").tag(TagRules.Match.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            .help("Any: an excluded tag hides a photo. All: only all of them together do.")
            Button("Reset") {
                rules = TagRules()
                scheduleSave()
            }
            Divider()
            // Just the count: the grid below the panel shows the photos.
            Text(model.items.count == 1 ? "1 photo matches" : "\(model.items.count) photos match")
                .font(.headline)
        }
    }

    private func label(_ item: TagRules.Item) -> String {
        switch item.kind {
        case .tag: return TagKey.display(model.tagName(item.name))
        case .group: return item.name + (item.state == .include ? " (any tag)" : " (whole group)")
        }
    }

    // MARK: - Changes

    private func load() {
        rules = album.rules ?? TagRules()
        name = album.name
        search = ""
        unsaved = false
    }

    private func cycle(_ kind: TagRules.Kind, _ name: String) {
        rules.cycle(kind, name)
        scheduleSave()
    }

    private func toggle(_ set: inout Set<String>, _ name: String) {
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
    }

    /// Saves once the clicking stops for a moment.
    private func scheduleSave() {
        unsaved = true
        save?.cancel()
        let id = album.id, snapshot = rules
        save = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            unsaved = false
            await model.updateRules(id, snapshot)
        }
    }

    private func flushSave() {
        guard unsaved else { return }
        save?.cancel()
        unsaved = false
        let id = album.id, snapshot = rules
        Task { await model.updateRules(id, snapshot) }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != album.name else { return }
        Task { await model.renameSmartAlbum(album.id, to: trimmed) }
    }

    private func finish() {
        commitName()
        flushSave()
        model.editingFilter = false
    }
}
