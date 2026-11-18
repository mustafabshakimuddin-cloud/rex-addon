import SwiftUI
import AVFoundation
import UIKit

/// Hands the background download session's wake-up to the download store.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var pendingBackgroundCompletion: (() -> Void)?

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadStore.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.pendingBackgroundCompletion = completionHandler
    }
}

/// The app's long-lived stores, built in dependency order once.
@MainActor
final class AppStores {
    let settings = AppSettings()
    let library = Library()
    let memory = SourceMemory()
    let downloads = DownloadStore()
    let trakt = TraktStore()
    let router = AppRouter()
    lazy var playback = PlaybackCenter(memory: memory, downloads: downloads)

    init() {
        trakt.attach(library)
    }
}

@main
struct ReelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var library: Library
    @StateObject private var playback: PlaybackCenter
    @StateObject private var router: AppRouter
    @StateObject private var memory: SourceMemory
    @StateObject private var downloads: DownloadStore
    @StateObject private var trakt: TraktStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Play sound with the silent switch on, like any video app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let stores = AppStores()
        _settings = StateObject(wrappedValue: stores.settings)
        _library = StateObject(wrappedValue: stores.library)
        _playback = StateObject(wrappedValue: stores.playback)
        _router = StateObject(wrappedValue: stores.router)
        _memory = StateObject(wrappedValue: stores.memory)
        _downloads = StateObject(wrappedValue: stores.downloads)
        _trakt = StateObject(wrappedValue: stores.trakt)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(playback)
                .environmentObject(router)
                .environmentObject(memory)
                .environmentObject(downloads)
                .environmentObject(trakt)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.saveNow() }
            if phase == .active {
                if let completion = AppDelegate.pendingBackgroundCompletion {
                    downloads.backgroundCompletion = completion
                    AppDelegate.pendingBackgroundCompletion = nil
                }
                Task { await trakt.sync() }
            }
        }
    }
}
