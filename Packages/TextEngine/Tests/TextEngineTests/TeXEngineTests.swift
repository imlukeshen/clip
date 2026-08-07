import Foundation
import Testing

@testable import TextEngine

@Test func bundledTectonicIsAnExecutableArm64Release() throws {
    let engine = TectonicEngine()

    #expect(engine.isAvailable)
    #expect(TectonicEngine.version == "0.16.9")
    let attributes = try FileManager.default.attributesOfItem(atPath: engine.executableURL.path)
    let permissions = attributes[.posixPermissions] as? NSNumber
    #expect((permissions?.intValue ?? 0) & 0o111 != 0)
}

@Test func tectonicRunsInAnUntrustedScopedWorkspace() async throws {
    let fixture = try TeXFixture(script: TeXFixture.successScript)
    defer { fixture.remove() }
    let observer = NetworkObserver()
    let engine = TectonicEngine(
        executableURL: fixture.executable,
        cacheDirectory: fixture.cache,
        networkAccessObserver: { await observer.record() }
    )
    let job = TeXJob(
        mainFile: fixture.mainFile,
        sourceOverrides: [
            "main.tex": Data("\\documentclass{article}\\begin{document}Clip\\end{document}".utf8)
        ],
        timeout: .seconds(2),
        packageAccess: .cachedOnly
    )

    let events = try await collect(engine.compile(job))
    let logs = events.compactMap { event -> String? in
        guard case .logLine(let line) = event else { return nil }
        return line
    }.joined(separator: "\n")
    guard case .finished(let pdf, let synctex) = events.last else {
        Issue.record("Tectonic did not produce a finished event")
        return
    }
    defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }

    #expect(try Data(contentsOf: pdf).starts(with: Data("%PDF".utf8)))
    #expect(synctex != nil)
    #expect(logs.contains("--untrusted"))
    #expect(logs.contains("--only-cached"))
    #expect(logs.contains("untrusted:1"))
    #expect(logs.contains("openin:p"))
    #expect(logs.contains("openout:p"))
    #expect(events.filter { if case .logLine = $0 { true } else { false } }.count == 1)
    #expect(!logs.contains(fixture.mainFile.deletingLastPathComponent().path))
    #expect(await observer.count == 0)
}

@Test func packageNetworkAccessIsExplicitAndObserved() async throws {
    let fixture = try TeXFixture(script: TeXFixture.successScript)
    defer { fixture.remove() }
    let observer = NetworkObserver()
    let engine = TectonicEngine(
        executableURL: fixture.executable,
        cacheDirectory: fixture.cache,
        networkAccessObserver: { await observer.record() }
    )
    let events = try await collect(
        engine.compile(
            TeXJob(
                mainFile: fixture.mainFile,
                timeout: .seconds(2),
                packageAccess: .allowNetwork
            )
        )
    )
    if case .finished(let pdf, _) = events.last {
        try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent())
    }
    let logs = events.compactMap { event -> String? in
        guard case .logLine(let line) = event else { return nil }
        return line
    }.joined(separator: "\n")

    #expect(await observer.count == 1)
    #expect(!logs.contains("--only-cached"))
}

@Test func allowedNetworkBuildUsesWarmCacheWithoutNetworkAccess() async throws {
    let fixture = try TeXFixture(script: TeXFixture.successScript)
    defer { fixture.remove() }
    let observer = NetworkObserver()
    let engine = TectonicEngine(
        executableURL: fixture.executable,
        cacheDirectory: fixture.cache,
        networkAccessObserver: { await observer.record() }
    )

    let firstEvents = try await collect(
        engine.compile(
            TeXJob(
                mainFile: fixture.mainFile,
                timeout: .seconds(2),
                packageAccess: .allowNetwork
            )
        )
    )
    if case .finished(let pdf, _) = firstEvents.last {
        try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent())
    }
    #expect(await observer.count == 1)

    let events = try await collect(
        engine.compile(
            TeXJob(
                mainFile: fixture.mainFile,
                timeout: .seconds(2),
                packageAccess: .allowNetwork
            )
        )
    )
    if case .finished(let pdf, _) = events.last {
        try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent())
    }
    let log = events.compactMap { event -> String? in
        guard case .logLine(let value) = event else { return nil }
        return value
    }.joined(separator: "\n")

    #expect(log.contains("--only-cached"))
    #expect(await observer.count == 1)
}

@Test func warmCacheMissRetriesWithObservedNetworkAccess() async throws {
    let fixture = try TeXFixture(script: TeXFixture.cacheMissThenSuccessScript)
    defer { fixture.remove() }
    let observer = NetworkObserver()
    let engine = TectonicEngine(
        executableURL: fixture.executable,
        cacheDirectory: fixture.cache,
        networkAccessObserver: { await observer.record() }
    )
    let job = TeXJob(
        mainFile: fixture.mainFile,
        timeout: .seconds(2),
        packageAccess: .allowNetwork
    )

    for _ in 0..<2 {
        let events = try await collect(engine.compile(job))
        if case .finished(let pdf, _) = events.last {
            try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent())
        }
    }

    #expect(await observer.count == 2)
}

@Test func cachedSyntaxFailureDoesNotRetryOverTheNetwork() {
    #expect(
        !TectonicEngine.requiresNetworkRetry(
            "using only cached resource files\nerror: undefined control sequence"
        )
    )
    #expect(
        TectonicEngine.requiresNetworkRetry(
            "using only cached resource files\nerror: required bundle file not found"
        )
    )
}

@Test func bundledTectonicExplainsThatBiberNeedsTheDirectBuild() async throws {
    let fixture = try TeXFixture(script: TeXFixture.successScript)
    defer { fixture.remove() }
    let engine = TectonicEngine(executableURL: fixture.executable, cacheDirectory: fixture.cache)

    do {
        _ = try await collect(
            engine.compile(TeXJob(mainFile: fixture.mainFile, bibliography: .biber))
        )
        Issue.record("Bundled Tectonic should not claim to include Biber")
    } catch {
        #expect(error as? TeXEngineError == .bibliographyToolUnavailable("Biber"))
    }
}

@Test func biberProjectsRouteToAnAvailableSystemEngine() async throws {
    let primary = RecordingTeXEngine(id: .tectonic, isAvailable: true)
    let system = RecordingTeXEngine(id: .systemTeX, isAvailable: true)
    let router = BibliographyRoutingTeXEngine(primary: primary, biberEngine: system)
    let fixture = try TeXFixture(script: TeXFixture.successScript)
    defer { fixture.remove() }

    _ = try await collect(
        router.compile(TeXJob(mainFile: fixture.mainFile, bibliography: .biber))
    )

    #expect(await primary.compiles == 0)
    #expect(await system.compiles == 1)
}

@Test func shellEscapeIsRefusedBeforeTheEngineStarts() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-tex-marker-\(UUID().uuidString)"
    )
    let script = """
        #!/bin/sh
        : > "\(marker.path)"
        exit 0
        """
    let fixture = try TeXFixture(
        script: script,
        source: "\\documentclass{article}\n\\write18{touch /tmp/unsafe}\n"
    )
    defer {
        fixture.remove()
        try? FileManager.default.removeItem(at: marker)
    }
    let engine = TectonicEngine(executableURL: fixture.executable, cacheDirectory: fixture.cache)

    do {
        _ = try await collect(engine.compile(TeXJob(mainFile: fixture.mainFile)))
        Issue.record("Shell escape should have been refused")
    } catch {
        #expect(error as? TeXEngineError == .unsafeSource("shell escape is disabled"))
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func anInfiniteCompileIsHardKilledAtTheDeadline() async throws {
    let fixture = try TeXFixture(
        script: """
            #!/bin/sh
            while :; do :; done
            """
    )
    defer { fixture.remove() }
    let engine = TectonicEngine(executableURL: fixture.executable, cacheDirectory: fixture.cache)
    let clock = ContinuousClock()
    let started = clock.now

    do {
        _ = try await collect(
            engine.compile(
                TeXJob(mainFile: fixture.mainFile, timeout: .milliseconds(80))
            )
        )
        Issue.record("An infinite compile should time out")
    } catch {
        #expect(error as? TeXEngineError == .timedOut)
    }
    #expect(started.duration(to: clock.now) < .seconds(2))
}

@Test func oversizedPDFsAreNeverCopiedOutOfTheSandbox() async throws {
    let fixture = try TeXFixture(script: TeXFixture.successScript)
    defer { fixture.remove() }
    let engine = TectonicEngine(executableURL: fixture.executable, cacheDirectory: fixture.cache)

    do {
        _ = try await collect(
            engine.compile(
                TeXJob(mainFile: fixture.mainFile, timeout: .seconds(2), outputSizeLimit: 2)
            )
        )
        Issue.record("An oversized PDF should be refused")
    } catch {
        #expect(error as? TeXEngineError == .outputTooLarge(limit: 2))
    }
}

@Test func oversizedBuildLogsAreStoppedBeforeTheyCanGrowWithoutBound() async throws {
    let fixture = try TeXFixture(
        script: """
            #!/bin/sh
            while :; do
                printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' >&2
            done
            """
    )
    defer { fixture.remove() }
    let engine = TectonicEngine(executableURL: fixture.executable, cacheDirectory: fixture.cache)
    let clock = ContinuousClock()
    let started = clock.now

    do {
        _ = try await collect(
            engine.compile(
                TeXJob(
                    mainFile: fixture.mainFile,
                    timeout: .seconds(2),
                    logSizeLimit: 1_024
                )
            )
        )
        Issue.record("An oversized build log should be refused")
    } catch {
        #expect(error as? TeXEngineError == .logTooLarge(limit: 1_024))
    }
    #expect(started.duration(to: clock.now) < .seconds(2))
}

private func collect(
    _ stream: AsyncThrowingStream<TeXEvent, Error>
) async throws -> [TeXEvent] {
    var events: [TeXEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private actor NetworkObserver {
    private(set) var count = 0

    func record() { count += 1 }
}

private final class RecordingTeXEngine: TeXEngine, @unchecked Sendable {
    let id: EngineID
    let displayName = "Recorder"
    let isAvailable: Bool
    private let state = RecordingTeXState()

    init(id: EngineID, isAvailable: Bool) {
        self.id = id
        self.isAvailable = isAvailable
    }

    var compiles: Int {
        get async { await state.compiles }
    }

    func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await state.record()
                continuation.finish()
            }
        }
    }
}

private actor RecordingTeXState {
    private(set) var compiles = 0

    func record() { compiles += 1 }
}

private struct TeXFixture {
    let root: URL
    let mainFile: URL
    let executable: URL
    let cache: URL

    init(script: String, source: String = "\\documentclass{article}\n") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-tex-test-\(UUID().uuidString)",
            isDirectory: true
        )
        mainFile = root.appendingPathComponent("main.tex")
        executable = root.appendingPathComponent("fake-tectonic")
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(source.utf8).write(to: mainFile)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static let successScript = """
        #!/bin/sh
        outdir=""
        input=""
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "--outdir" ]; then outdir="$argument"; fi
            previous="$argument"
            input="$argument"
        done
        name="${input##*/}"
        name="${name%.tex}"
        printf '%%PDF-1.4\n' > "$outdir/$name.pdf"
        printf 'SyncTeX Version:1\n' > "$outdir/$name.synctex.gz"
        printf 'args:%s\n' "$*" >&2
        printf 'untrusted:%s\n' "$TECTONIC_UNTRUSTED_MODE" >&2
        printf 'openin:%s\n' "$openin_any" >&2
        printf 'openout:%s\n' "$openout_any" >&2
        """

    static let cacheMissThenSuccessScript = """
        #!/bin/sh
        case " $* " in
            *" --only-cached "*)
                printf 'using only cached resource files\n' >&2
                printf "this bundle isn't cached\n" >&2
                exit 1
                ;;
        esac
        outdir=""
        input=""
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "--outdir" ]; then outdir="$argument"; fi
            previous="$argument"
            input="$argument"
        done
        name="${input##*/}"
        name="${name%.tex}"
        printf '%%PDF-1.4\n' > "$outdir/$name.pdf"
        printf 'SyncTeX Version:1\n' > "$outdir/$name.synctex.gz"
        printf 'args:%s\n' "$*" >&2
        """
}
