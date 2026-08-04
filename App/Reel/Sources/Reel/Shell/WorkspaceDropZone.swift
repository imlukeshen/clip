import DesignSystem
import ReelAppCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceDropZone: View {
    @Bindable var model: AppModel
    let workspace: Workspace

    @State private var isTargeted = false
    @State private var isPicking = false

    var body: some View {
        DropZone(
            title: title,
            detail: detail,
            state: isTargeted ? .dragTargeted : .idle,
            chooseFiles: { isPicking = true }
        )
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls, source: .drop)
            return !urls.isEmpty
        } isTargeted: {
            isTargeted = $0
        }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                accept(urls, source: .picker)
            }
        }
    }

    private var title: String {
        switch workspace {
        case .inbox: "Drop files"
        case .video: "Drop clips"
        case .photo: "Drop images"
        case .pdf: "Drop PDFs"
        case .text: "Drop text files"
        case .convert: "Drop files"
        }
    }

    private var detail: String {
        switch workspace {
        case .inbox: "MOV, MP4, PNG, JPEG, HEIC"
        case .video: "MOV, MP4, M4V, WebM, MKV"
        case .photo: "PNG, JPEG, HEIC, TIFF, WebP"
        case .pdf: "PDF"
        case .text: "Markdown, LaTeX, code, plain text"
        case .convert: "Video, images, audio"
        }
    }

    private var allowedContentTypes: [UTType] {
        switch workspace {
        case .text: [.text, .sourceCode, .plainText]
        default: [.movie, .image, .audio, .pdf]
        }
    }

    private func accept(_ urls: [URL], source: IngestSource) {
        if workspace == .convert {
            model.enqueueForConversion(urls, source: source)
        } else {
            model.accept(urls, source: source)
        }
    }
}
