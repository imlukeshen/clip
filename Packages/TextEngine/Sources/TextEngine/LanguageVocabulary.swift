import CoreModel

/// The reserved words and common built-ins of each language clipx edits.
///
/// Tree-sitter grammars name most keyword tokens by their spelling, so the
/// same list colours a keyword and offers it as a completion. Each grammar
/// spells a few things its own way, which is why one shared C-family list
/// left `fn`, `elif`, `fi`, and friends uncoloured.
public enum LanguageVocabulary {
    /// Reserved words for `language`, spelled as written in source.
    public static func keywords(for language: LanguageID) -> [String] {
        switch language {
        case .python: python
        case .javascript: javascript
        case .typescript: javascript + typescript
        case .swift: swift
        case .go: go
        case .rust: rust
        case .c: c
        case .cpp: c + cpp
        case .java: java
        case .bash: bash
        case .sql: sql
        default: []
        }
    }

    /// Built-in functions, types, and names worth completing for `language`.
    public static func builtins(for language: LanguageID) -> [String] {
        switch language {
        case .python: pythonBuiltins
        case .javascript, .typescript: javascriptBuiltins
        case .swift: swiftBuiltins
        case .go: goBuiltins
        case .rust: rustBuiltins
        case .c: cBuiltins
        case .cpp: cBuiltins + cppBuiltins
        case .java: javaBuiltins
        case .bash: bashBuiltins
        case .sql: sqlBuiltins
        default: []
        }
    }

    /// Lowercased keyword spellings, for matching grammar node types.
    static func keywordNodeTypes(for language: LanguageID) -> Set<String> {
        Set(keywords(for: language).map { $0.lowercased() })
    }

    private static let python = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case",
        "class", "continue", "def", "del", "elif", "else", "except", "finally", "for",
        "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not",
        "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ]

    private static let javascript = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
        "from", "function", "get", "if", "import", "in", "instanceof", "let", "new", "null",
        "of", "return", "set", "static", "super", "switch", "this", "throw", "true", "try",
        "typeof", "undefined", "var", "void", "while", "with", "yield",
    ]

    private static let typescript = [
        "abstract", "any", "as", "asserts", "declare", "enum", "implements", "infer",
        "interface", "is", "keyof", "namespace", "never", "override", "private", "protected",
        "public", "readonly", "satisfies", "type", "unknown",
    ]

    private static let swift = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if", "import",
        "in", "init", "inout", "internal", "is", "let", "mutating", "nil", "nonisolated",
        "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while",
    ]

    private static let go = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface",
        "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch",
        "true", "type", "var",
    ]

    private static let rust = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
        "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
        "trait", "true", "type", "unsafe", "use", "where", "while",
    ]

    private static let c = [
        "#define", "#elif", "#else", "#endif", "#if", "#ifdef", "#ifndef", "#include",
        "#pragma", "#undef", "auto", "break", "case", "const", "continue", "default", "do",
        "else", "enum", "extern", "for", "goto", "if", "inline", "long", "NULL", "register",
        "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch",
        "typedef", "union", "unsigned", "volatile", "while",
    ]

    private static let cpp = [
        "catch", "class", "co_await", "co_return", "co_yield", "concept", "constexpr",
        "decltype", "delete", "explicit", "false", "final", "friend", "mutable", "namespace",
        "new", "noexcept", "nullptr", "operator", "override", "private", "protected",
        "public", "requires", "static_assert", "template", "this", "throw", "true", "try",
        "typename", "using", "virtual",
    ]

    private static let java = [
        "abstract", "assert", "break", "case", "catch", "class", "const", "continue",
        "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "if",
        "implements", "import", "instanceof", "interface", "native", "new", "null",
        "package", "permits", "private", "protected", "public", "record", "return", "sealed",
        "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
        "transient", "true", "try", "var", "volatile", "while", "yield",
    ]

    private static let bash = [
        "case", "declare", "do", "done", "elif", "else", "esac", "export", "fi", "for",
        "function", "if", "in", "local", "readonly", "return", "select", "then", "unset",
        "until", "while",
    ]

    private static let sql = [
        "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DESC",
        "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FROM", "GROUP", "HAVING", "IN",
        "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT",
        "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES",
        "RIGHT", "SELECT", "SET", "TABLE", "THEN", "UNION", "UNIQUE", "UPDATE", "VALUES",
        "VIEW", "WHEN", "WHERE", "WITH",
    ]

    private static let pythonBuiltins = [
        "abs", "all", "any", "bool", "bytes", "callable", "chr", "dict", "dir", "divmod",
        "enumerate", "filter", "float", "format", "frozenset", "getattr", "hasattr", "hash",
        "help", "hex", "input", "int", "isinstance", "issubclass", "iter", "len", "list",
        "map", "max", "min", "next", "object", "open", "ord", "pow", "print", "range",
        "repr", "reversed", "round", "set", "setattr", "slice", "sorted", "str", "sum",
        "super", "tuple", "type", "vars", "zip", "Exception", "ValueError", "TypeError",
        "KeyError", "IndexError", "RuntimeError", "StopIteration", "NotImplementedError",
        "self", "cls", "__init__", "__name__", "__main__",
    ]

    private static let javascriptBuiltins = [
        "Array", "Boolean", "Date", "Error", "JSON", "Map", "Math", "Number", "Object",
        "Promise", "RegExp", "Set", "String", "Symbol", "console", "document", "fetch",
        "globalThis", "parseFloat", "parseInt", "process", "require", "setInterval",
        "setTimeout", "window", "log", "length", "push", "forEach", "filter", "reduce",
        "string", "number", "boolean",
    ]

    private static let swiftBuiltins = [
        "Array", "Bool", "Character", "Dictionary", "Double", "Error", "Float", "Int",
        "Optional", "Result", "Set", "String", "Task", "UInt", "Void", "assert", "count",
        "fatalError", "filter", "forEach", "isEmpty", "map", "max", "min", "print",
        "reduce", "sorted",
    ]

    private static let goBuiltins = [
        "append", "bool", "byte", "cap", "close", "complex", "copy", "delete", "error",
        "float64", "fmt", "int", "int64", "len", "make", "new", "panic", "print", "println",
        "recover", "rune", "string", "uint", "Println", "Printf", "Sprintf", "Errorf",
    ]

    private static let rustBuiltins = [
        "Box", "Err", "HashMap", "None", "Ok", "Option", "Result", "Some", "String", "Vec",
        "bool", "char", "f64", "i32", "i64", "println", "format", "panic", "u8", "u32",
        "u64", "usize", "vec", "unwrap", "clone", "iter", "collect", "len", "push",
    ]

    private static let cBuiltins = [
        "char", "double", "float", "int", "void", "size_t", "printf", "scanf", "malloc",
        "free", "calloc", "realloc", "strlen", "strcpy", "strcmp", "memcpy", "memset",
        "fopen", "fclose", "fprintf", "stdin", "stdout", "stderr", "main", "bool",
    ]

    private static let cppBuiltins = [
        "std", "string", "vector", "map", "unordered_map", "set", "cout", "cin", "endl",
        "unique_ptr", "shared_ptr", "make_unique", "make_shared", "size", "push_back",
        "begin", "end", "auto",
    ]

    private static let javaBuiltins = [
        "boolean", "byte", "char", "double", "float", "int", "long", "short", "void",
        "String", "System", "Integer", "List", "ArrayList", "Map", "HashMap", "Object",
        "Exception", "Override", "main", "println", "out", "length", "size",
    ]

    private static let bashBuiltins = [
        "echo", "printf", "read", "cd", "pwd", "exit", "test", "source", "shift", "set",
        "trap", "eval", "exec", "true", "false", "grep", "sed", "awk", "ls", "cat",
    ]

    private static let sqlBuiltins = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "INTEGER", "TEXT", "REAL", "BLOB",
        "VARCHAR", "BOOLEAN", "DATE", "PRIMARY KEY", "FOREIGN KEY", "AUTOINCREMENT",
    ]
}
