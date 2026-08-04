@preconcurrency import AppKit
import Foundation

/// Puts a history entry back on the system pasteboard so it pastes in any app.
public enum CapturePasteboard {
    /// Writes the entry's backing file at `url` onto the pasteboard in the form
    /// the entry's `kind` calls for.
    ///
    /// - A still writes both the file reference and the bitmap, so an editor or
    ///   Finder gets the file while a chat box or document gets the image.
    /// - A recording writes the file reference alone.
    /// - Text and a file set are stored as sidecars — a `.txt` of the text, a
    ///   `.filelist` of paths — so the backing file itself is never what the user
    ///   wants pasted; its contents are read back and written as a string or as
    ///   file references.
    ///
    /// Returns the pasteboard's `changeCount` after the write, so a watcher that
    /// polls the pasteboard can recognise this write as app-authored and skip
    /// re-ingesting it.
    @discardableResult
    public static func write(_ url: URL, kind: CaptureHistoryItem.Kind) -> Int {
        write(url, kind: kind, to: .general)
    }

    /// The write itself, against any pasteboard. Split out so tests can target a
    /// named pasteboard instead of the developer's live clipboard.
    @discardableResult
    static func write(_ url: URL, kind: CaptureHistoryItem.Kind, to pasteboard: NSPasteboard) -> Int
    {
        pasteboard.clearContents()
        var objects: [any NSPasteboardWriting] = []
        switch kind {
        case .image:
            objects.append(url as NSURL)
            if let image = NSImage(contentsOf: url) { objects.append(image) }
        case .video:
            objects.append(url as NSURL)
        case .text:
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                objects.append(text as NSString)
            }
        case .fileList:
            objects.append(contentsOf: fileURLs(fromListAt: url).map { $0 as NSURL })
        }
        pasteboard.writeObjects(objects)
        return pasteboard.changeCount
    }

    /// Reads the newline-separated paths a `.filelist` entry stores back into
    /// file URLs, dropping any whose file has since moved.
    private static func fileURLs(fromListAt url: URL) -> [URL] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return
            contents
            .split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
