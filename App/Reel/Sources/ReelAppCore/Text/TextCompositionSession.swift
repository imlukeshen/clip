import Foundation

/// Reconciles a native input-method composition with model changes that arrive
/// while AppKit owns marked text.
///
/// A composition is deliberately kept outside the persisted document until it
/// commits. If the document changes in the meantime, independent contiguous
/// edits are combined. A true overlap resolves to the newer model value so an
/// autosave, file reload, or collaboration update can never be overwritten by
/// a stale composition buffer.
public struct TextCompositionSession: Sendable, Equatable {
    /// The last editor/model value known to be synchronized before composition.
    public let baseline: String

    /// The newest non-baseline model value observed during composition.
    public private(set) var latestExternalText: String?

    public init(baseline: String) {
        self.baseline = baseline
    }

    /// Retains the latest meaningful model change. Repeated SwiftUI updates
    /// commonly carry the baseline while marked text is intentionally local;
    /// those are not external edits and must not erase a newer value.
    public mutating func observeExternalText(_ text: String) {
        guard text != baseline else { return }
        latestExternalText = text
    }

    /// Produces the value to publish once AppKit commits marked text.
    public func resolve(committedLocalText localText: String) -> String {
        guard let externalText = latestExternalText else { return localText }
        guard externalText != localText else { return localText }
        guard let localEdit = ContiguousEdit(from: baseline, to: localText) else {
            return externalText
        }
        guard let externalEdit = ContiguousEdit(from: baseline, to: externalText) else {
            return localText
        }

        let adjustedLocation: Int
        if externalEdit.upperBound <= localEdit.lowerBound {
            adjustedLocation = localEdit.lowerBound + externalEdit.delta
        } else if localEdit.upperBound <= externalEdit.lowerBound {
            adjustedLocation = localEdit.lowerBound
        } else {
            // Both edits replace some of the same baseline text. There is no
            // lossless automatic merge, so retain the newer model value.
            return externalText
        }

        return localEdit.applying(to: externalText, at: adjustedLocation) ?? externalText
    }
}

private struct ContiguousEdit: Sendable, Equatable {
    let lowerBound: Int
    let upperBound: Int
    let replacement: [UInt16]

    var delta: Int { replacement.count - (upperBound - lowerBound) }

    init?(from baseline: String, to updated: String) {
        guard baseline != updated else { return nil }
        let original = Array(baseline.utf16)
        let replacementSource = Array(updated.utf16)
        let sharedLimit = min(original.count, replacementSource.count)

        var prefix = 0
        while prefix < sharedLimit, original[prefix] == replacementSource[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < original.count - prefix,
            suffix < replacementSource.count - prefix,
            original[original.count - suffix - 1]
                == replacementSource[replacementSource.count - suffix - 1]
        {
            suffix += 1
        }

        lowerBound = prefix
        upperBound = original.count - suffix
        replacement = Array(replacementSource[prefix..<(replacementSource.count - suffix)])
    }

    func applying(to text: String, at location: Int) -> String? {
        var codeUnits = Array(text.utf16)
        let length = upperBound - lowerBound
        guard location >= 0, length >= 0, location + length <= codeUnits.count else {
            return nil
        }
        codeUnits.replaceSubrange(location..<(location + length), with: replacement)
        return String(decoding: codeUnits, as: UTF16.self)
    }
}
