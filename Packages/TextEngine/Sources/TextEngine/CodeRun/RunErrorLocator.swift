import CoreModel
import Foundation

/// Finds the line of the user's own file that a compiler error or runtime
/// traceback blames.
public enum RunErrorLocator {
    /// The blamed line in `fileName`, if the error output names one.
    ///
    /// Compilers report the first error first, so the first mention wins.
    /// Python tracebacks list frames outermost first, so there the last
    /// mention is the line that raised. Frames in library code are skipped
    /// because the user cannot edit them.
    public static func errorLine(
        in errorOutput: String,
        fileName: String,
        language: LanguageID
    ) -> Int? {
        let name = NSRegularExpression.escapedPattern(for: fileName)
        let pattern =
            language == .python
            ? #"File "(?:[^"]*/)?"# + name + #"", line (\d+)"#
                // clang, swiftc, rustc, go, javac, node: `main.c:12:5`, `main.go:12`.
                // bash: `main.sh: line 12:`.
            : #"(?:^|[\s(/])"# + name + #"(?::(\d+)|: line (\d+))"#
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines]
            )
        else { return nil }
        let text = errorOutput as NSString
        let matches = expression.matches(
            in: errorOutput,
            range: NSRange(location: 0, length: text.length)
        )
        let match = language == .python ? matches.last : matches.first
        guard let match else { return nil }
        for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
            return Int(text.substring(with: match.range(at: group)))
        }
        return nil
    }
}
