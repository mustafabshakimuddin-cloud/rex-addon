import SwiftUI
import AppKit

/// The player's own window on the Mac. It shows whatever session the playback center holds;
/// when the session ends (Up Next, Try Another Source, the player closing itself) the window
/// closes, and when the window is closed the session ends, so the two never disagree.
struct PlayerWindow: View {
    @Environment(PlaybackCenter.self) private var playback
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = playback.session {
                PlayerView(session: session)
                    .id(session.id)
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        .navigationTitle(playback.session?.target.displayTitle ?? "Player")
        .onChange(of: playback.session == nil) { _, ended in
            if ended { dismissWindow(id: "player") }
        }
        .onDisappear {
            // Closed with the red button or ⌘W: end the session, then let the playback center
            // carry on with whatever was waiting for the player to go (the next episode, the
            // source list).
            if playback.session != nil { playback.session = nil }
            playback.playerDismissed()
        }
    }
}
