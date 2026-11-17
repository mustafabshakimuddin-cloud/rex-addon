import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var keyDraft = ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, testing, ok(String), failed(String) }

    var body: some View {
        Form {
            Section {
                Picker("Service", selection: $settings.debridService) {
                    ForEach(DebridService.allCases) { Text($0.name).tag($0) }
                }
                if settings.debridService != .none {
                    SecureField("API key", text: $keyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(saveKey)
                    HStack {
                        Button("Save and Test", action: { saveKey(); Task { await test() } })
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || testState == .testing)
                        Spacer()
                        testStatus
                    }
                    if let page = settings.debridService.keyPage {
                        Link(destination: page) { Label("Get your \(settings.debridService.name) API key", systemImage: "arrow.up.right.square") }
                    }
                }
            } header: {
                Text("Debrid Service")
            } footer: {
                Text("Streams play through your debrid account: the release is fetched by the service and streamed to you over HTTPS. The key is stored in this device's Keychain.")
            }

            Section {
                Toggle("Play the best source automatically", isOn: $settings.autoPlayBest)
                Toggle("Instant sources only", isOn: $settings.cachedOnly)
                Picker("Sort", selection: $settings.sort) {
                    ForEach(TorrentioSort.allCases) { Text($0.title).tag($0) }
                }
                Picker("Maximum size", selection: $settings.maxSizeGB) {
                    Text("No limit").tag(0)
                    ForEach([2, 5, 10, 20, 40], id: \.self) { Text("\($0) GB").tag($0) }
                }
                NavigationLink {
                    MultiSelectList(title: "Hide Qualities", options: TorrentioConfig.qualityOptions, selection: $settings.excludedQualities, label: Self.qualityLabel)
                } label: {
                    LabeledContent("Hide qualities", value: settings.excludedQualities.isEmpty ? "None" : settings.excludedQualities.map(Self.qualityLabel).joined(separator: ", "))
                }
                NavigationLink {
                    MultiSelectList(title: "Providers", options: TorrentioConfig.allProviders, selection: $settings.providers, label: { $0 })
                } label: {
                    LabeledContent("Providers", value: settings.providers.isEmpty ? "All" : "\(settings.providers.count) selected")
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("With automatic play off, Play shows every source so you can pick the quality and size. “Instant” sources are already cached by your debrid service and start straight away.")
            }

            Section {
                Picker("Audio language", selection: $settings.preferredAudioLanguage) {
                    ForEach(Languages.options, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Turn on subtitles automatically", isOn: $settings.autoplaySubtitles)
                Picker("Subtitle language", selection: $settings.preferredSubtitleLanguage) {
                    ForEach(Languages.options.filter { !$0.0.isEmpty }, id: \.0) { Text($0.1).tag($0.0) }
                }
            } header: {
                Text("Player")
            } footer: {
                Text("The audio language is chosen as the stream opens, so the right track starts straight away. Multichannel and Dolby Atmos tracks play in Spatial Audio on supported headphones.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Text("Catalogue by Cinemeta. Sources by Torrentio. Playback by AetherEngine (LGPL 3 with an App Store exception) and FFmpeg (LGPL). \(AppConfig.name) hosts no content.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("Settings")
        .onAppear { keyDraft = settings.debridKey }
        .onChange(of: settings.debridService) { _, _ in testState = .idle }
    }

    @ViewBuilder private var testStatus: some View {
        switch testState {
        case .idle: EmptyView()
        case .testing: ProgressView()
        case let .ok(text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cached).font(.footnote)
        case let .failed(text): Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote).lineLimit(2)
        }
    }

    private func saveKey() {
        settings.debridKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Asks Torrentio for a well-known film through the debrid service and resolves the first
    /// instant source: the same path playback takes, so a pass here means playback will work.
    private func test() async {
        testState = .testing
        var config = settings.torrentio
        config.cachedOnly = true
        do {
            let sources = try await Torrentio.streams(kind: .movie, videoID: "tt0111161", config: config)
            guard let first = PlaybackCenter.rank(sources).first else {
                testState = .failed("No instant sources came back")
                return
            }
            _ = try await Torrentio.resolve(first)
            testState = .ok("Working")
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    static func qualityLabel(_ key: String) -> String {
        ["4k": "4K", "scr": "Screener", "cam": "Cam", "unknown": "Unknown", "dolbyvision": "Dolby Vision", "hdrall": "HDR", "threed": "3D"][key] ?? key
    }
}

struct MultiSelectList: View {
    let title: String
    let options: [String]
    @Binding var selection: [String]
    let label: (String) -> String

    var body: some View {
        List(options, id: \.self) { option in
            Button {
                if let index = selection.firstIndex(of: option) { selection.remove(at: index) } else { selection.append(option) }
            } label: {
                HStack {
                    Text(label(option)).foregroundStyle(.white)
                    Spacer()
                    if selection.contains(option) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle(title)
        .toolbar {
            if !selection.isEmpty {
                Button("Clear") { selection = [] }
            }
        }
    }
}
