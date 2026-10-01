import Foundation

/// The bundled Mermaid renderer, used offline by the editor and in exported HTML.
public enum MermaidAssets {
    /// The minified Mermaid library, or an empty string if the resource is missing.
    public static let javaScript: String = {
        guard
            let url = Bundle.module.url(
                forResource: "mermaid.min",
                withExtension: "js",
                subdirectory: "Resources/Mermaid"
            ), let value = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return value
    }()
}
