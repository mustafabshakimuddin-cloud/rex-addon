import SwiftUI
import MobileVLCKit

@main
struct ReelApp: App {
    var body: some Scene {
        WindowGroup {
            Text("\(AppConfig.name) — VLC \(VLCLibrary.shared().version)")
                .preferredColorScheme(.dark)
        }
    }
}
