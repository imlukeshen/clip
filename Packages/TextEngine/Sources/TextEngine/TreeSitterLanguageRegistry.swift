import CoreModel
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterLatex
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSql
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTypeScript
import TreeSitterXML
import TreeSitterYAML

enum TreeSitterLanguageRegistry {
    static func language(for identifier: LanguageID) -> Language? {
        let pointer: OpaquePointer?
        if identifier == .markdown {
            pointer = tree_sitter_markdown()
        } else if identifier == .latex {
            pointer = tree_sitter_latex()
        } else if identifier == .swift {
            pointer = tree_sitter_swift()
        } else if identifier == .javascript {
            pointer = tree_sitter_javascript()
        } else if identifier == .typescript {
            pointer = tree_sitter_typescript()
        } else if identifier == .python {
            pointer = tree_sitter_python()
        } else if identifier == .json {
            pointer = tree_sitter_json()
        } else if identifier == .yaml {
            pointer = tree_sitter_yaml()
        } else if identifier == .toml {
            pointer = tree_sitter_toml()
        } else if identifier == .html {
            pointer = tree_sitter_html()
        } else if identifier == .css {
            pointer = tree_sitter_css()
        } else if identifier == .rust {
            pointer = tree_sitter_rust()
        } else if identifier == .go {
            pointer = tree_sitter_go()
        } else if identifier == .c {
            pointer = tree_sitter_c()
        } else if identifier == .cpp {
            pointer = tree_sitter_cpp()
        } else if identifier == .java {
            pointer = tree_sitter_java()
        } else if identifier == .sql {
            pointer = tree_sitter_sql()
        } else if identifier == .bash {
            pointer = tree_sitter_bash()
        } else if identifier == .xml {
            pointer = tree_sitter_xml()
        } else {
            pointer = nil
        }
        guard let pointer else { return nil }
        return Language(pointer)
    }
}
