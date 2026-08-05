import Foundation
@preconcurrency import NaturalLanguage

public struct TextEmbedding: Sendable, Equatable {
    public var vector: [Float]
    public var model: String

    public init(vector: [Float], model: String) {
        self.vector = vector
        self.model = model
    }
}

public protocol TextEmbeddingProviding: Sendable {
    func embedding(for text: String) async throws -> TextEmbedding
    func currentModelIdentifiers() async -> Set<String>
}

public enum TextEmbeddingError: Error, Sendable, Equatable {
    case noSuitableModel
    case assetsUnavailable(String)
    case emptyResult
}

/// On-device contextual embeddings built into macOS. No text leaves the process.
public actor NaturalLanguageEmbeddingProvider: TextEmbeddingProviding {
    private var loadedModels: [String: NLContextualEmbedding] = [:]

    public init() {}

    public func embedding(for text: String) async throws -> TextEmbedding {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TextEmbeddingError.emptyResult }
        let language = NLLanguageRecognizer.dominantLanguage(for: value) ?? .english
        guard
            let model = NLContextualEmbedding(language: language)
                ?? NLContextualEmbedding(language: .english)
        else { throw TextEmbeddingError.noSuitableModel }
        let identifier = Self.identifier(for: model)
        guard model.hasAvailableAssets else {
            throw TextEmbeddingError.assetsUnavailable(identifier)
        }
        if loadedModels[identifier] == nil {
            try model.load()
            loadedModels[identifier] = model
        }
        let appliedLanguage: NLLanguage? = model.languages.contains(language) ? language : nil
        let result = try model.embeddingResult(for: value, language: appliedLanguage)
        var sum = [Double](repeating: 0, count: model.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) {
            vector, range in
            let token = result.string[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return true }
            for index in sum.indices { sum[index] += vector[index] }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0 else { throw TextEmbeddingError.emptyResult }
        let magnitude = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { throw TextEmbeddingError.emptyResult }
        return TextEmbedding(
            vector: sum.map { Float($0 / magnitude) },
            model: identifier
        )
    }

    public func currentModelIdentifiers() -> Set<String> {
        let probeLanguages: [NLLanguage] = [
            .english, .simplifiedChinese, .arabic, .russian, .hindi, .thai,
        ]
        return Set(
            probeLanguages.compactMap(NLContextualEmbedding.init(language:)).map(Self.identifier))
    }

    private nonisolated static func identifier(for model: NLContextualEmbedding) -> String {
        "apple-natural-language/\(model.modelIdentifier)/r\(model.revision)"
    }
}
