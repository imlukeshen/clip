import CoreModel

enum TreeSitterTokenClassifier {
    private static let keywords: Set<String> = [
        "abstract", "actor", "alias", "as", "async", "await", "break", "case",
        "catch", "class", "const", "continue", "default", "defer", "do", "else",
        "enum", "export", "extends", "extension", "false", "final", "finally", "for",
        "from", "func", "function", "guard", "if", "implements", "import", "in",
        "interface", "internal", "is", "let", "match", "mut", "namespace", "new",
        "nil", "null", "override", "package", "private", "protocol", "public", "repeat",
        "return", "sealed", "select", "self", "static", "struct", "super", "switch",
        "throw", "throws", "trait", "true", "try", "type", "typeof", "var", "virtual",
        "where", "while", "yield",
    ]

    private static let operators: Set<String> = [
        "+", "-", "*", "/", "%", "=", "==", "!=", "===", "!==", "<", ">", "<=",
        ">=", "=>", "->", "&&", "||", "!", "&", "|", "^", "~", "??", "?.", "::",
        ":=", "..", "...", "**", "//", "<<", ">>", "+=", "-=", "*=", "/=", "%=",
        "**=", "//=",
    ]

    /// Classifies a node, including each grammar's own keyword spellings.
    static func kind(for nodeType: String, language: LanguageID) -> SyntaxTokenKind? {
        let type = nodeType.lowercased()
        switch language {
        case .python:
            // Python's `type` node wraps an annotation such as `int`, so it is a
            // type there rather than the TypeScript `type` keyword. Python also
            // names whole expressions `binary_operator` and so on; only the
            // operator tokens inside them are operators.
            if type == "type" { return .type }
            if type == "decorator" { return .function }
            if type.hasSuffix("_operator") { return nil }
        case .sql:
            if type.hasPrefix("keyword_") { return .keyword }
        case .java:
            if javaTypes.contains(type) { return .type }
            if type == "null_literal" { return .keyword }
        case .rust:
            if type == "mutable_specifier" { return .keyword }
        case .css:
            // At-rules such as `@media` and `@import`.
            if type.count > 1, type.hasPrefix("@") { return .keyword }
        case .toml:
            if type == "bare_key" || type == "quoted_key" { return .property }
            if type == "boolean" { return .keyword }
        case .yaml:
            if type == "boolean_scalar" || type == "null_scalar" { return .keyword }
        case .xml:
            if type == "attvalue" || type == "systemliteral" || type == "pubidliteral" {
                return .string
            }
        default:
            break
        }
        if LanguageVocabulary.keywordNodeTypes(for: language).contains(type) { return .keyword }
        return kind(for: nodeType)
    }

    private static let javaTypes: Set<String> = [
        "integral_type", "floating_point_type", "boolean_type", "void_type",
    ]

    /// Classifies an identifier by the declaration or call that owns it, which
    /// the node type alone cannot say: `def area` and `class Shape` both name a
    /// plain `identifier`.
    /// Classifies a name by the declaration or call that owns it, which the
    /// node type alone cannot say: `def area` and `class Shape` both name a
    /// plain `identifier`.
    static func nameKind(parentType: String) -> SyntaxTokenKind? {
        if functionOwners.contains(parentType) { return .function }
        if typeOwners.contains(parentType) { return .type }
        return nil
    }

    /// The field of `parentType` that holds the name being declared or called.
    static func nameField(of parentType: String) -> String {
        callOwners.contains(parentType) ? "function" : "name"
    }

    private static let callOwners: Set<String> = ["call", "call_expression"]

    private static let functionOwners: Set<String> = callOwners.union([
        "function_definition", "function_declaration", "function_item", "method_declaration",
        "method_definition", "function_signature_item", "generator_function_declaration",
    ])

    private static let typeOwners: Set<String> = [
        "class_definition", "class_declaration", "struct_item", "enum_item", "trait_item",
        "interface_declaration", "enum_declaration", "record_declaration", "type_spec",
    ]

    /// Node types that hold a bare name, which only their parent can classify.
    static let nameNodeTypes: Set<String> = [
        "identifier", "field_identifier", "property_identifier", "type_identifier",
    ]

    static func kind(for nodeType: String) -> SyntaxTokenKind? {
        let type = nodeType.lowercased()
        if type.contains("comment") { return .comment }
        if type.contains("escape") { return .escape }
        if type.contains("string") || type.contains("character_literal")
            || type == "char_literal" || type.contains("template_literal")
        {
            return .string
        }
        if type.contains("number") || type.contains("integer") || type.contains("float")
            || type.contains("decimal")
        {
            return .number
        }
        if type.contains("heading") || type == "atx_h1_marker" || type == "atx_h2_marker" {
            return .heading
        }
        if type.contains("link") || type.contains("uri") || type == "url" {
            return .link
        }
        if type.contains("emphasis") || type == "strong_emphasis" { return .emphasis }
        if type.contains("type_identifier") || type == "primitive_type"
            || type == "predefined_type" || type == "builtin_type"
        {
            return .type
        }
        if type == "function_name" || type == "method_name" || type == "function_identifier" {
            return .function
        }
        if type == "property_identifier" || type == "property_name" || type == "field_identifier"
            || type == "attribute_name" || type == "pair_key"
        {
            return .property
        }
        if type == "tag_name" || type == "command_name" || type == "environment_name"
            || type == "doctype"
        {
            return .tag
        }
        if type.hasSuffix("_keyword") || keywords.contains(type) { return .keyword }
        if operators.contains(type) || type.hasSuffix("_operator") { return .operator }
        return nil
    }
}
