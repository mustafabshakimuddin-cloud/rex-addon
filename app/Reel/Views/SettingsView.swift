import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var trakt: TraktStore
    @EnvironmentObject private var memory: SourceMemory
    @State private var confirmForget = false
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
                NavigationLink {
                    AddonsView()
                } label: {
                    LabeledContent("Stremio addons", value: settings.addons.isEmpty ? "None" : "\(settings.addons.filter(\.enabled).count) on")
                }
                Toggle("Get streams ready on title pages", isOn: $settings.prepareAhead)
            } header: {
                Text("More Sources")
            } footer: {
                Text("Addons such as Comet or MediaFusion add their results to Torrentio's, so a title still plays when one of them is down. Getting streams ready resolves the likely pick when you open a title, so Play starts at once; it adds that release to your debrid account before you press Play.")
            }

            Section {
                Toggle("Play next episode automatically", isOn: $settings.autoPlayNext)
                Toggle("Show Skip Intro and Skip Credits", isOn: $settings.showSkipButtons)
                Button("Forget source history", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget which sources played well and which failed?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) { memory.forgetAll() }
                    }
            } header: {
                Text("Playback")
            } footer: {
                Text("\(AppConfig.name) remembers which releases played and which failed, and uses that when it picks a source for you. Skip buttons appear when a file's chapters name the intro, recap or credits.")
            }

            Section {
                NavigationLink {
                    TraktSettingsView()
                } label: {
                    LabeledContent("Trakt", value: trakt.isConnected ? "Connected" : "Not connected")
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Trakt keeps your watchlist, resume points and watched episodes in step with other apps and devices, and records what you watch here.")
            }

            Section {
                Picker("Audio language", selection: $settings.preferredAudioLanguage) {
                    ForEach(Languages.options, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Turn on subtitles automatically", isOn: $settings.autoplaySubtitles)
                Picker("Subtitle language", selection: $settings.preferredSubtitleLanguage) {
                    ForEach(Languages.options.filter { !$0.0.isEmpty }, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Find subtitles online when missing", isOn: $settings.searchOnlineSubtitles)
            } header: {
                Text("Player")
            } footer: {
                Text("The audio language is chosen as the stream opens, so the right track starts straight away. Multichannel and Dolby Atmos tracks play in Spatial Audio on supported headphones. Missing subtitles come from OpenSubtitles.")
            }

            Section("Subtitle Appearance") {
                VStack(alignment: .leading) {
                    LabeledContent("Size", value: "\(Int(settings.subtitleScale * 100))%")
                    Slider(value: $settings.subtitleScale, in: 0.7...1.6, step: 0.1)
                }
                Picker("Style", selection: $settings.subtitleStyle) {
                    ForEach(SubtitleStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Colour", selection: $settings.subtitleColor) {
                    ForEach(SubtitleColor.allCases) { Text($0.title).tag($0) }
                }
                SubtitlePreview(appearance: SubtitleAppearance(scale: settings.subtitleScale, style: settings.subtitleStyle, color: settings.subtitleColor))
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Text("Catalogue by Cinemeta. Sources by Torrentio and the addons you add. Subtitles by OpenSubtitles. Sync by Trakt. Playback by AetherEngine (LGPL 3 with an App Store exception) and FFmpeg (LGPL). \(AppConfig.name) hosts no content.")
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
            guard let first = sources.first(where: { $0.isCached && $0.isPlayable }) else {
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

/// What subtitles will look like, over a picture-like gradient.
private struct SubtitlePreview: View {
    let appearance: SubtitleAppearance

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.95, green: 0.8, blue: 0.55), Color(red: 0.2, green: 0.25, blue: 0.4)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            Text("The quick brown fox\njumps over the lazy dog")
                .font(.system(size: 17 * appearance.scale, weight: .semibold))
                .foregroundStyle(appearance.foreground)
                .multilineTextAlignment(.center)
                .modifier(PreviewBacking(style: appearance.style))
                .padding(.bottom, 14)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .accessibilityHidden(true)
    }
}

private struct PreviewBacking: ViewModifier {
    let style: SubtitleStyle
    func body(content: Content) -> some View {
        switch style {
        case .outline:
            content.shadow(color: .black, radius: 0.5).shadow(color: .black.opacity(0.9), radius: 2, y: 1).shadow(color: .black.opacity(0.6), radius: 6)
        case .shadow:
            content.shadow(color: .black.opacity(0.85), radius: 3, x: 1.5, y: 2)
        case .box:
            content.padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
