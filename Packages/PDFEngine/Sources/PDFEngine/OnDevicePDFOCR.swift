import CoreGraphics
import Foundation
@preconcurrency import Vision

public struct OnDevicePDFOCR: Sendable {
    public init() {}

    public func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { observation -> (String, CGRect)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return (text, observation.boundingBox)
                }
                .sorted {
                    abs($0.1.midY - $1.1.midY) < 0.015
                        ? $0.1.minX < $1.1.minX : $0.1.maxY > $1.1.maxY
                }
                .map(\.0)
                .joined(separator: "\n")
        }.value
    }
}
