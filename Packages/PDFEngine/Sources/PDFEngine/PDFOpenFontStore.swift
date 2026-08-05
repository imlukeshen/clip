import CoreModel
import CoreText
import CryptoKit
import Foundation

public struct PDFFontResolution: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case exactSystemFont
        case cachedOpenFont
        case downloadedOpenFont
    }

    public var font: PDFFontDescriptor
    public var source: Source
    public var detail: String

    public init(font: PDFFontDescriptor, source: Source, detail: String) {
        self.font = font
        self.source = source
        self.detail = detail
    }
}

public enum PDFOpenFontStoreError: Error, Sendable, Equatable {
    case invalidResponse
    case downloadTooLarge
    case integrityCheckFailed
    case cacheWriteFailed
}

/// Resolves missing PDF fonts without executing packages or trusting URLs from
/// a document. Downloads are restricted to a pinned Google Fonts revision,
/// verified with SHA-256, and stored in an inspectable per-library cache.
public final class PDFOpenFontStore: @unchecked Sendable {
    public let cacheDirectory: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(cacheDirectory: URL, fileManager: FileManager = .default) {
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
    }

    public func exactFontIsInstalled(_ descriptor: PDFFontDescriptor) -> Bool {
        let requested = Self.normalizedFontName(descriptor.postScriptName)
        let font = CTFontCreateWithName(descriptor.postScriptName as CFString, 12, nil)
        let resolved = Self.normalizedFontName(CTFontCopyPostScriptName(font) as String)
        return requested == resolved
    }

    public func cachedData(for postScriptName: String) -> Data? {
        guard let package = OpenFontPackage.package(named: postScriptName) else { return nil }
        return lock.withLock {
            let url = cacheDirectory.appendingPathComponent(package.filename)
            guard let data = try? Data(contentsOf: url), package.isValid(data) else {
                return nil
            }
            return data
        }
    }

    public func resolve(
        _ descriptor: PDFFontDescriptor,
        requiredCharacters: Set<Character>,
        allowsDownload: Bool
    ) async throws -> PDFFontResolution? {
        if !descriptor.isSubset, exactFontIsInstalled(descriptor) {
            return PDFFontResolution(
                font: descriptor,
                source: .exactSystemFont,
                detail: "Using installed font \(descriptor.postScriptName)."
            )
        }
        let package = OpenFontPackage.bestMatch(
            for: descriptor,
            requiredCharacters: requiredCharacters
        )
        if cachedData(for: package.postScriptName) != nil {
            return resolution(for: package, source: .cachedOpenFont)
        }
        guard allowsDownload else { return nil }
        let (data, response) = try await URLSession.shared.data(from: package.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PDFOpenFontStoreError.invalidResponse
        }
        guard data.count <= 24 * 1_024 * 1_024 else {
            throw PDFOpenFontStoreError.downloadTooLarge
        }
        guard package.isValid(data) else {
            throw PDFOpenFontStoreError.integrityCheckFailed
        }
        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let destination = cacheDirectory.appendingPathComponent(package.filename)
            try data.write(to: destination, options: .atomic)
            try package.metadata(requiredCharacters: requiredCharacters).write(
                to: cacheDirectory.appendingPathComponent("\(package.identifier).json"),
                options: .atomic
            )
        } catch {
            throw PDFOpenFontStoreError.cacheWriteFailed
        }
        return resolution(for: package, source: .downloadedOpenFont)
    }

    private func resolution(
        for package: OpenFontPackage,
        source: PDFFontResolution.Source
    ) -> PDFFontResolution {
        PDFFontResolution(
            font: PDFFontDescriptor(
                postScriptName: package.postScriptName,
                familyName: package.familyName,
                isEmbedded: true,
                isSubset: false
            ),
            source: source,
            detail: "\(package.familyName) substituted safely for unavailable PDF glyphs."
        )
    }

    private static func normalizedFontName(_ value: String) -> String {
        let withoutSubset: Substring
        if PDFFontDescriptor.hasSubsetPrefix(value) {
            withoutSubset = value.dropFirst(7)
        } else {
            withoutSubset = value[...]
        }
        return withoutSubset.lowercased().filter(\.isLetter)
    }
}

private struct OpenFontPackage: Sendable {
    static let pinnedRevision = "2796410152d4f9524b68ed46e69c1b60f8e0f7c3"

    let identifier: String
    let familyName: String
    let postScriptName: String
    let filename: String
    let repositoryPath: String
    let sha256: String

    var url: URL {
        guard
            let url = URL(
                string:
                    "https://raw.githubusercontent.com/google/fonts/\(Self.pinnedRevision)/\(repositoryPath)"
            )
        else {
            preconditionFailure("The bundled open-font URL must be valid")
        }
        return url
    }

    static func bestMatch(
        for descriptor: PDFFontDescriptor,
        requiredCharacters: Set<Character>
    ) -> Self {
        let scalars = requiredCharacters.flatMap(\.unicodeScalars).map(\.value)
        if scalars.contains(where: {
            (0x0600...0x06FF).contains($0) || (0x0750...0x077F).contains($0)
        }) {
            return arabic
        }
        if scalars.contains(where: { (0x0900...0x097F).contains($0) }) {
            return devanagari
        }
        if scalars.contains(where: {
            (0x3040...0x30FF).contains($0) || (0x3400...0x9FFF).contains($0)
                || (0xAC00...0xD7AF).contains($0)
        }) {
            return cjk
        }
        let name = "\(descriptor.postScriptName) \(descriptor.familyName ?? "")".lowercased()
        if name.contains("mono") || name.contains("courier") || descriptor.flags & 1 != 0 {
            return mono
        }
        if name.contains("serif") || name.contains("times") || descriptor.flags & 2 != 0 {
            return serif
        }
        return sans
    }

    static func package(named postScriptName: String) -> Self? {
        [sans, serif, mono, arabic, devanagari, cjk].first {
            $0.postScriptName == postScriptName
        }
    }

    func isValid(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    func metadata(requiredCharacters: Set<Character>) throws -> Data {
        let value = FontPackageMetadata(
            family: familyName,
            postScriptName: postScriptName,
            source: url.absoluteString,
            revision: Self.pinnedRevision,
            sha256: sha256,
            license: "SIL Open Font License 1.1",
            licenseURL: "https://github.com/google/fonts/blob/\(Self.pinnedRevision)/ofl/OFL.txt",
            requestedCharacters: String(requiredCharacters.sorted())
        )
        return try JSONEncoder().encode(value)
    }

    static let sans = OpenFontPackage(
        identifier: "lato-regular",
        familyName: "Lato",
        postScriptName: "Lato-Regular",
        filename: "Lato-Regular.ttf",
        repositoryPath: "ofl/lato/Lato-Regular.ttf",
        sha256: "d636e4683231f931eda222d588e944d082bfd3bdba02f928bee461c0f185b251"
    )

    static let serif = OpenFontPackage(
        identifier: "spectral-regular",
        familyName: "Spectral",
        postScriptName: "Spectral-Regular",
        filename: "Spectral-Regular.ttf",
        repositoryPath: "ofl/spectral/Spectral-Regular.ttf",
        sha256: "c89021dc20720c8d0dcf40b0b2f6e00c13665fa8041717f581396f51b8c78f5d"
    )

    static let mono = OpenFontPackage(
        identifier: "ibm-plex-mono-regular",
        familyName: "IBM Plex Mono",
        postScriptName: "IBMPlexMono-Regular",
        filename: "IBMPlexMono-Regular.ttf",
        repositoryPath: "ofl/ibmplexmono/IBMPlexMono-Regular.ttf",
        sha256: "6a3412f058c7d8dfd9170c41e85ade48e5156ecb89356110ca57a0a27734af46"
    )

    static let arabic = OpenFontPackage(
        identifier: "noto-sans-arabic",
        familyName: "Noto Sans Arabic",
        postScriptName: "NotoSansArabic",
        filename: "NotoSansArabic.ttf",
        repositoryPath: "ofl/notosansarabic/NotoSansArabic%5Bwdth%2Cwght%5D.ttf",
        sha256: "63111b5b2e074dd48cc67692e0a2726d86ee94c1c37fe8598257b7b4e87e869e"
    )

    static let devanagari = OpenFontPackage(
        identifier: "noto-sans-devanagari",
        familyName: "Noto Sans Devanagari",
        postScriptName: "NotoSansDevanagari",
        filename: "NotoSansDevanagari.ttf",
        repositoryPath: "ofl/notosansdevanagari/NotoSansDevanagari%5Bwdth%2Cwght%5D.ttf",
        sha256: "9ce7b04f60e363d8870e5997744cf85cf69d38a4d7d129d364d92a3b14b461d7"
    )

    static let cjk = OpenFontPackage(
        identifier: "noto-sans-cjk",
        familyName: "Noto Sans CJK",
        postScriptName: "NotoSansSC",
        filename: "NotoSansSC.ttf",
        repositoryPath: "ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf",
        sha256: "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da"
    )
}

private struct FontPackageMetadata: Codable {
    let family: String
    let postScriptName: String
    let source: String
    let revision: String
    let sha256: String
    let license: String
    let licenseURL: String
    let requestedCharacters: String
}
