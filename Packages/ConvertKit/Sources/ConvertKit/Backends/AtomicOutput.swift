import Foundation

enum AtomicOutput {
    static func prepareTemporaryURL(for output: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ConversionError.cannotCreateOutput
        }
        return output.deletingLastPathComponent().appendingPathComponent(
            ".reel-convert-\(UUID().uuidString).\(output.pathExtension)"
        )
    }

    static func commit(_ temporary: URL, to output: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
        } catch {
            throw ConversionError.cannotCreateOutput
        }
    }
}
