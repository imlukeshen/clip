import ReelAppCore
import SwiftUI

/// A reusable full-canvas overlay for moving, resizing, and rotating one image layer.
///
/// The overlay keeps drag updates transient and calls `onCommit` exactly once when
/// the gesture ends. Its parent can therefore render lightweight live feedback in
/// `onChange` and create one persistent undo operation in `onCommit`.
struct ImageLayerTransformOverlay: View {
    let normalizedFrame: CGRect
    let rotationDegrees: Double
    let canvasSize: CGSize
    var isLocked = false
    var allowsRotation = true
    var preservesAspectRatio = false
    var minimumPointSize = ImageLayerTransformGeometry.defaultMinimumPointSize
    let onChange: (ImageLayerTransformState) -> Void
    let onCommit: (ImageLayerTransformState) -> Void

    @State private var session: Session?
    @State private var transientState: ImageLayerTransformState?

    private let coordinateSpaceName = "image-layer-transform-canvas"
    private let handleVisualSize = 8.0
    private let handleHitSize = 22.0

    var body: some View {
        let state = displayedState
        let rect = ImageLayerTransformGeometry.displayRect(
            for: state.frame,
            canvasSize: canvasSize
        )

        ZStack {
            selectionBorder(rect: rect, rotation: state.rotationDegrees)

            if !isLocked {
                moveTarget(rect: rect, rotation: state.rotationDegrees)
                resizeHandles(state: state)
                if allowsRotation {
                    rotationStem(state: state)
                    rotationHandle(state: state)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .coordinateSpace(name: coordinateSpaceName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLocked ? "Selected layer, locked" : "Selected layer transform")
        .onDisappear {
            session = nil
            transientState = nil
        }
    }

    private var sourceState: ImageLayerTransformState {
        ImageLayerTransformState(frame: normalizedFrame, rotationDegrees: rotationDegrees)
    }

    private var displayedState: ImageLayerTransformState {
        transientState ?? sourceState
    }

    private func selectionBorder(rect: CGRect, rotation: Double) -> some View {
        ZStack {
            Rectangle()
                .stroke(.black.opacity(0.58), lineWidth: 2.5)
            Rectangle()
                .stroke(.white, style: StrokeStyle(lineWidth: 1.25, dash: [5, 3]))
        }
        .frame(width: rect.width, height: rect.height)
        .rotationEffect(.degrees(rotation))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    private func moveTarget(rect: CGRect, rotation: Double) -> some View {
        Color.clear
            .frame(
                width: max(rect.width - handleHitSize, 1),
                height: max(rect.height - handleHitSize, 1)
            )
            .contentShape(Rectangle())
            .rotationEffect(.degrees(rotation))
            .position(x: rect.midX, y: rect.midY)
            .gesture(transformGesture(.move))
            .help("Drag to move the layer")
            .accessibilityLabel("Move selected layer")
    }

    private func rotationStem(state: ImageLayerTransformState) -> some View {
        let top = ImageLayerTransformGeometry.position(
            of: .top,
            in: state,
            canvasSize: canvasSize
        )
        let handle = ImageLayerTransformGeometry.rotationHandlePosition(
            in: state,
            canvasSize: canvasSize
        )
        return Path { path in
            path.move(to: top)
            path.addLine(to: handle)
        }
        .stroke(.white.opacity(0.9), lineWidth: 1)
        .shadow(color: .black.opacity(0.65), radius: 1)
        .allowsHitTesting(false)
    }

    private func resizeHandles(state: ImageLayerTransformState) -> some View {
        ForEach(ImageLayerResizeHandle.allCases) { handle in
            transformHandle(
                position: ImageLayerTransformGeometry.position(
                    of: handle,
                    in: state,
                    canvasSize: canvasSize
                ),
                accessibilityLabel: "Resize from \(handle.accessibilityName)",
                accessibilityIdentifier: "image-transform-resize-\(handle.rawValue)",
                gesture: transformGesture(.resize(handle))
            )
        }
    }

    private func rotationHandle(state: ImageLayerTransformState) -> some View {
        transformHandle(
            position: ImageLayerTransformGeometry.rotationHandlePosition(
                in: state,
                canvasSize: canvasSize
            ),
            accessibilityLabel: "Rotate selected layer",
            accessibilityIdentifier: "image-transform-rotate",
            gesture: transformGesture(.rotate)
        )
    }

    private func transformHandle<G: Gesture>(
        position: CGPoint,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        gesture: G
    ) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(.black.opacity(0.58), lineWidth: 1))
            .frame(width: handleVisualSize, height: handleVisualSize)
            .frame(width: handleHitSize, height: handleHitSize)
            .contentShape(Circle())
            .position(position)
            .gesture(gesture)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func transformGesture(_ operation: Operation) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                let initial: ImageLayerTransformState
                if let session, session.operation == operation {
                    initial = session.initial
                } else {
                    initial = sourceState
                    session = Session(operation: operation, initial: initial)
                }

                let next: ImageLayerTransformState
                switch operation {
                case .move:
                    next = ImageLayerTransformGeometry.moved(
                        initial,
                        by: value.translation,
                        canvasSize: canvasSize
                    )
                case .resize(let handle):
                    next = ImageLayerTransformGeometry.resized(
                        initial,
                        from: handle,
                        by: value.translation,
                        canvasSize: canvasSize,
                        minimumPointSize: minimumPointSize,
                        preservingAspectRatio: preservesAspectRatio
                    )
                case .rotate:
                    next = ImageLayerTransformGeometry.rotated(
                        initial,
                        from: value.startLocation,
                        to: value.location,
                        canvasSize: canvasSize
                    )
                }
                transientState = next
                onChange(next)
            }
            .onEnded { value in
                guard let activeSession = session, activeSession.operation == operation else {
                    return
                }
                let finalState = transientState ?? activeSession.initial
                session = nil
                transientState = nil
                onCommit(finalState)
            }
    }
}

extension ImageLayerTransformOverlay {
    fileprivate enum Operation: Equatable {
        case move
        case resize(ImageLayerResizeHandle)
        case rotate
    }

    fileprivate struct Session {
        let operation: Operation
        let initial: ImageLayerTransformState
    }
}

extension ImageLayerResizeHandle {
    fileprivate var accessibilityName: String {
        switch self {
        case .topLeading: "top left"
        case .top: "top"
        case .topTrailing: "top right"
        case .trailing: "right"
        case .bottomTrailing: "bottom right"
        case .bottom: "bottom"
        case .bottomLeading: "bottom left"
        case .leading: "left"
        }
    }
}
