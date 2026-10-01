# TextEngine

`TextEngine` owns the text editor's model work: file loading and encodings,
language detection, Tree-sitter highlighting with pinned grammars (ADR-0010),
the Markdown block document and offline HTML rendering (ADR-0011), and LaTeX
compilation through bundled Tectonic (ADR-0012). It depends on CoreModel,
swift-markdown, and the Tree-sitter packages; never on UI or the library.
Bundled web assets (KaTeX) live in `Sources/TextEngine/Resources`.
