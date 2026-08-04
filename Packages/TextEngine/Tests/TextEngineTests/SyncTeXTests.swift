import Foundation
import Testing

@testable import TextEngine

private let syncTeXFixture = """
    SyncTeX Version:1
    Input:1:/private/tmp/ClipTeX/source/main.tex
    Output:pdf
    Magnification:1000
    Unit:1
    X Offset:0
    Y Offset:0
    Content:
    {1
    [1,6:8799519,44254495:22609920,36044800,0
    (1,4:8799519,8865055:22609920,454820,7208
    h1,3:8799519,8865055:983040,0,0
    )
    (1,6:8799519,9651487:22609920,462029,135003
    h1,5:8799519,9651487:983040,0,0
    )
    ]
    }1
    Postamble:
    Count:6
    """

@Test func syncTeXMapsForwardAndInverseWithoutGuessingAcrossMissingLines() throws {
    let index = try SyncTeXIndex(synctexText: syncTeXFixture)
    let location = try #require(index.forwardSearch(file: "main.tex", line: 3))

    #expect(location.page == 1)
    #expect(abs(location.x - 133.77) < 0.1)
    #expect(location.width > 14)
    #expect(location.height > 6)
    #expect(index.forwardSearch(file: "main.tex", line: 142) == nil)

    let source = try #require(
        index.inverseSearch(
            page: 1,
            x: location.x + 1,
            y: location.y + 1
        )
    )
    #expect(source.file.hasSuffix("main.tex"))
    #expect(source.line == 3)
    #expect(index.inverseSearch(page: 1, x: 500, y: 700) == nil)
}

@Test func gzipSyncTeXSidecarsAreDecodedWithABoundedNativeInflater() throws {
    let base64 =
        "H4sIAAAAAAAA/4yTy27bQAxF9/wKexcDakRyOM9tVlkUKdCmSBFk4ahyIth6wBoDCYr+ezGK5Uh1i3ali+Eh7x1K+vzaFF/Ku8XXct9XbRMIrpvuEAOF/LYv932+O2zLvl4Xj227zYtd1eWXse4+9K9NEcuXvF5XzWUsX45tHI5CjUJGoUdhAtwcYlLd9w18XD811aYq1nGwR0S4baoYCO4WN5tNX8aA8O1dXrVNLJsYYEnOwA+Ce8pMEKsMO5uJYUZtdWBjrCLNmZA4YecyhIsZaYdnwAwzhNXbGGe91+QnY9ig94yZoChtiTOckyYd+glonRHFo5v7G5ZMn/9JrODht2DCWmSKKYMiDhN9QZmcSOeMRj29gRaX8jG65KzOSO8UypvvU6oTidVKywjANs1XJOhFvbeRI6M9S2o6L8NqvghvNImzk1iGkX1GSiOqFEyfsX4WTAdiRKWtjABsk8PJ2R/byCg0SJyazsvDbmfR/vDSlRF73Ox/cUMQ8l7QqAlIRELEx/opyXl9NaR6gKVVDD/Hf9Gmj93Cp7aP6/pxVwa4ag9NDIphyTKcL/piX3XxUAf4BQAA//8DAP5sm2rSAwAA"
    let archive = try #require(Data(base64Encoded: base64))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "clip-synctex-test-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("main.synctex.gz")
    try archive.write(to: url)

    let index = try SyncTeXIndex(contentsOf: url)
    #expect(index.forwardSearch(file: "main.tex", line: 3) != nil)
    #expect(index.forwardSearch(file: "main.tex", line: 5) != nil)
}

@Test func forwardSearchDoesNotConfuseDuplicateFilenamesInNestedFolders() throws {
    let source = """
        SyncTeX Version:1
        Input:1:/private/tmp/clip-tex-test/source/main.tex
        Input:2:/private/tmp/clip-tex-test/source/chapters/main.tex
        Content:
        {1
        h1,7:100000,100000:100000,100000,0
        h2,7:900000,900000:100000,100000,0
        }1
        """
    let index = try SyncTeXIndex(synctexText: source)

    let root = try #require(index.forwardSearch(file: "main.tex", line: 7))
    let nested = try #require(index.forwardSearch(file: "chapters/main.tex", line: 7))

    #expect(root.x < nested.x)
}

@Test func texLogsPreserveErrorsWarningsBoxesAndUnknownOutput() {
    let log = """
        (./chapters/body.tex
        ! LaTeX Error: File `missing.sty' not found.
        l.42 \\usepackage{missing}
        Package hyperref Warning: Token not allowed on input line 18.
        Overfull \\hbox (12.0pt too wide) in paragraph at lines 50--52
        an unparsed engine line that remains in the raw log
        error: appendix.tex:9: Undefined control sequence
        """

    let diagnostics = TeXLogParser.diagnostics(in: log)
    #expect(diagnostics.count == 4)
    #expect(
        diagnostics.contains {
            $0.severity == .error && $0.file == "./chapters/body.tex" && $0.line == 42
        }
    )
    #expect(diagnostics.contains { $0.severity == .warning && $0.line == 18 })
    #expect(diagnostics.contains { $0.severity == .warning && $0.line == 50 })
    #expect(
        diagnostics.contains {
            $0.severity == .error && $0.file == "appendix.tex" && $0.line == 9
        }
    )
}
