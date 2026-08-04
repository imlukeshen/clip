import Foundation

/// Capabilities that differ between Clip's direct and App Store channels.
/// The App Store value never permits external process edges, even if the same
/// machine has the corresponding application installed.
public struct ConversionCapabilities: Sendable, Equatable {
    public static let defaultLibreOfficeExecutable = URL(
        fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    )

    public var allowsExternalProcesses: Bool
    public var libreOfficeExecutable: URL

    public init(
        allowsExternalProcesses: Bool,
        libreOfficeExecutable: URL = Self.defaultLibreOfficeExecutable
    ) {
        self.allowsExternalProcesses = allowsExternalProcesses
        self.libreOfficeExecutable = libreOfficeExecutable.standardizedFileURL
    }

    public static let appStore = Self(allowsExternalProcesses: false)

    public static func direct(
        libreOfficeExecutable: URL = Self.defaultLibreOfficeExecutable
    ) -> Self {
        Self(
            allowsExternalProcesses: true,
            libreOfficeExecutable: libreOfficeExecutable
        )
    }

    public var isLibreOfficeAvailable: Bool {
        allowsExternalProcesses
            && FileManager.default.isExecutableFile(atPath: libreOfficeExecutable.path)
    }
}
