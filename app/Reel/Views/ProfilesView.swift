import SwiftUI

/// Who is watching: switch, add, rename and remove profiles.
struct ProfilesView: View {
    @Environment(ProfileStore.self) private var profiles
    @State private var editing: Profile?
    @State private var adding = false
    @State private var confirmDelete: Profile?

    var body: some View {
        Form {
            Section {
                ForEach(profiles.profiles) { profile in
                    HStack(spacing: 12) {
                        ProfileBadge(profile: profile, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.body.weight(.semibold))
                            if profile.isKids { Text("Kids: family and animation only").font(.caption).foregroundStyle(Theme.secondaryText) }
                        }
                        Spacer()
                        if profile.id == profiles.current.id {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        } else {
                            Button("Switch") { AppStores.current?.switchProfile(to: profile) }
                                .buttonStyle(.glass)
                        }
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { editing = profile } label: { Label("Edit", systemImage: "pencil") }
                        if !profile.isDefault && profile.id != profiles.current.id {
                            Button(role: .destructive) { confirmDelete = profile } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .swipeActions {
                        Button { editing = profile } label: { Label("Edit", systemImage: "pencil") }.tint(.indigo)
                    }
                }
                Button { adding = true } label: { Label("Add Profile", systemImage: "plus") }
            } footer: {
                Text("Each profile has its own My List, history and resume points, lists, player choices and Trakt account. The debrid service, addons and other settings are shared. Long-press a profile to edit or delete it.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Backdrop())
        .navigationTitle("Profiles")
        .sheet(item: $editing) { profile in
            NavigationStack { ProfileEditor(profile: profile) { profiles.update($0) } }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ProfileEditor(profile: Profile(id: "", name: "", symbol: Profile.symbols[1])) { new in
                    profiles.add(name: new.name, symbol: new.symbol, isKids: new.isKids)
                }
            }
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "this profile")? Its My List, history and lists go with it.",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let profile = confirmDelete { profiles.delete(profile) }
            }
        }
    }
}

private struct ProfileEditor: View {
    @State var profile: Profile
    let save: (Profile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $profile.name)
            Section("Symbol") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 12) {
                    ForEach(Profile.symbols, id: \.self) { symbol in
                        Button { profile.symbol = symbol } label: {
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(width: 48, height: 48)
                                .background(profile.symbol == symbol ? Theme.accent.opacity(0.35) : Theme.surface, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
            }
            if !profile.isDefault {
                Toggle("Kids profile", isOn: $profile.isKids)
            }
        }
        .navigationTitle(profile.id.isEmpty ? "New Profile" : "Edit Profile")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(profile); dismiss() }
                    .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// A profile's symbol in a circle.
struct ProfileBadge: View {
    let profile: Profile
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: profile.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .frame(width: size, height: size)
            .background(Theme.accentGradient, in: Circle())
            .accessibilityLabel(profile.name)
    }
}

/// Home's profile button: who is watching, and a quick switch.
struct ProfileSwitcher: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppRouter.self) private var router

    var body: some View {
        // Only once there is someone to switch to; one profile needs no button.
        if profiles.hasSeveral { menu }
    }

    private var menu: some View {
        Menu {
            ForEach(profiles.profiles) { profile in
                Button { AppStores.current?.switchProfile(to: profile) } label: {
                    Label(profile.name, systemImage: profile.id == profiles.current.id ? "checkmark" : profile.symbol)
                }
            }
            Divider()
            Button { router.openSettings(.profiles) } label: { Label("Manage Profiles", systemImage: "person.2") }
        } label: {
            ProfileBadge(profile: profiles.current, size: 34)
        }
        .accessibilityLabel("Profile: \(profiles.current.name)")
    }
}
