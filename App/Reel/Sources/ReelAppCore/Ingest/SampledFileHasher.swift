import CryptoKit
import Foundation

/// Computes Clip's O(1) first-edge, last-edge, and byte-size SHA-256 fingerprint.
public enum SampledFileHasher {
    private static let sampleSize = 1_024 * 1_024

    public static func hash(_ url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw IngestError.unreadable(url, underlying: "file could not be opened")
        }
        defer {
            do {
                try handle.close()
            } catch {
                // Closing a read-only handle cannot invalidate a completed hash.
            }
        }

        let size: UInt64
        do {
            size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            throw IngestError.unreadable(url, underlying: "file could not be sampled")
        }

        var hasher = SHA256()
        do {
            let first = try handle.read(upToCount: sampleSize) ?? Data()
            hasher.update(data: first)
            let lastOffset = size > UInt64(sampleSize) ? size - UInt64(sampleSize) : 0
            try handle.seek(toOffset: lastOffset)
            let last = try handle.read(upToCount: sampleSize) ?? Data()
            hasher.update(data: last)
        } catch {
            throw IngestError.unreadable(url, underlying: "file could not be sampled")
        }

        var littleEndianSize = size.littleEndian
        withUnsafeBytes(of: &littleEndianSize) { bytes in
            hasher.update(bufferPointer: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprints in-memory bytes with the identical scheme ``hash(_:)-6``
    /// applies on disk, so a text file saved from the editor dedupes against the
    /// same bytes ingested from a file. Used on the writable-text save path,
    /// where the contents exist only in memory until they are written.
    public static func hash(_ data: Data) -> String {
        let size = UInt64(data.count)
        var hasher = SHA256()
        hasher.update(data: data.prefix(sampleSize))
        let lastOffset = size > UInt64(sampleSize) ? Int(size) - sampleSize : 0
        hasher.update(data: data.suffix(from: lastOffset).prefix(sampleSize))
        var littleEndianSize = size.littleEndian
        withUnsafeBytes(of: &littleEndianSize) { bytes in
            hasher.update(bufferPointer: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
