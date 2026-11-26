import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TraktStore.self) private var trakt
    @Environment(SourceMemory.self) private var memory
    @Environment(AlertCenter.self) private var alerts
    @Environment(AppRouter.self) private var router
    @Environment(ProfileStore.self) private var profiles
    @State private var confirmForget = false
    @State private var keyDraft = ""
    @State private var secondKeyDraft = ""
    @State private var secondTest: TestState = .idle
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, testing, ok(String), failed(String) }

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsPage.status) {
                    HStack(spacing: 12) {
                        Image(systemName: statusSymbol)
                            .font(.title3)
                            .foregroundStyle(statusTint)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Status").font(.body.weight(.semibold))
                            Text(statusLine).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if Attention.settingsNeedAttention(settings: settings, trakt: trakt, alerts: alerts) { AttentionDot() }
                    }
                }
                NavigationLink(value: SettingsPage.profiles) {
                    HStack(spacing: 12) {
                        ProfileBadge(profile: profiles.current, size: 30)
                        LabeledContent("Profile", value: profiles.current.name)
                    }
                }
                Button {
                    router.openSetup()
                } label: {
                    Label(settings.setupFinished ? "Run Setup Again" : "Finish Setup", systemImage: "wand.and.stars")
                }
            } footer: {
                Text("Status checks your debrid service, Torrentio, the catalogue and each addon, and says what to do about anything that fails.")
            }

            Section {
                Picker("Service", selection: Bindable(settings).debridService) {
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
                    if let account = settings.debridAccount {
                        if let name = account.username { LabeledContent("Account", value: name) }
                        if let expires = account.expires {
                            LabeledContent("Plan ends") {
                                Text(expires.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle((account.daysLeft ?? 99) <= 7 ? Theme.warning : Theme.secondaryText)
                            }
                        }
                    }
                }
            } header: {
                Text("Debrid Service")
            } footer: {
                Text("Streams play through your debrid account: the release is fetched by the service and streamed to you over HTTPS. The key is stored in this device's Keychain.")
            }

            if settings.isDebridConfigured {
                Section {
                    Picker("Second service", selection: Bindable(settings).secondaryService) {
                        ForEach(DebridService.allCases.filter { $0 != settings.debridService }) { Text($0.name).tag($0) }
                    }
                    if settings.secondaryService != .none {
                        SecureField("API key", text: $secondKeyDraft)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { settings.secondaryKey = secondKeyDraft }
                        HStack {
                            Button("Save and Test") {
                                settings.secondaryKey = secondKeyDraft
                                Task { await testSecond() }
                            }
                            .disabled(secondKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty || secondTest == .testing)
                            Spacer()
                            switch secondTest {
                            case .idle: EmptyView()
                            case .testing: ProgressView()
                            case let .ok(text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cached).font(.footnote)
                            case let .failed(text): Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote).lineLimit(2)
                            }
                        }
                    }
                } header: {
                    Text("Second Debrid Service")
                } footer: {
                    Text("Optional. Torrentio is asked through both, and releases only the second has cached are added to the list. Useful when one service lacks a title the other has.")
                }
            }

            Section {
                Toggle("Play the best source automatically", isOn: Bindable(settings).autoPlayBest)
                NavigationLink(value: SettingsPage.pickRules) {
                    LabeledContent("Pick rules", value: pickRulesSummary)
                }
                NavigationLink(value: SettingsPage.addons) {
                    LabeledContent("Stremio addons", value: settings.addons.isEmpty ? "None" : "\(settings.addons.filter(\.enabled).count) on")
                }
                Toggle("Get streams ready on title pages", isOn: Bindable(settings).prepareAhead)
            } header: {
                Text("Sources")
            } footer: {
                Text("With automatic play off, Play shows every source so you can pick. Pick rules decide which releases are listed and which Play chooses. Addons such as Comet or MediaFusion add their results to Torrentio's. Getting streams ready resolves the likely pick when you open a title, so Play starts at once; it adds that release to your debrid account before you press Play.")
            }

            Section {
                Toggle("Play next episode automatically", isOn: Bindable(settings).autoPlayNext)
                Toggle("Show Skip Intro and Skip Credits", isOn: Bindable(settings).showSkipButtons)
                Toggle("Skip intros automatically", isOn: Bindable(settings).autoSkipIntro)
                Toggle("Skip recaps automatically", isOn: Bindable(settings).autoSkipRecap)
                Button("Forget player choices") { ViewingPreferences.forgetAll() }
                Button("Forget source history", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget which sources played well and which failed?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) { memory.forgetAll() }
                    }
            } header: {
                Text("Playback")
            } footer: {
                Text("\(AppConfig.name) remembers which releases played and which failed, and uses that when it picks a source for you. Skip buttons appear when a file's chapters name the intro, recap or credits. Each series also remembers its audio and subtitle language, subtitle timing, fill and speed.")
            }

            Section {
                NavigationLink(value: SettingsPage.trakt) {
                    LabeledContent("Trakt") {
                        HStack(spacing: 6) {
                            Text(trakt.isConnected ? "Connected" : "Not connected")
                            if trakt.syncError != nil { AttentionDot(size: 7) }
                        }
                    }
                }
                NavigationLink {
                    TMDBSettingsView()
                } label: {
                    LabeledContent("TMDB", value: TMDB.isConfigured ? "On" : "Off")
                }
            } header: {
                Text("Sync and Services")
            } footer: {
                Text("Trakt keeps your watchlist, resume points and watched episodes in step with other apps and devices, and records what you watch here.")
            }

            Section {
                Picker("Audio language", selection: Bindable(settings).preferredAudioLanguage) {
                    ForEach(Languages.options, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Turn on subtitles automatically", isOn: Bindable(settings).autoplaySubtitles)
                Picker("Subtitle language", selection: Bindable(settings).preferredSubtitleLanguage) {
                    ForEach(Languages.options.filter { !$0.0.isEmpty }, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Find subtitles online when missing", isOn: Bindable(settings).searchOnlineSubtitles)
                Toggle("Night mode", isOn: Bindable(settings).nightMode)
                Picker("Dialogue boost", selection: Bindable(settings).dialogueBoostDB) {
                    Text("Off").tag(0.0)
                    ForEach([3.0, 6.0, 9.0, 12.0], id: \.self) { Text("+\(Int($0)) dB").tag($0) }
                }
                Toggle("Lift quiet films", isOn: Bindable(settings).liftQuietSources)
            } header: {
                Text("Player")
            } footer: {
                Text("The audio language is chosen as the stream opens, so the right track starts straight away. Multichannel and Dolby Atmos tracks play in Spatial Audio on supported headphones. Missing subtitles come from OpenSubtitles. Night mode narrows the gap between whispers and explosions; the dialogue boost raises speech; lifting quiet films evens out releases mixed low. While any of them is on, Atmos plays without its height channels.")
            }

            Section("Subtitle Appearance") {
                VStack(alignment: .leading) {
                    LabeledContent("Size", value: "\(Int(settings.subtitleScale * 100))%")
                    Slider(value: Bindable(settings).subtitleScale, in: 0.7...1.6, step: 0.1)
                }
                Picker("Style", selection: Bindable(settings).subtitleStyle) {
                    ForEach(SubtitleStyle.allCases) { Text($0.title.localized).tag($0) }
                }
                Picker("Colour", selection: Bindable(settings).subtitleColor) {
                    ForEach(SubtitleColor.allCases) { Text($0.title.localized).tag($0) }
                }
                if settings.subtitleStyle == .box {
                    VStack(alignment: .leading) {
                        LabeledContent("Box", value: "\(Int(settings.subtitleBoxOpacity * 100))%")
                        Slider(value: Bindable(settings).subtitleBoxOpacity, in: 0.3...1, step: 0.05)
                    }
                }
                VStack(alignment: .leading) {
                    LabeledContent("Height", value: settings.subtitleLift == 0 ? "Default" : "+\(Int(settings.subtitleLift)) pt")
                    Slider(value: Bindable(settings).subtitleLift, in: 0...120, step: 10)
                }
                Toggle("Follow the system text size", isOn: Bindable(settings).subtitleFollowsTextSize)
                SubtitlePreview(appearance: settings.subtitleAppearance)
            }

            Section {
                NavigationLink(value: SettingsPage.offline) {
                    LabeledContent("Offline copies", value: settings.downloadsOverCellular ? "Wi-Fi and cellular" : "Wi-Fi only")
                }
                Toggle("Tell me about new episodes", isOn: Bindable(settings).notifyNewEpisodes)
                Toggle("Tell me when a download finishes", isOn: Bindable(settings).notifyDownloads)
            } header: {
                Text("Downloads and Notifications")
            } footer: {
                Text("New episodes of the series you follow are checked in the background a few times a day.")
            }

            Section {
                NavigationLink(value: SettingsPage.appearance) {
                    LabeledContent("Appearance") {
                        HStack(spacing: 6) {
                            Circle().fill(settings.accent.accent).frame(width: 12, height: 12)
                            Text(settings.accent.title.localized)
                        }
                    }
                }
                NavigationLink(value: SettingsPage.homeScreen) {
                    LabeledContent("Home Screen", value: "\(settings.visibleHomeSections.count) sections")
                }
                NavigationLink(value: SettingsPage.backup) {
                    Label("Back Up and Restore", systemImage: "externaldrive.badge.icloud")
                }
            } header: {
                Text("Customise")
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
        .navigationDestination(for: SettingsPage.self) { page in
            switch page {
            case .status: StatusView()
            case .pickRules: PickRulesView()
            case .addons: AddonsView()
            case .trakt: TraktSettingsView()
            case .appearance: AppearanceView()
            case .homeScreen: HomeLayoutView()
            case .offline: OfflineSettingsView()
            case .backup: BackupView()
            case .profiles: ProfilesView()
            }
        }
        .onAppear {
            keyDraft = settings.debridKey
            secondKeyDraft = settings.secondaryKey
        }
        .onChange(of: settings.debridService) { _, _ in testState = .idle }
    }

    private var statusLine: String {
        if !settings.canFindSources { return "Nothing can play yet" }
        if trakt.syncError != nil { return "Trakt sync stopped" }
        if alerts.unseenProblems > 0 { return alerts.unseenProblems == 1 ? "1 new alert" : "\(alerts.unseenProblems) new alerts" }
        return "Check that everything works"
    }

    private var statusSymbol: String {
        if !settings.canFindSources { return "xmark.octagon.fill" }
        if trakt.syncError != nil || alerts.unseenProblems > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    private var statusTint: Color {
        if !settings.canFindSources { return Theme.problem }
        if trakt.syncError != nil || alerts.unseenProblems > 0 { return Theme.warning }
        return Theme.cached
    }

    private var pickRulesSummary: String {
        var parts: [String] = []
        if settings.cachedOnly { parts.append("Instant") }
        if settings.maxSizeGB > 0 { parts.append("≤ \(settings.maxSizeGB) GB") }
        if !settings.excludedQualities.isEmpty { parts.append("\(settings.excludedQualities.count) hidden") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
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

    /// The key as playback uses it, checked without adding anything to the account.
    private func test() async {
        testState = .testing
        switch await DebridCheck.run(settings.torrentio) {
        case let .success(pass):
            testState = .ok(pass.summary)
            settings.debridAccount = pass.account
        case let .failure(error): testState = .failed(error.localizedDescription)
        }
    }

    private func testSecond() async {
        guard let config = settings.secondaryTorrentio else { secondTest = .failed("Enter a key first."); return }
        secondTest = .testing
        switch await DebridCheck.run(config) {
        case let .success(pass): secondTest = .ok(pass.summary)
        case let .failure(error): secondTest = .failed(error.localizedDescription)
        }
    }

    static func qualityLabel(_ key: String) -> String {
        ["4k": "4K", "scr": "Screener", "cam": "Cam", "unknown": "Unknown", "dolbyvision": "Dolby Vision", "hdrall": "HDR", "threed": "3D"][key] ?? key
    }
}

/// Which releases are listed, and which one Play picks. Reached from Settings and from the
/// sources list itself.
struct PickRulesView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                Toggle("Instant sources only", isOn: Bindable(settings).cachedOnly)
                Picker("Sort", selection: Bindable(settings).sort) {
                    ForEach(TorrentioSort.allCases) { Text($0.title.localized).tag($0) }
                }
                Picker("Maximum size", selection: Bindable(settings).maxSizeGB) {
                    Text("No limit").tag(0)
                    ForEach([2, 5, 10, 20, 40], id: \.self) { Text("\($0) GB").tag($0) }
                }
            } footer: {
                Text("“Instant” sources are already cached by your debrid service and start straight away. A size limit keeps 4K remuxes off a slow connection.")
            }
            Section {
                NavigationLink {
                    MultiSelectList(title: "Hide Qualities", options: TorrentioConfig.qualityOptions, selection: Bindable(settings).excludedQualities, label: SettingsView.qualityLabel)
                } label: {
                    LabeledContent("Hide qualities", value: settings.excludedQualities.isEmpty ? "None" : settings.excludedQualities.map(SettingsView.qualityLabel).joined(separator: ", "))
                }
                NavigationLink {
                    MultiSelectList(title: "Providers", options: TorrentioConfig.allProviders, selection: Bindable(settings).providers, label: { $0 })
                } label: {
                    LabeledContent("Providers", value: settings.providers.isEmpty ? "All" : "\(settings.providers.count) selected")
                }
                Picker("Minimum seeders", selection: Bindable(settings).minSeeders) {
                    Text("Any").tag(0)
                    ForEach([5, 10, 25, 50], id: \.self) { Text("\($0)").tag($0) }
                }
            } footer: {
                Text("Play picks instant sources first, then your quality order, then your preferences below, then what has played well for you before. Changes apply to the next search. The seeder minimum applies to releases that aren't instant.")
            }
            Section {
                leaning("HDR", Bindable(settings).preferHDR)
                leaning("Dolby Vision", Bindable(settings).preferDolbyVision)
                leaning("Dolby Atmos", Bindable(settings).preferAtmos)
                leaning("Remux", Bindable(settings).preferRemux)
                Toggle("Favour my audio language", isOn: Bindable(settings).preferAudioLanguageReleases)
                Toggle("Match this device", isOn: Bindable(settings).matchDevice)
                NavigationLink {
                    GroupsList()
                } label: {
                    LabeledContent("Preferred groups", value: settings.preferredGroups.isEmpty ? "None" : settings.preferredGroups.joined(separator: ", "))
                }
            } header: {
                Text("Preferences")
            } footer: {
                Text("Within a quality, these decide which release comes first. Matching the device passes over Dolby Vision and HDR on screens that can't show them, and AV1 where the chip can't decode it\(AppSettings.deviceSupport.av1 ? "" : " (this one can't)"). Long-press a source to prefer its release group.")
            }
            Section {
                TextField("Server", text: Bindable(settings).torrentioServer)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if settings.torrentioServer != Torrentio.base {
                    Button("Use the public server") { settings.torrentioServer = Torrentio.base }
                }
                NavigationLink {
                    MultiSelectList(title: "Language Priority", options: TorrentioConfig.languageOptions, selection: Bindable(settings).priorityLanguages,
                                    label: { $0.capitalized })
                } label: {
                    LabeledContent("Language priority", value: settings.priorityLanguages.isEmpty ? "None" : settings.priorityLanguages.map(\.capitalized).joined(separator: ", "))
                }
                Picker("Results per quality", selection: Bindable(settings).perQualityLimit) {
                    Text("All").tag(0)
                    ForEach([3, 5, 10, 20], id: \.self) { Text("\($0)").tag($0) }
                }
            } header: {
                Text("Torrentio")
            } footer: {
                Text("A self-hosted Torrentio can stand in for the public one. Languages listed here come first in Torrentio's results.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("Pick Rules")
    }

    private func leaning(_ title: String, _ value: Binding<Leaning>) -> some View {
        Picker(title, selection: value) {
            ForEach(Leaning.allCases) { Text($0.title.localized).tag($0) }
        }
    }
}

/// Release groups whose releases come first within a quality.
private struct GroupsList: View {
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Group, e.g. FLUX", text: $draft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("The group is the name after the last dash in a release: “FLUX” in Movie.2024.2160p.WEB-DL.DV-FLUX.")
            }
            Section {
                ForEach(settings.preferredGroups, id: \.self) { Text($0) }
                    .onDelete { settings.preferredGroups.remove(atOffsets: $0) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("Preferred Groups")
    }

    private func add() {
        let group = draft.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !group.isEmpty, !settings.preferredGroups.contains(group) else { return }
        settings.preferredGroups.append(group)
        draft = ""
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
