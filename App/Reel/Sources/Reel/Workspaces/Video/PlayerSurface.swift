@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        // Only when it actually differs. SwiftUI calls this on every upstream
        // re-evaluation, which during a rail drag is every frame, and handing
        // an AVPlayerLayer a player makes AVFoundation reconfigure its render
        // pipeline even when it is the same player it already had.
        guard view.playerLayer.player !== player else { return }
        view.playerLayer.player = player
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
