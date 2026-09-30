import CoreModel
import Foundation

/// How clipx runs one language with tools already installed on the Mac.
///
/// Interpreted languages run in one step. Compiled ones build into the run's
/// staging folder first, then run the result. Markup and data formats such as
/// HTML, JSON, and YAML are not programs and have no toolchain.
public struct CodeToolchain: Sendable {
    /// The language this toolchain runs.
    public let language: LanguageID
    /// The tool's name as users know it, such as "Python 3" or "Node.js".
    public let displayName: String
    /// Where to get the tool, shown when it is not installed.
    public let installHint: String
    let candidates: @Sendable () -> [String]
    let requiresDeveloperTools: Bool
    let plan: @Sendable (_ tool: URL, _ source: URL, _ buildFolder: URL) -> [CodeRunStep]

    /// Every language clipx can run, in menu order.
    public static let runnableLanguages: [LanguageID] = all.map(\.language)

    /// The toolchain for `language`, or `nil` for markup and data formats.
    public static func toolchain(for language: LanguageID) -> CodeToolchain? {
        all.first { $0.language == language }
    }

    /// The installed tool, or `nil` when none of the usual locations has it.
    func locate(fileManager: FileManager = .default) -> URL? {
        if requiresDeveloperTools, !Self.hasDeveloperTools(fileManager) { return nil }
        return candidates()
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `/usr/bin/swift`, `clang`, and friends are shims that open an install
    /// dialog when no developer tools are present, so check before trusting them.
    private static func hasDeveloperTools(_ fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin")
            || fileManager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer")
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static func installed(_ name: String) -> [String] {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    }

    private static func step(_ tool: URL, _ arguments: [String]) -> CodeRunStep {
        CodeRunStep(executableURL: tool, arguments: arguments)
    }

    private static func javaHomes() -> [String] {
        let root = "/Library/Java/JavaVirtualMachines"
        let versions: [String]
        do {
            versions = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            return []  // No JDK folder: Java is simply not installed there.
        }
        return versions.sorted(by: >).map { "\(root)/\($0)/Contents/Home/bin/java" }
    }

    static let all: [CodeToolchain] = [
        CodeToolchain(
            language: .python,
            displayName: "Python 3",
            installHint: "Install Python 3 from python.org or with Homebrew.",
            candidates: {
                installed("python3") + [
                    "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                    "/Library/Developer/CommandLineTools/usr/bin/python3",
                    "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
                ]
            },
            requiresDeveloperTools: false,
            plan: { tool, source, _ in [step(tool, ["-u", "-B", source.path])] }
        ),
        CodeToolchain(
            language: .javascript,
            displayName: "Node.js",
            installHint: "Install Node.js from nodejs.org or with Homebrew.",
            candidates: { installed("node") },
            requiresDeveloperTools: false,
            plan: { tool, source, _ in [step(tool, [source.path])] }
        ),
        CodeToolchain(
            language: .typescript,
            displayName: "Bun, Deno, or Node.js 22.6+",
            installHint: "Install Bun, Deno, or Node.js 22.6 or later with Homebrew.",
            candidates: {
                ["\(home)/.bun/bin/bun"] + installed("bun") + ["\(home)/.deno/bin/deno"]
                    + installed("deno") + installed("node")
            },
            requiresDeveloperTools: false,
            plan: { tool, source, _ in
                switch tool.lastPathComponent {
                case "bun": [step(tool, ["run", source.path])]
                case "deno": [step(tool, ["run", "--quiet", "--allow-all", source.path])]
                default:
                    [step(tool, ["--experimental-strip-types", "--no-warnings", source.path])]
                }
            }
        ),
        CodeToolchain(
            language: .swift,
            displayName: "Swift",
            installHint: "Install Xcode or the Command Line Tools (xcode-select --install).",
            candidates: { ["/usr/bin/swift"] },
            requiresDeveloperTools: true,
            plan: { tool, source, _ in [step(tool, [source.path])] }
        ),
        CodeToolchain(
            language: .go,
            displayName: "Go",
            installHint: "Install Go from go.dev or with Homebrew.",
            candidates: { installed("go") + ["/usr/local/go/bin/go"] },
            requiresDeveloperTools: false,
            plan: { tool, source, _ in [step(tool, ["run", source.path])] }
        ),
        CodeToolchain(
            language: .rust,
            displayName: "Rust",
            installHint: "Install Rust from rustup.rs or with Homebrew.",
            candidates: { ["\(home)/.cargo/bin/rustc"] + installed("rustc") },
            requiresDeveloperTools: false,
            plan: { tool, source, build in
                let binary = build.appendingPathComponent("main")
                return [
                    step(tool, ["--edition", "2021", "-o", binary.path, source.path]),
                    step(binary, []),
                ]
            }
        ),
        CodeToolchain(
            language: .c,
            displayName: "Clang",
            installHint: "Install Xcode or the Command Line Tools (xcode-select --install).",
            candidates: { ["/usr/bin/clang"] },
            requiresDeveloperTools: true,
            plan: { tool, source, build in
                let binary = build.appendingPathComponent("main")
                return [
                    step(tool, ["-std=c17", "-Wall", "-o", binary.path, source.path, "-lm"]),
                    step(binary, []),
                ]
            }
        ),
        CodeToolchain(
            language: .cpp,
            displayName: "Clang",
            installHint: "Install Xcode or the Command Line Tools (xcode-select --install).",
            candidates: { ["/usr/bin/clang++"] },
            requiresDeveloperTools: true,
            plan: { tool, source, build in
                let binary = build.appendingPathComponent("main")
                return [
                    step(tool, ["-std=c++20", "-Wall", "-o", binary.path, source.path]),
                    step(binary, []),
                ]
            }
        ),
        CodeToolchain(
            language: .java,
            displayName: "Java 11+",
            installHint: "Install a JDK, for example with Homebrew (brew install openjdk).",
            candidates: {
                [
                    "/opt/homebrew/opt/openjdk/bin/java",
                    "/usr/local/opt/openjdk/bin/java",
                ] + javaHomes()
            },
            requiresDeveloperTools: false,
            plan: { tool, source, _ in [step(tool, [source.path])] }
        ),
        CodeToolchain(
            language: .bash,
            displayName: "Bash",
            installHint: "Bash ships with macOS.",
            candidates: { installed("bash") + ["/bin/bash"] },
            requiresDeveloperTools: false,
            plan: { tool, source, _ in [step(tool, [source.path])] }
        ),
        CodeToolchain(
            language: .sql,
            displayName: "SQLite",
            installHint: "SQLite ships with macOS.",
            candidates: { installed("sqlite3") + ["/usr/bin/sqlite3"] },
            requiresDeveloperTools: false,
            plan: { tool, source, _ in
                [step(tool, ["-bail", "-header", "-column", ":memory:", ".read \(source.path)"])]
            }
        ),
    ]
}
