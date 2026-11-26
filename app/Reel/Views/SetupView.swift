import SwiftUI

/// First-run setup, also reachable from Settings. One question per page; every step but the first
/// can be skipped, and the last page lists what is set and what isn't, each with a way back to it.
struct SetupView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TraktStore.self) private var trakt
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome
    @State private var keyDraft = ""
    @State private var testState: SettingsView.TestState = .idle

    enum Step: Int, CaseIterable, Comparable {
        case welcome, debrid, addons, playback, sync, done
        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
        var next: Step { Step(rawValue: rawValue + 1) ?? .done }
        var previous: Step { Step(rawValue: rawValue - 1) ?? .welcome }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step != .welcome && step != .done { progressDots.padding(.top, 8) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { page }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 28)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .id(step)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                }
                .scrollBounceBehavior(.basedOnSize)
                buttons
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 560)
            }
            .background(Theme.Backdrop())
            .toolbar {
                if step > .welcome && step < .done {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.left") { go(step.previous) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", systemImage: "xmark") { finish() }
                        .accessibilityLabel("Close setup")
                }
            }
        }
        .onAppear { keyDraft = settings.debridKey }
        .interactiveDismissDisabled()
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            header("Welcome to \(AppConfig.name)", systemImage: "play.rectangle.on.rectangle.fill",
                   text: "Browse films and series, and stream them through your own debrid service or Stremio addons. A few questions and you're watching.")
            VStack(alignment: .leading, spacing: 14) {
                bullet("magnifyingglass", "Explore what's popular, new and top rated")
                bullet("bolt.fill", "Play the best instant source in one tap")
                bullet("calendar", "Follow series and see new episodes on Calendar")
                bullet("arrow.triangle.2.circlepath", "Pick up where you left off, in step with Trakt")
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        case .debrid:
            header("How should titles play?", systemImage: "key.fill",
                   text: "A debrid service fetches releases for you and streams them over HTTPS. Torrentio needs one to give playable links.")
            VStack(alignment: .leading, spacing: 14) {
                Picker("Service", selection: Bindable(settings).debridService) {
                    ForEach(DebridService.allCases) { Text($0 == .none ? "Choose a service" : $0.name).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                if settings.debridService != .none {
                    SecureField("API key", text: $keyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onSubmit { Task { await test() } }
                    HStack {
                        Button("Test Key") { Task { await test() } }
                            .buttonStyle(.glass)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || testState == .testing)
                        Spacer()
                        testStatus
                    }
                    if let page = settings.debridService.keyPage {
                        Link(destination: page) {
                            Label("Get your \(settings.debridService.name) API key", systemImage: "arrow.up.right.square")
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            Text("No debrid service? Skip this and add a Stremio addon that gives direct links on the next page.")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
        case .addons:
            header("More sources", systemImage: "puzzlepiece.extension.fill",
                   text: "Stremio addons such as Comet or MediaFusion add their results to Torrentio's, so a title still plays when one of them is down.")
            NavigationLink {
                AddonsView()
            } label: {
                HStack {
                    Label(settings.addons.isEmpty ? "Add an Addon" : "Addons", systemImage: "plus.circle.fill")
                    Spacer()
                    Text(settings.addons.isEmpty ? "None" : "\(settings.addons.filter(\.enabled).count) on")
                        .foregroundStyle(Theme.secondaryText)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.secondaryText)
                }
                .padding(16)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            Text("Optional. You can add addons any time under Settings → Stremio addons.")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
        case .playback:
            header("Your preferences", systemImage: "slider.horizontal.3",
                   text: "How Play chooses, and which audio and subtitles start with a title. All of this can change later in Settings.")
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Play the best source automatically", isOn: Bindable(settings).autoPlayBest)
                Toggle("Instant sources only", isOn: Bindable(settings).cachedOnly)
                Divider().opacity(0.4)
                Picker("Audio language", selection: Bindable(settings).preferredAudioLanguage) {
                    ForEach(Languages.options, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Turn on subtitles automatically", isOn: Bindable(settings).autoplaySubtitles)
                if settings.autoplaySubtitles {
                    Picker("Subtitle language", selection: Bindable(settings).preferredSubtitleLanguage) {
                        ForEach(Languages.options.filter { !$0.0.isEmpty }, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            Text(settings.autoPlayBest
                 ? "Play starts the best instant release straight away; the Sources button still lists them all."
                 : "Play shows every release so you pick the quality and size yourself.")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
        case .sync:
            header("Keep in sync", systemImage: "arrow.triangle.2.circlepath",
                   text: "Connect Trakt to keep My List, resume points and watched episodes in step with your other apps and devices.")
            NavigationLink {
                TraktSettingsView()
            } label: {
                HStack {
                    Label(trakt.isConnected ? "Trakt connected" : "Connect Trakt",
                          systemImage: trakt.isConnected ? "checkmark.circle.fill" : "link")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.secondaryText)
                }
                .padding(16)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            Text("Optional. Trakt needs a free API app of your own; the Trakt page explains how.")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
        case .done:
            header(settings.canFindSources ? "You're ready" : "Almost there",
                   systemImage: settings.canFindSources ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                   text: settings.canFindSources
                   ? "Here's what is set up. Anything marked Not set can be added later."
                   : "Nothing can play until a debrid service or an addon is added. You can still browse.")
            VStack(spacing: 0) {
                summaryRow("Debrid service", value: settings.isDebridConfigured ? settings.debridService.name : nil, step: .debrid)
                Divider().opacity(0.3)
                summaryRow("Stremio addons", value: settings.addons.isEmpty ? nil : "\(settings.addons.filter(\.enabled).count) on", step: .addons)
                Divider().opacity(0.3)
                summaryRow("Play", value: settings.autoPlayBest ? "Best source automatically" : "Choose from the list", step: .playback)
                Divider().opacity(0.3)
                summaryRow("Trakt", value: trakt.isConnected ? "Connected" : nil, step: .sync)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }

    private func header(_ title: String, systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(Theme.accent.opacity(0.2)), in: .rect(cornerRadius: 18))
            Text(title.localized).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Text(text.localized).font(.body).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 22)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text.localized).font(.subheadline)
        }
    }

    private func summaryRow(_ title: String, value: String?, step target: Step) -> some View {
        Button { go(target) } label: {
            HStack(spacing: 12) {
                Image(systemName: value == nil ? "circle.dashed" : "checkmark.circle.fill")
                    .foregroundStyle(value == nil ? Theme.secondaryText : Theme.cached)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.localized).font(.subheadline.weight(.semibold))
                    Text(value ?? "Not set").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text(value == nil ? "Set Up" : "Change").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var progressDots: some View {
        let steps = Step.allCases.filter { $0 != .welcome && $0 != .done }
        return HStack(spacing: 6) {
            ForEach(steps, id: \.self) { item in
                Capsule()
                    .fill(item <= step ? Theme.accent : Color.white.opacity(0.2))
                    .frame(width: item == step ? 22 : 8, height: 8)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue) of \(steps.count)")
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 10) {
            switch step {
            case .welcome:
                primary("Get Started") { go(.debrid) }
            case .done:
                primary("Start Watching") { finish() }
                Button("Check Status") {
                    finish()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        router.openSettings(.status)
                    }
                }
                .font(.subheadline.weight(.semibold))
            case .debrid:
                primary(settings.isDebridConfigured || !keyDraft.isEmpty ? "Continue" : "Continue without one") {
                    saveKey()
                    go(.addons)
                }
            default:
                primary("Continue") { go(step.next) }
                if step == .addons || step == .sync {
                    Button("Skip for Now") { go(step.next) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.localized).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
    }

    // MARK: Actions

    private func go(_ target: Step) {
        withAnimation(.spring(duration: 0.4)) { step = target }
    }

    private func finish() {
        saveKey()
        settings.setupFinished = true
        router.showingSetup = false
        dismiss()
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if key != settings.debridKey { settings.debridKey = key }
    }

    private func test() async {
        saveKey()
        testState = .testing
        switch await DebridCheck.run(settings.torrentio) {
        case let .success(pass):
            testState = .ok(pass.summary)
            settings.debridAccount = pass.account
        case let .failure(error): testState = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch testState {
        case .idle: EmptyView()
        case .testing: ProgressView()
        case let .ok(text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cached).font(.footnote)
        case let .failed(text): Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.problem).font(.footnote).lineLimit(3)
        }
    }
}
