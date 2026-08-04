import CZlib
import Foundation

public struct SyncTeXPDFLocation: Sendable, Equatable {
    public var page: Int
    /// Horizontal PDF coordinate in points from the left edge.
    public var x: Double
    /// Vertical PDF coordinate in points from the top edge.
    public var y: Double
    public var width: Double
    public var height: Double

    public init(page: Int, x: Double, y: Double, width: Double, height: Double) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SyncTeXSourceLocation: Sendable, Equatable {
    public var file: String
    public var line: Int
    public var column: Int?

    public init(file: String, line: Int, column: Int? = nil) {
        self.file = file
        self.line = line
        self.column = column
    }
}

public enum SyncTeXError: Error, Sendable, Equatable {
    case unreadable
    case invalidArchive
    case expandedDataTooLarge
    case malformed
}

extension SyncTeXError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable: "The SyncTeX map could not be read."
        case .invalidArchive: "The SyncTeX map is not a valid gzip stream."
        case .expandedDataTooLarge: "The SyncTeX map exceeds Clip's safety limit."
        case .malformed: "The SyncTeX map is malformed."
        }
    }
}

/// A bounded, immutable index over the records in a SyncTeX sidecar.
public struct SyncTeXIndex: Sendable, Equatable {
    private static let scaledPointsPerPDFPoint = 65_781.76
    private static let expandedSizeLimit = 100 * 1_024 * 1_024

    private struct Record: Sendable, Equatable {
        var tag: Int
        var line: Int
        var column: Int?
        var location: SyncTeXPDFLocation
    }

    private struct RawBox {
        var height: Double
        var depth: Double
    }

    private var inputs: [Int: String]
    private var records: [Record]

    public init(contentsOf url: URL) throws {
        guard let compressed = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw SyncTeXError.unreadable
        }
        let data = try Self.gunzip(compressed)
        guard let source = String(data: data, encoding: .utf8) else {
            throw SyncTeXError.malformed
        }
        try self.init(synctexText: source)
    }

    public init(synctexText source: String) throws {
        var inputs: [Int: String] = [:]
        var records: [Record] = []
        var page: Int?
        var unit = 1.0
        var magnification = 1_000.0
        var xOffset = 0.0
        var yOffset = 0.0
        var boxes: [RawBox] = []

        for line in source.split(whereSeparator: \.isNewline) {
            let value = String(line)
            if value.hasPrefix("Input:") {
                let fields = value.dropFirst(6).split(separator: ":", maxSplits: 1)
                if fields.count == 2, let tag = Int(fields[0]), !fields[1].isEmpty {
                    inputs[tag] = String(fields[1])
                }
                continue
            }
            if value.hasPrefix("Unit:"), let parsed = Double(value.dropFirst(5)) {
                unit = parsed
                continue
            }
            if value.hasPrefix("Magnification:"),
                let parsed = Double(value.dropFirst("Magnification:".count))
            {
                magnification = parsed
                continue
            }
            if value.hasPrefix("X Offset:"), let parsed = Double(value.dropFirst(9)) {
                xOffset = parsed
                continue
            }
            if value.hasPrefix("Y Offset:"), let parsed = Double(value.dropFirst(9)) {
                yOffset = parsed
                continue
            }
            if value.first == "{", let parsed = Int(value.dropFirst()) {
                page = parsed
                boxes.removeAll(keepingCapacity: true)
                continue
            }
            if value.first == "}" {
                page = nil
                boxes.removeAll(keepingCapacity: true)
                continue
            }
            if value == "]" || value == ")" {
                if !boxes.isEmpty { boxes.removeLast() }
                continue
            }
            guard let page, let parsed = Self.parseRecord(value) else { continue }
            let inherited = boxes.last
            let rawHeight = parsed.height == 0 ? inherited?.height ?? 0 : parsed.height
            let rawDepth = parsed.depth == 0 ? inherited?.depth ?? 0 : parsed.depth
            let scale = unit * (magnification / 1_000) / Self.scaledPointsPerPDFPoint
            let width = max(abs(parsed.width * scale), 8)
            let height = max(abs((rawHeight + rawDepth) * scale), 10)
            let location = SyncTeXPDFLocation(
                page: page,
                x: (parsed.x * unit + xOffset) * (magnification / 1_000)
                    / Self.scaledPointsPerPDFPoint,
                y: ((parsed.y - rawHeight) * unit + yOffset) * (magnification / 1_000)
                    / Self.scaledPointsPerPDFPoint,
                width: width,
                height: height
            )
            records.append(
                Record(
                    tag: parsed.tag,
                    line: parsed.line,
                    column: parsed.column,
                    location: location
                )
            )
            if parsed.opensBox {
                boxes.append(RawBox(height: rawHeight, depth: rawDepth))
            }
        }
        guard !inputs.isEmpty, !records.isEmpty else { throw SyncTeXError.malformed }
        self.inputs = inputs
        self.records = records
    }

    public func forwardSearch(file: String, line: Int) -> SyncTeXPDFLocation? {
        let matchingInputs = inputs.filter { Self.pathsMatch($0.value, file) }
        let minimumExtraComponents = matchingInputs.values.map {
            max(
                Self.pathComponents($0).count - Self.pathComponents(file).count,
                0
            )
        }.min()
        let matchingTags = Set(
            matchingInputs.compactMap { tag, path in
                let extraComponents = max(
                    Self.pathComponents(path).count - Self.pathComponents(file).count,
                    0
                )
                return extraComponents == minimumExtraComponents ? tag : nil
            }
        )
        return
            records
            .filter { matchingTags.contains($0.tag) && $0.line == line }
            .min { lhs, rhs in
                let leftArea = lhs.location.width * lhs.location.height
                let rightArea = rhs.location.width * rhs.location.height
                if leftArea == rightArea { return lhs.location.x < rhs.location.x }
                return leftArea < rightArea
            }?.location
    }

    /// Resolves a PDF point expressed from the page's top-left edge.
    public func inverseSearch(
        page: Int,
        x: Double,
        y: Double,
        maximumDistance: Double = 36
    ) -> SyncTeXSourceLocation? {
        let candidates = records.compactMap { record -> (Record, Double, Double)? in
            guard record.location.page == page, inputs[record.tag] != nil else { return nil }
            let rect = record.location
            // Page and large container boxes inherit a source line but are not
            // useful inverse-search targets; accepting them would map almost
            // every blank page click to the document's closing line.
            guard rect.height <= 144, rect.width <= 540 else { return nil }
            let dx = max(rect.x - x, 0, x - (rect.x + rect.width))
            let dy = max(rect.y - y, 0, y - (rect.y + rect.height))
            let distance = hypot(dx, dy)
            return (record, distance, rect.width * rect.height)
        }
        guard
            let match = candidates.min(by: { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.2 < rhs.2 }
                return lhs.1 < rhs.1
            }), match.1 <= maximumDistance,
            let file = inputs[match.0.tag]
        else { return nil }
        return SyncTeXSourceLocation(
            file: file,
            line: match.0.line,
            column: match.0.column
        )
    }

    private static func pathsMatch(_ indexed: String, _ requested: String) -> Bool {
        if indexed == requested { return true }
        let indexedURL = URL(fileURLWithPath: indexed).standardizedFileURL
        let requestedURL = URL(fileURLWithPath: requested).standardizedFileURL
        if indexedURL == requestedURL { return true }
        return indexed.hasSuffix("/\(requested)")
    }

    private static func pathComponents(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    private struct ParsedRecord {
        var tag: Int
        var line: Int
        var column: Int?
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var depth: Double
        var opensBox: Bool
    }

    private static func parseRecord(_ source: String) -> ParsedRecord? {
        guard let marker = source.first, "[(hvxkg".contains(marker) else { return nil }
        let fields = source.dropFirst().split(separator: ":", maxSplits: 2)
        guard fields.count >= 2 else { return nil }
        let sourceFields = fields[0].split(separator: ",")
        let positionFields = fields[1].split(separator: ",")
        guard sourceFields.count >= 2, positionFields.count >= 2,
            let tag = Int(sourceFields[0]), let line = Int(sourceFields[1]), line > 0,
            let x = Double(positionFields[0]), let y = Double(positionFields[1])
        else { return nil }
        let dimensions = fields.count == 3 ? fields[2].split(separator: ",") : []
        return ParsedRecord(
            tag: tag,
            line: line,
            column: sourceFields.count > 2 ? Int(sourceFields[2]) : nil,
            x: x,
            y: y,
            width: dimensions.first.flatMap(Double.init) ?? 0,
            height: dimensions.count > 1 ? Double(dimensions[1]) ?? 0 : 0,
            depth: dimensions.count > 2 ? Double(dimensions[2]) ?? 0 : 0,
            opensBox: marker == "[" || marker == "("
        )
    }

    private static func gunzip(_ compressed: Data) throws -> Data {
        var stream = z_stream()
        guard
            inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout.size(ofValue: stream)))
                == Z_OK
        else { throw SyncTeXError.invalidArchive }
        defer { inflateEnd(&stream) }

        return try compressed.withUnsafeBytes { rawInput in
            guard let input = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                throw SyncTeXError.invalidArchive
            }
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(compressed.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            let bufferSize = buffer.count
            var status = Z_OK
            repeat {
                status = buffer.withUnsafeMutableBytes { rawOutput in
                    stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bufferSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw SyncTeXError.invalidArchive
                }
                let produced = bufferSize - Int(stream.avail_out)
                result.append(contentsOf: buffer.prefix(produced))
                guard result.count <= expandedSizeLimit else {
                    throw SyncTeXError.expandedDataTooLarge
                }
            } while status != Z_STREAM_END
            return result
        }
    }
}
