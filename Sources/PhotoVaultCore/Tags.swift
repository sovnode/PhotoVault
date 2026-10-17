import Foundation
import ImageIO

/// PhotoVault's own XMP namespace. Its `classifications` field lists which
/// tools have tagged the photo, one record per tool (see `ToolRecord`). The
/// `.local` host is reserved, so the namespace can never belong to anyone else.
public enum PhotoVaultXMP {
    public static let namespace = "http://ns.photovault.local/1.0/"
    public static let prefix = "pv"
    public static let classifications = "classifications"
}

/// How tags from different sources are matched: lower case, a space for an
/// underscore, single spaces. JoyTag's `blonde_hair`, a hand-typed
/// `Blonde hair` and a line `blonde hair` in Tag Groups.txt are all one tag.
public enum TagKey {
    public static func key(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// How PhotoVault shows and writes a JoyTag tag: spaces for underscores,
    /// except in emoticons such as `^_^`, where the underscore is the mouth.
    public static func display(_ tag: String) -> String {
        tag.filter(\.isLetter).count > 2 ? tag.replacingOccurrences(of: "_", with: " ") : tag
    }
}

/// One tool's record in a photo's `pv:classifications`: which prefix its tags
/// carry, which tool and version wrote them, and when. JoyTag's record is how
/// PhotoVault knows a photo has been classified; another tool's record declares
/// its prefix, so its tags are shown under its name.
///
/// Stored as a line of `key=value` pairs, e.g.
/// `prefix=jt; tool=JoyTag; version=6b7f163; date=2026-10-14T00:00:00Z`.
public struct ToolRecord: Hashable, Sendable {
    public var prefix: String
    public var tool: String
    public var version: String?
    public var date: Date?

    public init(prefix: String, tool: String, version: String? = nil, date: Date? = nil) {
        self.prefix = prefix
        self.tool = tool
        self.version = version
        self.date = date
    }

    /// Reads a record, tolerating extra spaces, unknown keys and any order.
    /// Nil without a usable prefix.
    public init?(parsing line: String) {
        var fields: [String: String] = [:]
        for part in line.split(separator: ";") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        guard let prefix = fields["prefix"]?.lowercased(), ToolRecord.isValidPrefix(prefix) else { return nil }
        self.prefix = prefix
        self.tool = fields["tool"] ?? prefix
        self.version = fields["version"]
        self.date = fields["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    public var line: String {
        var parts = ["prefix=\(prefix)", "tool=\(tool)"]
        if let version { parts.append("version=\(version)") }
        if let date { parts.append("date=\(ISO8601DateFormatter().string(from: date))") }
        return parts.joined(separator: "; ")
    }

    /// Lower-case letters and digits, as in `jt` and `ext`.
    public static func isValidPrefix(_ p: String) -> Bool {
        !p.isEmpty && p.count <= 16 && p.allSatisfy { ($0.isLetter && $0.isLowercase && $0.isASCII) || $0.isNumber }
    }
}

/// What a photo file says about its tags.
public struct FileTags: Hashable, Sendable {
    public var keywords: [String]
    public var records: [ToolRecord]

    public init(keywords: [String] = [], records: [ToolRecord] = []) {
        self.keywords = keywords
        self.records = records
    }
}

/// A tag as the catalog stores it: where it came from, how it's written, and
/// the key it merges on.
public struct FileTag: Hashable, Sendable {
    /// `jt` (JoyTag, PhotoVault's own), a prefix another tool declared in the
    /// photo, or `manual` — a person's own keyword.
    public var source: String
    public var name: String
    public var key: String

    public init(source: String, name: String) {
        self.source = source
        self.name = name
        self.key = TagKey.key(name)
    }

    public static let manual = "manual"
}

public enum TagReader {
    /// The keywords and PhotoVault records in a photo file — XMP `dc:subject`,
    /// or the IPTC keywords if there's no XMP list. Reads the header only.
    /// Nil if the file can't be read as an image.
    public static func read(url: URL) -> FileTags? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let raw = readRaw(source)
        return FileTags(keywords: raw.keywords, records: raw.recordLines.compactMap(ToolRecord.init(parsing:)))
    }

    /// The keywords, and PhotoVault's record lines exactly as stored — lines it
    /// can't parse included, so a rewrite keeps what it doesn't understand.
    static func readRaw(_ source: CGImageSource) -> (keywords: [String], recordLines: [String]) {
        var keywords: [String] = [], lines: [String] = []
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            if let subject = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString) {
                keywords = strings(in: subject)
            }
            // Matched by namespace rather than by the "pv" prefix, which another
            // app rewriting the metadata is free to rename.
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
                if CGImageMetadataTagCopyNamespace(tag) as String? == PhotoVaultXMP.namespace,
                   CGImageMetadataTagCopyName(tag) as String? == PhotoVaultXMP.classifications {
                    lines = strings(in: tag)
                }
                return true
            }
        }
        if keywords.isEmpty,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if let list = iptc[kCGImagePropertyIPTCKeywords] as? [String] {
                keywords = list
            } else if let one = iptc[kCGImagePropertyIPTCKeywords] as? String {
                keywords = [one]
            }
        }
        return (keywords, lines)
    }

    private static func strings(in tag: CGImageMetadataTag) -> [String] {
        let value = CGImageMetadataTagCopyValue(tag)
        if let items = value as? [CGImageMetadataTag] {
            return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        if let one = value as? String { return [one] }
        return []
    }
}

public enum TagSources {
    /// Sorts a file's keywords by source. `jt:` is always PhotoVault's own; any
    /// other `prefix:` counts only if a record in the photo declares it;
    /// everything else — including keywords that merely contain a colon — is a
    /// person's own tag, kept exactly as written.
    public static func split(_ file: FileTags) -> [FileTag] {
        let declared = Set(file.records.map(\.prefix)).union([JoyTag.prefix])
        var seen = Set<String>()
        var out: [FileTag] = []
        for raw in file.keywords {
            let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { continue }
            var tag = FileTag(source: FileTag.manual, name: keyword)
            if let (prefix, rest) = prefixed(keyword), declared.contains(prefix) {
                tag = FileTag(source: prefix, name: rest)
            }
            guard !tag.key.isEmpty, seen.insert(tag.source + "\u{1}" + tag.key).inserted else { continue }
            out.append(tag)
        }
        return out
    }

    /// `prefix:rest` split at the first colon, the prefix in lower case — or nil
    /// if there's no colon or nothing after it. Whether the prefix counts depends
    /// on the photo's records (see `split`).
    public static func prefixed(_ keyword: String) -> (prefix: String, rest: String)? {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = keyword.firstIndex(of: ":") else { return nil }
        let rest = keyword[keyword.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (keyword[..<colon].lowercased(), rest)
    }
}

/// JoyTag's identity in PhotoVault.
public enum JoyTag {
    public static let prefix = "jt"
    public static let tool = "JoyTag"
}

/// Tag Groups.txt: which group each tag is listed under. `[Group]` lines start a
/// group, each following line is a tag, `#` starts a comment. Matching uses
/// `TagKey`, so case and underscores don't matter. A tag may be in several
/// groups; one in none belongs to `TagGroups.other`.
public struct TagGroups: Sendable, Equatable {
    public static let other = "Other"
    /// In the vault's top folder, hidden: Finder shows it once hidden files
    /// are shown (⌘⇧.). Vaults set up before 1.3.0 have it visible, as
    /// `legacyFileName`, until the vault scripts rename it.
    public static let fileName = ".Tag Groups.txt"
    public static let legacyFileName = "Tag Groups.txt"

    /// Group names in file order.
    public private(set) var names: [String] = []
    /// Each group's tag keys, in file order.
    public private(set) var members: [String: [String]] = [:]
    private var groupsOf: [String: [String]] = [:]

    public init(text: String) {
        var current: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { current = nil; continue }
                if members[name] == nil { names.append(name); members[name] = [] }
                current = name
            } else if let group = current {
                let key = TagKey.key(line)
                guard !key.isEmpty else { continue }
                if !(groupsOf[key]?.contains(group) ?? false) {
                    members[group, default: []].append(key)
                    groupsOf[key, default: []].append(group)
                }
            }
        }
    }

    public init(url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    /// The groups a tag is listed under, or `[Other]`.
    public func groups(of key: String) -> [String] {
        groupsOf[key] ?? [TagGroups.other]
    }

    /// The group of nude and explicit tags, hidden unless asked for.
    public static let restricted = "R18"

    /// Whether a tag is listed in the R18 group — in this vault's own groups
    /// file, where it can be moved in or out.
    public func isRestricted(_ key: String) -> Bool {
        groupsOf[key]?.contains(TagGroups.restricted) ?? false
    }

    /// Whether `rules` use R18: the group itself, or any tag in it.
    public func usesRestricted(_ rules: TagRules) -> Bool {
        rules.items.contains { item in
            item.kind == .group ? item.name == TagGroups.restricted : isRestricted(item.name)
        }
    }
}
