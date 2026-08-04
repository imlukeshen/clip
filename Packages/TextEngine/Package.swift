// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TextEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TextEngine", targets: ["TextEngine"])
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(
            url: "https://github.com/swiftlang/swift-markdown",
            exact: "0.8.0"
        ),
        .package(
            url: "https://github.com/tree-sitter/swift-tree-sitter",
            exact: "0.25.0"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-bash",
            revision: "a06c2e4415e9bc0346c6b86d401879ffb44058f7"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-c",
            revision: "b780e47fc780ddc8da13afa35a3f4ed5c157823d"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-cpp",
            revision: "8b5b49eb196bec7040441bee33b2c9a4838d6967"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-css",
            revision: "6e4e7885292b8dad18cccd845f838984181b264e"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-go",
            revision: "2346a3ab1bb3857b48b29d779a1ef9799a248cd7"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-html",
            revision: "73a3947324f6efddf9e17c0ea58d454843590cc0"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-java",
            revision: "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-javascript",
            revision: "a48cee89ea5a4866d8516ab344c1f4b35acf999f"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-json",
            revision: "001c28d7a29832b06b0e831ec77845553c89b56d"
        ),
        .package(
            url: "https://github.com/latex-lsp/tree-sitter-latex",
            revision: "aca6eeba1b9556685bf0aa1cdc4a902cba155823"
        ),
        .package(
            url: "https://github.com/MDeiml/tree-sitter-markdown",
            revision: "a0a00f817d02412bd92c54d316f164d827b57b5c"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-python",
            revision: "53639fbf35319f69a8ff63c48d9cc94aeee09816"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-rust",
            revision: "77a3747266f4d621d0757825e6b11edcbf991ca5"
        ),
        .package(
            url: "https://github.com/DerekStride/tree-sitter-sql",
            revision: "851e9cb257ba7c66cc8c14214a31c44d2f1e954e"
        ),
        .package(
            url: "https://github.com/alex-pinkus/tree-sitter-swift",
            revision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5"
        ),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-toml",
            revision: "64b56832c2cffe41758f28e05c756a3a98d16f41"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-typescript",
            revision: "75b3874edb2dc714fb1fd77a32013d0f8699989f"
        ),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-xml",
            revision: "5000ae8f22d11fbe93939b05c1e37cf21117162d"
        ),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml",
            revision: "ccfaef1c88e3ea9cbb9ca3e986873c596919d016"
        ),
    ],
    targets: [
        .target(
            name: "TextEngine",
            dependencies: [
                "CoreModel",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterLatex", package: "tree-sitter-latex"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterSql", package: "tree-sitter-sql"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterXML", package: "tree-sitter-xml"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "TextEngineTests", dependencies: ["TextEngine", "CoreModel"]),
    ],
    swiftLanguageModes: [.v6]
)
