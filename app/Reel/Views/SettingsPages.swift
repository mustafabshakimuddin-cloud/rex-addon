import SwiftUI
import UniformTypeIdentifiers

/// Stremio addons whose streams are merged with Torrentio's.
struct AddonsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var address = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("https://…/manifest.json", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(add)
                HStack {
                    Button("Add Addon", action: add)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || adding)
                    Spacer()
                    if adding { ProgressView() }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
                }
            } header: {
                Text("Add")
            } footer: {
                Text("Paste the install link from the addon's configure page. It ends in manifest.json and may start with stremio://. If it contains your debrid key, configure it there with the same service you use here. An addon's streams join Torrentio's, and its catalogues appear in Explore under Rows.")
            }

            Section("Installed") {
                if settings.addons.isEmpty {
                    Text("None yet. Torrentio is always on.").foregroundStyle(Theme.secondaryText)
                }
                ForEach(Bindable(settings).addons) { $addon in
                    Toggle(isOn: $addon.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(addon.name)
                            Text(URL(string: addon.base)?.host ?? addon.base).font(.caption).foregroundStyle(Theme.secondaryText)
                            Text([addon.hasStreams ? "Streams" : nil,
                                  (addon.catalogs?.isEmpty ?? true) ? nil : "\(addon.catalogs!.count) catalogue\(addon.catalogs!.count == 1 ? "" : "s") in Explore"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(Theme.secondaryText)
                            if addon.base.hasPrefix("http://") {
                                Label("Not encrypted: its links, and any key in them, travel in the clear.", systemImage: "lock.open")
                                    .font(.caption2).foregroundStyle(Theme.warning)
                            }
                        }
                    }
                    #if os(tvOS)
                    // No drag or swipe on Apple TV: hold the select button for these.
                    .contextMenu {
                        let index = settings.addons.firstIndex { $0.id == addon.id } ?? 0
                        if index > 0 {
                            Button { settings.addons.move(fromOffsets: [index], toOffset: index - 1) } label: { Label("Move Up", systemImage: "arrow.up") }
                        }
                        if index < settings.addons.count - 1 {
                            Button { settings.addons.move(fromOffsets: [index], toOffset: index + 2) } label: { Label("Move Down", systemImage: "arrow.down") }
                        }
                        Button(role: .destructive) { settings.addons.removeAll { $0.id == addon.id } } label: { Label("Remove", systemImage: "trash") }
                    }
                    #endif
                }
                #if os(iOS)
                .onDelete { settings.addons.remove(atOffsets: $0) }
                .onMove { settings.addons.move(fromOffsets: $0, toOffset: $1) }
                #endif
            }
        }
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle("Stremio Addons")
        #if os(iOS)
        .toolbar { if !settings.addons.isEmpty { EditButton() } }
        #endif
    }

    private func add() {
        let text = address
        adding = true
        error = nil
        Task {
            defer { adding = false }
            do {
                let addon = try await Addons.install(from: text)
                if let index = settings.addons.firstIndex(where: { $0.id == addon.id }) {
                    settings.addons[index] = addon
                } else {
                    settings.addons.append(addon)
                }
                address = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Connects a Trakt account with the device flow.
struct TraktSettingsView: View {
    @Environment(TraktStore.self) private var trakt
    @Environment(\.openURL) private var openURL
    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        Form {
            if trakt.isConnected {
                Section {
                    LabeledContent("Status", value: "Connected")
                    if let lastSync = trakt.lastSync {
                        LabeledContent("Last sync", value: lastSync.formatted(date: .omitted, time: .shortened))
                    }
                    if let error = trakt.syncError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
                    }
                    Button {
                        Task { await trakt.sync() }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            Spacer()
                            if trakt.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(trakt.isSyncing)
                    Button("Disconnect", role: .destructive) { trakt.disconnect() }
                } footer: {
                    Text("Your watchlist, resume points and watched episodes come in from Trakt; what you watch and add here goes back.")
                }
            } else {
                switch trakt.signIn {
                case let .waiting(code, url):
                    Section {
                        VStack(spacing: 12) {
                            Text("Enter this code at").foregroundStyle(Theme.secondaryText)
                            Text(url.replacingOccurrences(of: "https://", with: "")).font(.headline)
                            #if os(tvOS)
                            Text(code)
                                .font(.system(size: 64, weight: .bold, design: .monospaced))
                            // On Apple TV the phone does the typing: scan, sign in, enter the code.
                            if let link = URL(string: url), let image = QRCodeSheet.code(for: link.absoluteString) {
                                Image(uiImage: image).interpolation(.none).resizable()
                                    .frame(width: 260, height: 260)
                                    .padding(16)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                Text("Or scan this with your phone").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            #else
                            Text(code)
                                .font(.system(size: 40, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                            HStack {
                                Button("Copy Code", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
                                    .buttonStyle(.glass)
                                Button("Open Trakt", systemImage: "safari") {
                                    if let link = URL(string: url) { openURL(link) }
                                }
                                .buttonStyle(.glassProminent)
                            }
                            #endif
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Waiting for you to approve…").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        Button("Cancel", role: .cancel) { trakt.cancelSignIn() }
                    }
                default:
                    Section {
                        TextField("Client ID", text: $clientID)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Client Secret", text: $clientSecret)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Connect") { trakt.connect(clientID: clientID, clientSecret: clientSecret) }
                            .disabled(clientID.isEmpty || clientSecret.isEmpty)
                        if case let .failed(message) = trakt.signIn {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
                        }
                    } header: {
                        Text("Your Trakt API App")
                    } footer: {
                        Text("Trakt needs an API app of your own: open trakt.tv/oauth/applications, choose New Application, give it any name, enter urn:ietf:wg:oauth:2.0:oob as the redirect URI, and save. Paste its Client ID and Client Secret here. They are kept in this device's Keychain.")
                    }
                    Section {
                        Link(destination: URL(string: "https://trakt.tv/oauth/applications/new")!) {
                            Label("Create a Trakt API App", systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
        }
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle("Trakt")
        .onAppear {
            clientID = trakt.credentials?.clientID ?? ""
            clientSecret = trakt.credentials?.clientSecret ?? ""
        }
    }
}

/// Accent colour, poster size and the small things that change how the app looks.
struct AppearanceView: View {
    @Environment(AppSettings.self) private var settings

    private let sample = MediaItem(
        id: "tt0111161", kind: .movie, name: "The Shawshank Redemption",
        poster: URL(string: "https://images.metahub.space/poster/medium/tt0111161/img"),
        year: "1994", rating: "9.3")

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 14)], spacing: 14) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button {
                            withAnimation(.snappy) { settings.accent = choice }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(LinearGradient(colors: [choice.deep, choice.accent], startPoint: .bottomLeading, endPoint: .topTrailing))
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if settings.accent == choice {
                                            Image(systemName: "checkmark").font(.headline.weight(.bold)).foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(Circle().strokeBorder(.white.opacity(settings.accent == choice ? 0.9 : 0.15), lineWidth: 2))
                                Text(choice.title.localized).font(.caption).foregroundStyle(settings.accent == choice ? .white : Theme.secondaryText)
                            }
                        }
                        .cardButton()
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(settings.accent == choice ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Accent Colour")
            }

            Section {
                Picker("Poster size", selection: Bindable(settings).posterSize) {
                    ForEach(PosterSize.allCases) { Text($0.title.localized).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Spacer()
                    PosterCard(item: sample, width: 116 * settings.posterSize.scale)
                        .environment(\.showsRatings, settings.showRatings)
                        .animation(.snappy, value: settings.posterSize)
                    Spacer()
                }
                .padding(.vertical, 6)
                Toggle("Show ratings on posters", isOn: Bindable(settings).showRatings)
            } header: {
                Text("Posters")
            } footer: {
                Text("Larger posters show fewer titles per row.")
            }

            Section {
                Toggle("Move the featured row by itself", isOn: Bindable(settings).heroAutoAdvance)
            } header: {
                Text("Home")
            } footer: {
                Text("The featured titles at the top of Home move on every few seconds. Turn this off to move them only by swiping.")
            }
        }
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle("Appearance")
    }
}

/// Which sections Home shows, in what order.
struct HomeLayoutView: View {
    @Environment(AppSettings.self) private var settings
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                ForEach(settings.homeOrder) { section in
                    Toggle(isOn: binding(for: section)) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    #if os(tvOS)
                    .contextMenu {
                        let index = settings.homeOrder.firstIndex(of: section) ?? 0
                        if index > 0 {
                            Button { settings.homeOrder.move(fromOffsets: [index], toOffset: index - 1) } label: { Label("Move Up", systemImage: "arrow.up") }
                        }
                        if index < settings.homeOrder.count - 1 {
                            Button { settings.homeOrder.move(fromOffsets: [index], toOffset: index + 2) } label: { Label("Move Down", systemImage: "arrow.down") }
                        }
                    }
                    #endif
                }
                #if os(iOS)
                .onMove { settings.homeOrder.move(fromOffsets: $0, toOffset: $1) }
                #endif
            } footer: {
                #if os(tvOS)
                Text("Hold the select button on a section to move it. Hidden sections aren't loaded. Waiting on You collects anything that needs you: setup, failed downloads, new episodes, a stopped sync.")
                #else
                Text("Drag to reorder. Hidden sections aren't loaded. Waiting on You collects anything that needs you: setup, failed downloads, new episodes, a stopped sync.")
                #endif
            }
            Section {
                Button("Reset to Default", role: .destructive) { confirmReset = true }
            }
        }
        .clearListBackground()
        .background(Theme.Backdrop())
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("Home Screen")
        .confirmationDialog("Show every section in the original order?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { settings.resetHomeLayout() }
        }
    }

    private func binding(for section: HomeSection) -> Binding<Bool> {
        Binding(
            get: { !settings.homeHidden.contains(section) },
            set: { shown in
                if shown { settings.homeHidden.remove(section) } else { settings.homeHidden.insert(section) }
            }
        )
    }
}

/// How offline copies are made and kept.
struct OfflineSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router

    var body: some View {
        Form {
            Section {
                Toggle("Download over cellular", isOn: Bindable(settings).downloadsOverCellular)
                Picker("Largest download", selection: Bindable(settings).downloadMaxSizeGB) {
                    Text("Same as streaming").tag(0)
                    ForEach([2, 4, 8, 15, 30], id: \.self) { Text("\($0) GB").tag($0) }
                }
                Toggle("Save subtitles with downloads", isOn: Bindable(settings).downloadSubtitles)
            } footer: {
                Text("Downloads pick the release Play would, within this size. Subtitles in your subtitle language come from OpenSubtitles and play offline too.")
            }
            Section {
                Picker("Delete after watching", selection: Bindable(settings).deleteWatchedDownloadsAfterDays) {
                    Text("Never").tag(0)
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text($0 == 1 ? "After a day" : "After \($0) days").tag($0) }
                }
            } footer: {
                Text("A copy you've finished watching is deleted this long after, to free space.")
            }
            Section {
                Button("Open Downloads") { router.openLibrary(.downloads) }
            }
        }
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle("Offline Copies")
    }
}

/// A file with My List, history, source memory and settings, to restore after a reinstall. Keys
/// and Trakt's sign-in stay in the Keychain and are never written to it.
struct BackupView: View {
    @Environment(Library.self) private var library
    @Environment(SourceMemory.self) private var memory
    @Environment(ListsStore.self) private var lists
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?
    @State private var confirmRestore: URL?

    var body: some View {
        Form {
            #if os(tvOS)
            BackupTransferSection(message: $message)
            #else
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Save Backup…", systemImage: "square.and.arrow.up") }
                } else {
                    ProgressView()
                }
            } footer: {
                Text("Saves My List, your history and resume points, what \(AppConfig.name) learned about sources, addons and settings. Your debrid key and Trakt sign-in aren't included; enter them again after restoring.")
            }
            Section {
                Button("Restore from a Backup…") { importing = true }
            } footer: {
                Text("Replaces My List, history and settings on this device with the backup's.")
            }
            #endif
            if let message {
                Section { Text(message).font(.footnote) }
            }
            if !JSONFile.unreadableFiles.isEmpty {
                Section {
                    Text("These files couldn't be read at launch and were kept aside rather than lost: \(JSONFile.unreadableFiles.joined(separator: ", ")). A backup restores what they held.")
                        .font(.footnote).foregroundStyle(Theme.warning)
                }
            }
        }
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle("Back Up and Restore")
        #if os(iOS)
        .task { exportURL = Backup.write(library: library, memory: memory, lists: lists) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { confirmRestore = url }
        }
        #endif
        .confirmationDialog("Replace this device's library and settings with the backup?",
                            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let url = confirmRestore { restore(url) }
            }
        }
    }

    private func restore(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try Backup.restore(data, library: library, memory: memory, lists: lists)
            message = "Restored. Close and reopen \(AppConfig.name) for the restored settings to take effect."
        } catch {
            message = "That file isn't a \(AppConfig.name) backup."
        }
    }
}

/// An optional key for The Movie Database, for photos and biographies of cast and crew.
struct TMDBSettingsView: View {
    @State private var draft = TMDB.key
    @State private var state: SettingsView.TestState = .idle

    var body: some View {
        Form {
            Section {
                SecureField("API key or read access token", text: $draft)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("Save and Test") { Task { await save() } }
                        .disabled(state == .testing)
                    Spacer()
                    switch state {
                    case .idle: EmptyView()
                    case .testing: ProgressView()
                    case let .ok(text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.cached).font(.footnote)
                    case let .failed(text): Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
                    }
                }
                if let page = URL(string: "https://www.themoviedb.org/settings/api") {
                    Link(destination: page) { Label("Get a free TMDB key", systemImage: "arrow.up.right.square") }
                }
            } footer: {
                Text("Optional. With a key, cast and crew get photos and person pages get a biography. Leave it empty to turn this off. The key stays in this device's Keychain.")
            }
        }
        .clearListBackground()
        .background(Theme.Backdrop())
        .navigationTitle("TMDB")
    }

    private func save() async {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            TMDB.setKey("")
            state = .ok("Off")
            return
        }
        state = .testing
        if await TMDB.test(key) {
            TMDB.setKey(key)
            state = .ok("Working")
        } else {
            state = .failed("TMDB refused that key.")
        }
    }
}
