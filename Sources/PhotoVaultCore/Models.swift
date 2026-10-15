import Foundation

public enum MediaType: Int, Sendable, Codable {
    case photo = 0
    case video = 1
}

/// One row of `photo`. Photos and videos share a table on purpose: mixed
/// chronological browsing is the point, and every album/grid query would
/// otherwise grow a union.
public struct PhotoItem: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var relPath: String
    public var fileSize: Int64
    public var mtime: Double
    public var contentKey: String?
    public var width: Int
    public var height: Int
    public var orientation: Int
    public var capturedAt: Double?
    public var favorite: Bool
    public var missing: Bool
    public var mediaType: MediaType
    public var duration: Double?
    public var posterTime: Double?
    public var playable: Bool
    public var thumbOff: Int64?
    public var thumbLen: Int?
    /// In the Trash: hidden from every other view, out of every album, and
    /// deleted from disk only when the Trash is emptied.
    public var trashed: Bool
    /// The capture date came from the photo itself (EXIF/XMP/IPTC or the
    /// video's creation date). False means `capturedAt` is only the file date.
    public var hasDate: Bool
    /// When the file was created, as Finder's Date Created shows it. Nil if
    /// the file system doesn't record one.
    public var createdAt: Double?

    public init(
        id: Int64 = 0,
        relPath: String,
        fileSize: Int64 = 0,
        mtime: Double = 0,
        contentKey: String? = nil,
        width: Int = 0,
        height: Int = 0,
        orientation: Int = 1,
        capturedAt: Double? = nil,
        favorite: Bool = false,
        missing: Bool = false,
        mediaType: MediaType = .photo,
        duration: Double? = nil,
        posterTime: Double? = nil,
        playable: Bool = true,
        thumbOff: Int64? = nil,
        thumbLen: Int? = nil,
        trashed: Bool = false,
        hasDate: Bool = false,
        createdAt: Double? = nil
    ) {
        self.id = id
        self.relPath = relPath
        self.fileSize = fileSize
        self.mtime = mtime
        self.contentKey = contentKey
        self.width = width
        self.height = height
        self.orientation = orientation
        self.capturedAt = capturedAt
        self.favorite = favorite
        self.missing = missing
        self.mediaType = mediaType
        self.duration = duration
        self.posterTime = posterTime
        self.playable = playable
        self.thumbOff = thumbOff
        self.thumbLen = thumbLen
        self.trashed = trashed
        self.hasDate = hasDate
        self.createdAt = createdAt
    }

    public var hasThumb: Bool { thumbOff != nil && (thumbLen ?? 0) > 0 }

    public var displayName: String {
        (relPath as NSString).lastPathComponent
    }

    /// The folder the file is directly in, relative to the volume root
    /// (`Photos`, `Photos/2019/summer`).
    public var folder: String { Self.folder(of: relPath) }

    public static func folder(of relPath: String) -> String {
        (relPath as NSString).deletingLastPathComponent
    }

    /// The natural-order sort key for a path: its place under `Photos/`.
    public static func sortName(of relPath: String) -> String {
        let prefix = VolumeLocator.mediaDirName + "/"
        let inside = relPath.hasPrefix(prefix) ? String(relPath.dropFirst(prefix.count)) : relPath
        return NaturalSort.key(inside)
    }
}

/// Finder-style "natural" ordering, as a plain string key SQLite can sort on.
///
/// Digit runs compare as numbers, so `_2343` comes before `_10634` — plain
/// alphabetical order would put them the other way round. Case, accents and
/// character widths are ignored, as in Finder. Each digit run is padded to a
/// fixed width, so ordinary string comparison gives numeric order.
public enum NaturalSort {
    static let width = 20

    public static func key(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            let trimmed = String(digits.drop { $0 == "0" })
            let value = trimmed.isEmpty ? "0" : trimmed
            out += String(repeating: "0", count: max(0, width - value.count)) + value
            digits = ""
        }
        for ch in folded {
            if ch.isASCII && ch.isNumber {
                digits.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }
}

/// How a view is ordered: everything but albums, which keep their own order.
/// Libraries from phones and cameras want the date taken; a library of scans
/// with no dates wants file names, or the dates the files were made.
public enum PhotoOrder: String, Sendable, CaseIterable {
    /// The date in the photo; for a photo without one, its file's modified date.
    case date
    /// The file's creation date, as Finder shows it.
    case created
    case name
    /// The order photos were added to an album. Albums only.
    case added
    /// Videos by how long they play; a photo counts as no length at all.
    case length
    /// A shuffle, the same each time the view is shown until it's chosen again
    /// (or shuffled again with the arrow button).
    case random

    public var label: String {
        switch self {
        case .date: return "Date Taken"
        case .created: return "Date Created"
        case .name: return "File Name"
        case .added: return "Album Order"
        case .length: return "Length"
        case .random: return "Random"
        }
    }

    /// The orders the Sort menu offers in a view: Album Order only in an album.
    public static func choices(for scope: LibraryScope) -> [PhotoOrder] {
        if case .album = scope { return [.added, .date, .created, .name, .length, .random] }
        return [.date, .created, .name, .length, .random]
    }

    /// What each direction is called, for the button that flips it.
    public func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name: return ascending ? "A to Z" : "Z to A"
        case .date, .created, .added: return ascending ? "Oldest first" : "Newest first"
        case .length: return ascending ? "Shortest first" : "Longest first"
        case .random: return "Shuffled"
        }
    }

    /// Until someone picks one, a vault is ordered by date if at least half its
    /// photos carry a real capture date, and by file name otherwise. An empty
    /// vault starts on date, the common case.
    public static func defaultFor(datedCount: Int, total: Int) -> PhotoOrder {
        guard total > 0 else { return .date }
        return datedCount * 2 >= total ? .date : .name
    }
}

/// The name a copied album gets: "Beach (copy)", then "Beach (copy 2)" if
/// that's taken, and so on.
public enum CopyName {
    public static func of(_ name: String, among taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        let first = "\(name) (copy)"
        if !used.contains(first.lowercased()) { return first }
        var n = 2
        while used.contains("\(name) (copy \(n))".lowercased()) { n += 1 }
        return "\(name) (copy \(n))"
    }
}

/// A view's order, and which way it runs.
public struct SortSetting: Hashable, Sendable {
    public var order: PhotoOrder
    /// Oldest first, or A to Z.
    public var ascending: Bool
    /// Which shuffle Random shows: a new one each time it's chosen.
    public var seed: UInt64

    public init(order: PhotoOrder, ascending: Bool = true, seed: UInt64 = 0) {
        self.order = order
        self.ascending = ascending
        self.seed = seed
    }
}

/// A shuffle that's the same every time for the same seed: Random's order
/// doesn't jump about as the view reloads.
public enum Shuffle {
    public static func key(_ id: Int64, seed: UInt64) -> UInt64 {
        // SplitMix64's finaliser: every bit of the id and seed moves the result.
        var z = UInt64(bitPattern: id) &+ seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One folder in the tree under All Media.
public struct FolderNode: Identifiable, Hashable, Sendable {
    /// The folder's path relative to the volume root, e.g. `Photos/2019`.
    public var id: String
    public var name: String
    /// Photos directly in this folder; choosing it shows exactly these.
    public var directCount: Int
    /// Photos here and in every folder beneath it.
    public var totalCount: Int
    /// Nil for a folder with no subfolders, so the sidebar shows no disclosure
    /// arrow for it.
    public var children: [FolderNode]?

    /// Builds the tree under `root` from per-folder photo counts. Only folders
    /// holding photos (directly or somewhere beneath) appear; folders are in
    /// natural name order.
    public static func tree(directCounts: [String: Int], root: String = VolumeLocator.mediaDirName) -> FolderNode {
        var all = Set<String>([root])
        for folder in directCounts.keys where folder == root || folder.hasPrefix(root + "/") {
            var path = folder
            while path != root, !path.isEmpty {
                all.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        var kids: [String: [String]] = [:]
        for path in all where path != root {
            kids[(path as NSString).deletingLastPathComponent, default: []].append(path)
        }
        func build(_ path: String) -> FolderNode {
            let children = (kids[path] ?? [])
                .sorted { NaturalSort.key(($0 as NSString).lastPathComponent) < NaturalSort.key(($1 as NSString).lastPathComponent) }
                .map(build)
            let direct = directCounts[path] ?? 0
            return FolderNode(id: path, name: (path as NSString).lastPathComponent,
                              directCount: direct,
                              totalCount: direct + children.reduce(0) { $0 + $1.totalCount },
                              children: children.isEmpty ? nil : children)
        }
        return build(root)
    }
}

public struct Album: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var parentID: Int64?
    public var sortIndex: Int

    public init(id: Int64 = 0, name: String, parentID: Int64? = nil, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
    }
}

/// A smart album chooses its own photos: from tag rules, or, for an
/// older album, from a saved `WHERE` clause.
public struct SmartAlbum: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var predicate: String
    /// Set for an album built from tags; nil for a predicate album, which has
    /// no rules to edit.
    public var rules: TagRules?

    public init(id: Int64 = 0, name: String, predicate: String = "", rules: TagRules? = nil) {
        self.id = id
        self.name = name
        self.predicate = predicate
        self.rules = rules
    }
}

/// A smart album's tag rules. Tags and groups are included or excluded in the
/// order they were chosen — the order the filter panel lists them in.
/// `include` says whether a photo needs all the included items or any one;
/// `exclude` whether any excluded item hides a photo, or only all of them
/// together. A group counts as one item: a photo has it if it has any tag in
/// the group.
public struct TagRules: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case tag, group }
    public enum State: String, Codable, Sendable { case include, exclude }
    public enum Match: String, Codable, Sendable { case all, any }

    public struct Item: Codable, Hashable, Sendable {
        public var kind: Kind
        /// A tag's `TagKey`, or a group's name.
        public var name: String
        public var state: State

        public init(kind: Kind, name: String, state: State) {
            self.kind = kind
            self.name = name
            self.state = state
        }
    }

    public var items: [Item]
    public var include: Match
    public var exclude: Match

    public init(items: [Item] = [], include: Match = .all, exclude: Match = .any) {
        self.items = items
        self.include = include
        self.exclude = exclude
    }

    public func state(_ kind: Kind, _ name: String) -> State? {
        items.first { $0.kind == kind && $0.name == name }?.state
    }

    /// One click in the filter panel: off → include → exclude → off. A newly
    /// chosen item goes to the end of the list; changing one keeps its place.
    public mutating func cycle(_ kind: Kind, _ name: String) {
        guard let i = items.firstIndex(where: { $0.kind == kind && $0.name == name }) else {
            items.append(Item(kind: kind, name: name, state: .include))
            return
        }
        if items[i].state == .include { items[i].state = .exclude } else { items.remove(at: i) }
    }

    /// The rules as a SQL condition on photo `p`, with one bound JSON array of
    /// tag keys per `?`. A group's keys come from `groups` at the time of the
    /// query, so editing Tag Groups.txt updates every album that uses it;
    /// "Other" means any tag listed in no group. Nil when there are no rules:
    /// the album holds every photo.
    public func sql(groups: TagGroups) -> (clause: String, bindings: [String])? {
        var bindings: [String] = []
        func json(_ keys: [String]) -> String {
            String(data: (try? JSONEncoder().encode(keys)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        }
        func condition(_ item: Item) -> String {
            switch item.kind {
            case .tag:
                bindings.append(json([item.name]))
                return "EXISTS (SELECT 1 FROM tag t WHERE t.photo_id = p.id AND t.key IN (SELECT value FROM json_each(?)))"
            case .group where item.name == TagGroups.other:
                bindings.append(json(groups.names.flatMap { groups.members[$0] ?? [] }))
                return "EXISTS (SELECT 1 FROM tag t WHERE t.photo_id = p.id AND t.key NOT IN (SELECT value FROM json_each(?)))"
            case .group:
                bindings.append(json(groups.members[item.name] ?? []))
                return "EXISTS (SELECT 1 FROM tag t WHERE t.photo_id = p.id AND t.key IN (SELECT value FROM json_each(?)))"
            }
        }
        var parts: [String] = []
        let included = items.filter { $0.state == .include }.map(condition)
        if !included.isEmpty {
            parts.append("(" + included.joined(separator: include == .all ? " AND " : " OR ") + ")")
        }
        let excluded = items.filter { $0.state == .exclude }.map(condition)
        if !excluded.isEmpty {
            parts.append("NOT (" + excluded.joined(separator: exclude == .any ? " OR " : " AND ") + ")")
        }
        return parts.isEmpty ? nil : (parts.joined(separator: " AND "), bindings)
    }
}

/// What the grid is currently showing.
public enum LibraryScope: Hashable, Sendable {
    case all
    case favorites
    case album(Int64)
    case smart(Int64)
    case trash
    /// The photos directly in one folder (not its subfolders), e.g.
    /// `Photos/2019`.
    case folder(String)

    /// Whether a sort setting applies — everywhere, since albums gained the
    /// Sort menu (with Album Order) in 1.5.0.
    public var followsSortOrder: Bool { true }

    /// Which sort setting the view follows. The library has one — All Media and
    /// every folder in it, Favorites and the Trash — and each album and smart
    /// album remembers its own.
    public var sortKey: String {
        switch self {
        case .album(let id): return "sort.album.\(id)"
        case .smart(let id): return "sort.smart.\(id)"
        case .all, .favorites, .trash, .folder: return "sort"
        }
    }

    public var isAlbum: Bool {
        if case .album = self { return true }
        return false
    }

    /// Where the view's remembered place — the photo at the top of the screen
    /// when it was last looked at — is kept. One per view.
    /// The place for this view with `filter` applied. All, Photos and Videos
    /// each keep their own: a photo hidden by the filter can't be a place, and
    /// the filtered grid's top mustn't replace the unfiltered one's.
    public func placeKey(_ filter: MediaFilter) -> String {
        switch filter {
        case .all: return placeKey
        case .photos: return placeKey + ".photos"
        case .videos: return placeKey + ".videos"
        }
    }

    public var placeKey: String {
        switch self {
        case .all: return "place.all"
        case .favorites: return "place.favorites"
        case .trash: return "place.trash"
        case .folder(let path): return "place.folder.\(path)"
        case .album(let id): return "place.album.\(id)"
        case .smart(let id): return "place.smart.\(id)"
        }
    }
}

public enum MediaFilter: Int, Hashable, Sendable, CaseIterable {
    case all = 0
    case photos = 1
    case videos = 2

    public var label: String {
        switch self {
        case .all: return "All"
        case .photos: return "Photos"
        case .videos: return "Videos"
        }
    }
}

/// The set of extensions the scanner will pick up. Anything AVFoundation
/// cannot open still gets a row — it is marked `playable = 0` and badged,
/// which is far less confusing than silently omitting a file the user can see
/// in Finder.
public enum MediaKinds {
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp",
    ]
    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp",
    ]

    public static func mediaType(forExtension ext: String) -> MediaType? {
        let e = ext.lowercased()
        if photoExtensions.contains(e) { return .photo }
        if videoExtensions.contains(e) { return .video }
        return nil
    }
}

/// A tag across the vault: its key, how it's written, how many visible photos
/// carry it, and which sources it comes from.
public struct TagCount: Hashable, Sendable {
    public var key: String
    public var name: String
    public var photos: Int
    public var sources: Set<String>

    public init(key: String, name: String, photos: Int, sources: Set<String>) {
        self.key = key
        self.name = name
        self.photos = photos
        self.sources = sources
    }
}

/// One tag on one photo.
public struct PhotoTag: Hashable, Sendable {
    public var source: String
    public var name: String
    public var key: String
    public var confidence: Double?
}

/// One tool's tagging of one photo: which tool, which version, when, and
/// whether the record is in the file or only in the catalog.
public struct Classification: Hashable, Sendable {
    public var classifier: String
    public var label: String?
    public var version: String?
    public var classifiedAt: Double?
    public var inFile: Bool
}
