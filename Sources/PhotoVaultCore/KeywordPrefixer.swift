import Foundation

/// The one-off marking behind the `pv-prefix-keywords` command: records that
/// the keywords already in a vault's photos are one tool's output —
/// say they're another tagging tool's — so PhotoVault shows them under that tool's
/// name rather than as a person's own.
///
/// In the vault's catalog only: the photos aren't touched (by design —
/// rewriting every photo grows a vault's disk image, and tags live
/// in the catalog). A marked keyword stays the tool's when its file is
/// re-read, as long as the keyword is still there (see
/// `Catalog.setFileTags`). Run once, on one vault, with the app closed; it
/// covers the photos in the vault at that moment, and refuses photos it has
/// marked already.
public struct KeywordPrefixer {
    public let record: ToolRecord

    /// `prefix` and `label` are the tool's: `ext` and "OtherTagger", say. PhotoVault's
    /// own prefix can't be claimed.
    public init(prefix: String, label: String, version: String? = nil, date: Date = Date()) throws {
        let prefix = prefix.lowercased()
        guard ToolRecord.isValidPrefix(prefix) else {
            throw VaultError.cannotWriteTags("“\(prefix)” isn't a usable prefix: lower-case letters and digits only.")
        }
        guard prefix != JoyTag.prefix else {
            throw VaultError.cannotWriteTags("“\(JoyTag.prefix)” is PhotoVault's own prefix, for JoyTag.")
        }
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !label.contains(";") else {
            throw VaultError.cannotWriteTags("The label needs a name, without semicolons.")
        }
        record = ToolRecord(prefix: prefix, tool: label, version: version, date: date)
    }

    public struct Survey: Sendable {
        /// Photos with keywords to mark, and how many keywords that is.
        public var toMark: [PhotoItem] = []
        public var keywords = 0
        /// Photos marked already (or whose files declare the prefix
        /// themselves): left alone, never marked twice.
        public var alreadyMarked = 0
        /// Photos with no keyword of their own.
        public var nothingToMark = 0
    }

    /// What marking would do, read from the files themselves. Changes nothing.
    public func survey(root: URL, catalog: Catalog) throws -> Survey {
        var survey = Survey()
        for item in try catalog.presentPhotos() {
            if try catalog.classifications(photoID: item.id).contains(where: { $0.classifier == record.prefix }) {
                survey.alreadyMarked += 1
                continue
            }
            guard let file = TagReader.read(url: root.appendingPathComponent(item.relPath)) else {
                survey.nothingToMark += 1
                continue
            }
            if file.records.contains(where: { $0.prefix == record.prefix }) {
                survey.alreadyMarked += 1
                continue
            }
            let own = TagSources.split(file).filter { $0.source == FileTag.manual }.count
            guard own > 0 else { survey.nothingToMark += 1; continue }
            survey.toMark.append(item)
            survey.keywords += own
        }
        return survey
    }

    /// Marks each photo's own keywords as the tool's, in the catalog, one
    /// photo at a time — a photo whose tags the catalog hasn't read yet (one
    /// in the Trash, say) is read first. Returns a message per photo it
    /// couldn't mark.
    public func apply(_ photos: [PhotoItem], root: URL, catalog: Catalog,
                      progress: ((Int, Int) -> Void)? = nil) -> [String] {
        var failures: [String] = []
        for (n, item) in photos.enumerated() {
            do {
                try catalog.transaction {
                    if try catalog.tagsRead(photoID: item.id) != item.mtime {
                        let file = TagReader.read(url: root.appendingPathComponent(item.relPath)) ?? FileTags()
                        try catalog.setFileTags(photoID: item.id, tags: TagSources.split(file), records: file.records,
                                                fileMtime: item.mtime)
                    }
                    try catalog.markOwnKeywords(photoID: item.id, as: record)
                }
            } catch {
                failures.append("\(item.displayName): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            progress?(n + 1, photos.count)
        }
        return failures
    }
}
