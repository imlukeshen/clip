import Foundation

public enum Workspace: String, Sendable, CaseIterable, Identifiable {
    case inbox
    case video
    case photo
    case pdf
    case text
    case convert

    public var id: Self { self }

    public var hasDropZone: Bool { true }

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .video: "Video"
        case .photo: "Photo"
        case .pdf: "PDF"
        case .text: "Text"
        case .convert: "Convert"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .video: "play.rectangle"
        case .photo: "photo"
        case .pdf: "doc"
        case .text: "doc.text"
        case .convert: "arrow.left.arrow.right"
        }
    }
}
