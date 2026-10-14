import Foundation

/// One growing file holding every thumbnail back to back, addressed by
/// (offset, length) pairs stored in SQLite.
///
/// Two deliberate choices here:
///
/// 1. `pread`, not `mmap`. Mapping the pack would make reads a memcpy, but if
///    the volume disappears while pages are mapped the next touch is a SIGBUS —
///    an uncatchable crash. With frequent ejection that trade is a bad one. The
///    unified buffer cache serves repeat reads from RAM anyway, so for ~30 KB
///    blobs almost nothing is lost, and a vanished volume surfaces as EIO.
///
/// 2. Append, F_FULLFSYNC, *then* commit the row pointing at the bytes. Crash in
///    between and you get orphaned bytes at the tail, which `truncateOrphans`
///    reclaims. Do it the other way and rows point at data that was never
///    written, which is indistinguishable from corruption.
public final class BlobPack {
    private let fd: Int32
    private var tail: Int64
    private let url: URL

    private static let magic: [UInt8] = [0x50, 0x56, 0x50, 0x4B]  // "PVPK"
    private static let headerSize: Int64 = 16

    public init(url: URL) throws {
        self.url = url
        // Bound to a local first: inside `init`, `self` isn't fully formed, so
        // the closures below can't capture `self.fd`.
        let handle = open(url.path, O_RDWR | O_CREAT, 0o644)
        self.fd = handle
        guard handle >= 0 else {
            throw VaultError.packCorrupt("open failed: \(String(cString: strerror(errno)))")
        }

        var st = stat()
        guard fstat(handle, &st) == 0 else {
            close(handle)
            throw VaultError.packCorrupt("fstat failed")
        }

        if st.st_size == 0 {
            var header = [UInt8](repeating: 0, count: Int(BlobPack.headerSize))
            header.replaceSubrange(0..<4, with: BlobPack.magic)
            header[4] = 1  // format version
            let written = header.withUnsafeBytes {
                pwrite(handle, $0.baseAddress, Int(BlobPack.headerSize), 0)
            }
            guard written == Int(BlobPack.headerSize) else {
                close(handle)
                throw VaultError.packCorrupt("could not write header")
            }
            _ = fcntl(handle, F_FULLFSYNC)
            tail = BlobPack.headerSize
        } else {
            var header = [UInt8](repeating: 0, count: 4)
            let n = header.withUnsafeMutableBytes { pread(handle, $0.baseAddress, 4, 0) }
            guard n == 4, header == BlobPack.magic else {
                close(handle)
                throw VaultError.packCorrupt("not a PhotoVault pack file")
            }
            tail = Int64(st.st_size)
        }
    }

    deinit { close(fd) }

    public var currentTail: Int64 { tail }

    /// Writes a blob at the tail and durably flushes it. Returns the coordinates
    /// the caller must then record in the catalog — in that order, never reversed.
    public func append(_ data: Data) throws -> (offset: Int64, length: Int) {
        let offset = tail
        let written = data.withUnsafeBytes {
            pwrite(fd, $0.baseAddress, data.count, off_t(offset))
        }
        guard written == data.count else {
            throw VaultError.packCorrupt("short write: \(written) of \(data.count)")
        }
        // F_FULLFSYNC, not fsync(): on macOS plain fsync only pushes to the drive
        // cache, which a yanked volume can still lose.
        guard fcntl(fd, F_FULLFSYNC) != -1 else {
            throw VaultError.packCorrupt("fsync failed")
        }
        tail += Int64(data.count)
        return (offset, data.count)
    }

    public func read(offset: Int64, length: Int) throws -> Data {
        guard length > 0, offset >= BlobPack.headerSize else {
            throw VaultError.packCorrupt("bad blob coordinates")
        }
        var buf = Data(count: length)
        let n = buf.withUnsafeMutableBytes {
            pread(fd, $0.baseAddress, length, off_t(offset))
        }
        guard n == length else { throw VaultError.shortRead }
        return buf
    }

    /// Drops bytes past the highest offset the catalog knows about — the residue
    /// of a crash between append and commit. Call once at open, after the
    /// catalog is readable.
    public func truncateOrphans(catalogTail: Int64) throws {
        let safeTail = max(catalogTail, BlobPack.headerSize)
        guard safeTail < tail else { return }
        guard ftruncate(fd, off_t(safeTail)) == 0 else {
            throw VaultError.packCorrupt("truncate failed")
        }
        _ = fcntl(fd, F_FULLFSYNC)
        tail = safeTail
    }

    public func sync() {
        _ = fcntl(fd, F_FULLFSYNC)
    }
}
