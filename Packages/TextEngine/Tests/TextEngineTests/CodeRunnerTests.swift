import CoreModel
import Foundation
import Testing

@testable import TextEngine

@Test func runRequestNamesAFileWithTheLanguageExtension() {
    #expect(
        CodeRunRequest(language: .python, source: "", fileName: "/Users/me/solver.py").fileName
            == "solver.py")
    #expect(
        CodeRunRequest(language: .python, source: "", fileName: "Untitled.txt").fileName
            == "Untitled.py")
    #expect(CodeRunRequest(language: .rust, source: "", fileName: "").fileName == "main.rs")
}

@Test func markupAndDataFormatsHaveNoToolchain() {
    for language: LanguageID in [.html, .css, .json, .yaml, .toml, .xml, .markdown, .latex] {
        #expect(CodeToolchain.toolchain(for: language) == nil, "\(language.rawValue)")
    }
    #expect(CodeToolchain.runnableLanguages.count == 11)
}

@Test func errorLocatorReadsEachToolchainsFormat() {
    let cases: [(LanguageID, String, String, Int)] = [
        (
            .python, "solver.py",
            "  File \"solver.py\", line 3, in <module>\n  File \"solver.py\", line 7, in f\n  File \"/usr/lib/json.py\", line 9",
            7
        ),
        (.c, "main.c", "main.c:12:5: error: use of undeclared identifier 'x'", 12),
        (.rust, "main.rs", "error[E0425]: cannot find value `x`\n --> main.rs:4:13", 4),
        (.go, "main.go", "# command-line-arguments\n./main.go:6:2: undefined: x", 6),
        (.javascript, "app.js", "    at Object.<anonymous> (/tmp/app.js:2:7)", 2),
        (.bash, "run.sh", "run.sh: line 5: nope: command not found", 5),
        (.swift, "main.swift", "main.swift:3:1: error: cannot find 'x' in scope", 3),
    ]
    for (language, file, output, line) in cases {
        #expect(
            RunErrorLocator.errorLine(in: output, fileName: file, language: language) == line,
            "\(language.rawValue)")
    }
    #expect(RunErrorLocator.errorLine(in: "all good", fileName: "main.c", language: .c) == nil)
}

@Test func chunkDecoderHoldsBackASplitCharacter() {
    var decoder = UTF8ChunkDecoder()
    let bytes = Data("héllo ✓".utf8)
    let split = bytes.count - 1  // Cut the three-byte check mark in two.
    let first = decoder.decode(bytes.prefix(split))
    let second = decoder.decode(bytes.suffix(from: split))
    #expect(first + second == "héllo ✓")
    #expect(!first.contains("\u{FFFD}"))
}

/// Runs `source` and collects the transcript, or `nil` when the toolchain is
/// not installed on this machine.
private func run(
    _ language: LanguageID,
    _ source: String,
    timeout: Duration = .seconds(60)
) async throws -> (output: String, errors: String, status: Int32, commands: [String])? {
    let runner = SystemCodeRunner()
    guard runner.canRun(language) else { return nil }
    var output = ""
    var errors = ""
    var status: Int32 = -1
    var commands: [String] = []
    let request = CodeRunRequest(
        language: language, source: source, fileName: "main", timeout: timeout)
    for try await event in runner.run(request) {
        switch event {
        case .started(let command): commands.append(command)
        case .output(let text, .standardOutput): output += text
        case .output(let text, .standardError): errors += text
        case .finished(let exit, _): status = exit
        }
    }
    return (output, errors, status, commands)
}

@Test func everyInstalledToolchainRunsHelloWorld() async throws {
    let programs: [(LanguageID, String)] = [
        (.python, "print('hi', 6 * 7)\n"),
        (.javascript, "console.log('hi', 6 * 7)\n"),
        (.typescript, "const n: number = 6 * 7\nconsole.log('hi', n)\n"),
        (.swift, "print(\"hi\", 6 * 7)\n"),
        (.go, "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"hi\", 6*7) }\n"),
        (.rust, "fn main() { println!(\"hi {}\", 6 * 7); }\n"),
        (.c, "#include <stdio.h>\nint main(void) { printf(\"hi %d\\n\", 6 * 7); return 0; }\n"),
        (.cpp, "#include <iostream>\nint main() { std::cout << \"hi \" << 6 * 7 << \"\\n\"; }\n"),
        (
            .java,
            "class Main { public static void main(String[] a) { System.out.println(\"hi \" + 6 * 7); } }\n"
        ),
        (.bash, "echo hi $((6 * 7))\n"),
        (.sql, "select 'hi' as greeting, 6 * 7 as answer;\n"),
    ]
    for (language, source) in programs {
        guard let result = try await run(language, source) else { continue }
        #expect(result.status == 0, "\(language.rawValue): \(result.errors)")
        #expect(result.output.contains("hi"), "\(language.rawValue): \(result.output)")
        #expect(result.output.contains("42"), "\(language.rawValue): \(result.output)")
        #expect(!result.commands.isEmpty)
        #expect(!result.commands.joined().contains("clipx-run"), "\(result.commands)")
    }
}

@Test func aFailedBuildStopsBeforeRunningAndNamesTheLine() async throws {
    guard let result = try await run(.c, "int main(void) {\n  return missing;\n}\n") else { return }
    #expect(result.status != 0)
    #expect(result.commands.count == 1)
    #expect(RunErrorLocator.errorLine(in: result.errors, fileName: "main.c", language: .c) == 2)
    #expect(!result.errors.contains("clipx-run"))
}

@Test func outputStreamsBeforeTheProgramEnds() async throws {
    let runner = SystemCodeRunner()
    guard runner.canRun(.python) else { return }
    let request = CodeRunRequest(
        language: .python,
        source: "import time\nprint('first')\ntime.sleep(1.5)\nprint('second')\n",
        fileName: "slow.py"
    )
    // Measure the gap between the two lines, not the time from launch: a
    // loaded CI machine can take over a second just to start Python. A
    // buffered run delivers both lines together at exit; a streamed one
    // delivers them about the 1.5-second sleep apart.
    var firstArrival: ContinuousClock.Instant?
    for try await event in runner.run(request) {
        guard case .output(let text, _) = event else { continue }
        if firstArrival == nil, text.contains("first") { firstArrival = .now }
        if text.contains("second") {
            let first = try #require(firstArrival, "The first line never arrived")
            #expect(ContinuousClock.now - first > .seconds(0.75))
            return
        }
    }
    Issue.record("The second line never arrived")
}

@Test func aRunThatTakesTooLongIsStopped() async throws {
    let runner = SystemCodeRunner()
    guard runner.canRun(.python) else { return }
    let request = CodeRunRequest(
        language: .python, source: "import time\ntime.sleep(30)\n", fileName: "slow.py",
        timeout: .milliseconds(300))
    await #expect(throws: TextEngineError.runTimedOut(.milliseconds(300))) {
        for try await _ in runner.run(request) {}
    }
}
