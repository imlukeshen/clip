/// Routes projects that require the external Biber tool to a full System TeX
/// installation while retaining bundled Tectonic for every other document.
public struct BibliographyRoutingTeXEngine: TeXEngine {
    public let primary: any TeXEngine
    public let biberEngine: (any TeXEngine)?

    public init(primary: any TeXEngine, biberEngine: (any TeXEngine)? = nil) {
        self.primary = primary
        self.biberEngine = biberEngine
    }

    public var id: EngineID { primary.id }
    public var displayName: String { primary.displayName }
    public var isAvailable: Bool { primary.isAvailable }

    public func compile(_ job: TeXJob) -> AsyncThrowingStream<TeXEvent, Error> {
        if job.bibliography == .biber, let biberEngine, biberEngine.isAvailable {
            return biberEngine.compile(job)
        }
        return primary.compile(job)
    }
}
