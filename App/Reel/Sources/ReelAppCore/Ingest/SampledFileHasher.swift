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
}
