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
