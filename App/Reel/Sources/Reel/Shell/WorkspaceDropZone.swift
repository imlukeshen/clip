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
            model.acceptDrop(urls)
            return !urls.isEmpty
        } isTargeted: {
            isTargeted = $0
        }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.movie, .image, .audio, .pdf],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.acceptPicker(urls)
            }
        }
    }

    private var title: String {
        switch workspace {
        case .inbox: "Drop recordings or screenshots"
        case .video: "Drop clips to start a project"
        case .photo: "Drop images to edit"
        case .pdf: "Drop PDFs"
        case .convert: "Drop anything to convert"
        }
    }

    private var detail: String {
        switch workspace {
        case .inbox: "MOV, MP4, PNG, JPEG, HEIC"
        case .video: "MOV, MP4, M4V, WebM, MKV"
        case .photo: "PNG, JPEG, HEIC, TIFF, WebP"
        case .pdf: "Held in the library until PDF editing lands"
        case .convert: "Video, images, audio"
        }
    }
}
