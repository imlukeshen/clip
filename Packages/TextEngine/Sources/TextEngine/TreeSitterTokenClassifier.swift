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
        ":=", "..", "...",
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
