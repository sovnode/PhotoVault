import SwiftUI
import UniformTypeIdentifiers
import PhotoVaultCore

/// The photo's details, beside it in the viewer. View-only.
///
/// Everything here comes from the catalog, apart from camera, exposure and
/// location, which are read from the file's header when a photo is shown.
/// Location appears as coordinates only: a map would fetch tiles from Apple's
/// servers and reveal where the photo was taken.
struct PropertiesPanel: View {
    @EnvironmentObject var model: LibraryModel
    let item: PhotoItem
    @State private var metadata = PhotoMetadata()
    @State private var albums: [String] = []
    @State private var tags: [PhotoTag] = []
    @State private var records: [Classification] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("File") {
                    row("Name", item.displayName)
                    row("Folder", folderText)
                    row("Size", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                    row("Format", formatText)
                }
                section("Date") {
                    if item.hasDate {
                        row("Taken", dateText)
                    } else {
                        row("Modified", dateText)
                    }
                    if let created = item.createdAt {
                        row("Created", Self.dateText(created))
                    }
                    if !item.hasDate {
                        note("The photo itself carries no date.")
                    }
                }
                section(item.mediaType == .video ? "Video" : "Image") {
                    let size = item.orientedSize
                    row("Dimensions", size.width > 0 ? "\(size.width) × \(size.height)" : "Unknown")
                    if item.mediaType == .video {
                        if let d = item.duration { row("Duration", durationText(d)) }
                        if !item.playable { note("This file can't be played.") }
                    }
                }
                if metadata.cameraDescription != nil || metadata.exposureDescription != nil {
                    section("Camera") {
                        if let camera = metadata.cameraDescription { row("Camera", camera) }
                        if let lens = metadata.lens { row("Lens", lens) }
                        if let exposure = metadata.exposureDescription { row("Exposure", exposure) }
                    }
                }
                if let coordinates = metadata.coordinatesDescription {
                    section("Location") {
                        row("Coordinates", coordinates)
                        note("Shown as text only; no map is loaded.")
                    }
                }
                section("Library") {
                    row("Favorite", item.favorite ? "Yes" : "No")
                    row("Albums", albums.isEmpty ? "None" : albums.joined(separator: ", "))
                    if item.trashed { note("In the Trash.") }
                }
                section("Tags") { tagsSection }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(white: 0.11))
        .foregroundStyle(.white)
        // Loads once per photo, and again when its tags change (a re-tag).
        // Nothing here changes state while drawing.
        .task(id: [item.id, Int64(model.tagsVersion)]) { await load() }
    }

    private func load() async {
        albums = await model.albumNames(for: item)
        tags = await model.tags(for: item)
        records = await model.classifications(for: item)
        guard item.mediaType == .photo, let url = model.url(for: item) else {
            metadata = PhotoMetadata()
            return
        }
        metadata = await Task.detached(priority: .userInitiated) { PhotoMetadata.read(url: url) }.value
    }

    /// The photo's tags by where they came from — JoyTag, a tool that declared
    /// its prefix in the photo, or the photo's own
    /// keywords — without prefixes. Listed only: tags are browsed through smart
    /// albums.
    @ViewBuilder
    private var tagsSection: some View {
        if tags.isEmpty {
            note("No tags.")
        }
        ForEach(sources, id: \.self) { source in
            VStack(alignment: .leading, spacing: 4) {
                Text(title(of: source)).font(.caption).foregroundStyle(.white.opacity(0.6))
                if let record = records.first(where: { $0.classifier == source }) {
                    note(describe(record))
                }
                FlowLayout(spacing: 4) {
                    ForEach(tags.filter { $0.source == source }, id: \.key) { tag in
                        Text(TagKey.display(tag.name))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                }
            }
        }
    }

    /// JoyTag first, then other tools, then the photo's own keywords.
    private var sources: [String] {
        let present = Set(tags.map(\.source))
        let others = present.subtracting([JoyTag.prefix, FileTag.manual]).sorted()
        return ([JoyTag.prefix] + others + [FileTag.manual]).filter(present.contains)
    }

    private func title(of source: String) -> String {
        switch source {
        case JoyTag.prefix: return JoyTag.tool
        // Who wrote them can't be known from the file: a person, or a tool
        // nobody has marked (pv-prefix-keywords marks those).
        case FileTag.manual: return "Keywords already in the photo"
        default: return records.first { $0.classifier == source }?.label ?? source.uppercased()
        }
    }

    private func describe(_ record: Classification) -> String {
        var parts: [String] = []
        if let v = record.version { parts.append("Version \(v)") }
        if let t = record.classifiedAt {
            parts.append(Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private var folderText: String {
        let prefix = VolumeLocator.mediaDirName
        let folder = item.folder
        if folder == prefix { return "Photos" }
        return folder.split(separator: "/").joined(separator: " › ")
    }

    private var formatText: String {
        let ext = (item.relPath as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }

    private var dateText: String {
        guard let t = item.capturedAt else { return "Unknown" }
        return Self.dateText(t)
    }

    private static func dateText(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(date: .long, time: .shortened)
    }

    private func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.5))
    }
}
