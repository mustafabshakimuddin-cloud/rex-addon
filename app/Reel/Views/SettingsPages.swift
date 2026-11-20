import SwiftUI

/// Stremio addons whose streams are merged with Torrentio's.
struct AddonsView: View {
    @EnvironmentObject private var settings: AppSettings
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
                Text("Paste the install link from the addon's configure page. It ends in manifest.json and may start with stremio://. If it contains your debrid key, configure it there with the same service you use here.")
            }

            Section("Installed") {
                if settings.addons.isEmpty {
                    Text("None yet. Torrentio is always on.").foregroundStyle(Theme.secondaryText)
                }
                ForEach($settings.addons) { $addon in
                    Toggle(isOn: $addon.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(addon.name)
                            Text(URL(string: addon.base)?.host ?? addon.base).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .onDelete { settings.addons.remove(atOffsets: $0) }
                .onMove { settings.addons.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("Stremio Addons")
        .toolbar { if !settings.addons.isEmpty { EditButton() } }
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
    @EnvironmentObject private var trakt: TraktStore
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
        .scrollContentBackground(.hidden)
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
    @EnvironmentObject private var settings: AppSettings

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
                                Text(choice.title).font(.caption).foregroundStyle(settings.accent == choice ? .white : Theme.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(settings.accent == choice ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Accent Colour")
            }

            Section {
                Picker("Poster size", selection: $settings.posterSize) {
                    ForEach(PosterSize.allCases) { Text($0.title).tag($0) }
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
                Toggle("Show ratings on posters", isOn: $settings.showRatings)
            } header: {
                Text("Posters")
            } footer: {
                Text("Larger posters show fewer titles per row.")
            }

            Section {
                Toggle("Move the featured row by itself", isOn: $settings.heroAutoAdvance)
            } header: {
                Text("Home")
            } footer: {
                Text("The featured titles at the top of Home move on every few seconds. Turn this off to move them only by swiping.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("Appearance")
    }
}

/// Which sections Home shows, in what order.
struct HomeLayoutView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                ForEach(settings.homeOrder) { section in
                    Toggle(isOn: binding(for: section)) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
                .onMove { settings.homeOrder.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Drag to reorder. Hidden sections aren't loaded. Waiting on You collects anything that needs you: setup, failed downloads, new episodes, a stopped sync.")
            }
            Section {
                Button("Reset to Default", role: .destructive) { confirmReset = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .environment(\.editMode, .constant(.active))
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
