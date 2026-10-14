import Foundation
import CryptoKit

/// File size plus a SHA-256 of the first 64 KB.
///
/// Cheap enough to compute during a scan, and distinctive enough that a file
/// which turns up under a new path can be recognised as the same photo — which
/// is what lets a moved file keep its album memberships instead of orphaning
/// them. It is also the join key for merging two diverged copies of a vault,
/// because it says nothing about where the file currently lives.
public enum ContentKey {
    public static let probeBytes = 64 * 1024

    public static func compute(url: URL, fileSize: Int64) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: probeBytes)) ?? Data()
        let digest = SHA256.hash(data: head)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(fileSize):\(hex)"
    }
}
