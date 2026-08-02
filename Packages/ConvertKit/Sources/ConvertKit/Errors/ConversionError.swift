import Foundation

public enum ConversionError: Error, Sendable, Equatable {
    case unsupported(String)
    case invalidInput
    case cannotCreateOutput
    case backendUnavailable(String)
    case conversionFailed(String)
    case cancelled
}

extension ConversionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason): reason
        case .invalidInput: "The input file is not valid for this conversion."
        case .cannotCreateOutput: "The output file could not be created."
        case .backendUnavailable(let reason): reason
        case .conversionFailed(let reason): reason
        case .cancelled: "The conversion was cancelled."
        }
    }
}
