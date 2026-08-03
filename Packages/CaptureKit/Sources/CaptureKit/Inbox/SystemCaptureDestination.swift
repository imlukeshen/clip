import Foundation

/// Resolves the directory used by the macOS screenshot and screen-recording tools.
public enum SystemCaptureDestination {
    public static func current(fileManager: FileManager = .default) -> URL {
        let configuredLocation = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location")
        let desktop =
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Desktop",
                isDirectory: true
            )
        return resolve(configuredLocation: configuredLocation, desktop: desktop)
    }

    static func resolve(configuredLocation: String?, desktop: URL) -> URL {
        guard let configuredLocation,
            !configuredLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return desktop.standardizedFileURL
        }
        if let fileURL = URL(string: configuredLocation), fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }
        return URL(
            fileURLWithPath: (configuredLocation as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }
}
