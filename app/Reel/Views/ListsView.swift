import SwiftUI

/// "Add to List" for a title: every list of yours with a tick, and a way to start a new one.
struct AddToListMenu: View {
    let item: MediaItem
    @Environment(ListsStore.self) private var lists
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Menu {
            ForEach(lists.lists) { list in
                Button { lists.toggle(item, in: list.id) } label: {
                    Label(list.name, systemImage: lists.contains(item, in: list.id) ? "checkmark.circle.fill" : "circle")
                }
            }
            if !lists.lists.isEmpty { Divider() }
            Button { naming = true } label: { Label("New List…", systemImage: "plus") }
        } label: {
            Label("Add to List", systemImage: "text.badge.plus")
        }
        .alert("New List", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                lists.create(newName, with: item)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("\(item.name) is added to it.")
        }
    }
}

/// Your lists and your Trakt lists, from Library.
struct ListsSection: View {
    @Environment(ListsStore.self) private var lists
    @Environment(TraktStore.self) private var trakt
    @State private var traktLists: [Trakt.List] = []
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lists").font(.title3.weight(.bold))
                Spacer()
                Button { naming = true } label: { Label("New List", systemImage: "plus") }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20)
            if lists.lists.isEmpty && traktLists.isEmpty {
                Text("Make lists of your own beyond My List: long-press a title, or use + here.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText).padding(.horizontal, 20)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(lists.lists) { list in
                        NavigationLink(value: ListRoute.custom(list.id)) {
                            tile(list.name, count: list.items.count, poster: list.items.first?.poster, systemImage: "list.bullet")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(traktLists) { list in
                        NavigationLink(value: ListRoute.trakt(list)) {
                            tile(list.name, count: list.itemCount, poster: nil, systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
        }
        .task(id: trakt.isConnected) {
            traktLists = trakt.isConnected ? ((try? await trakt.lists()) ?? []) : []
        }
        .alert("New List", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") { lists.create(newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func tile(_ name: String, count: Int, poster: URL?, systemImage: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
                if let poster {
                    RemoteImage(url: poster, targetWidth: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: systemImage).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(count == 1 ? "1 title" : "\(count) titles").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Where a list tile leads.
enum ListRoute: Hashable {
    case custom(UUID)
    case trakt(Trakt.List)
}

/// One list as a grid; your own can be renamed, reordered and emptied.
struct ListDetailView: View {
    let route: ListRoute
    @Environment(ListsStore.self) private var lists
    @Environment(TraktStore.self) private var trakt
    @Environment(Library.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.cardScale) private var cardScale
    @Environment(\.dismiss) private var dismiss
    @State private var traktItems: [MediaItem] = []
    @State private var loading = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var items: [MediaItem] {
        switch route {
        case let .custom(id): return lists.list(id)?.items ?? []
        case .trakt: return traktItems
        }
    }

    private var title: String {
        switch route {
        case let .custom(id): return lists.list(id)?.name ?? "List"
        case let .trakt(list): return list.name
        }
    }

    var body: some View {
        let metrics = CardMetrics(sizeClass, scale: cardScale)
        ScrollView {
            if loading && items.isEmpty { ProgressView().padding(.top, 60) }
            if !loading && items.isEmpty {
                StateMessage(title: "Empty", message: "Long-press a title anywhere and choose Add to List.", systemImage: "list.bullet")
                    .padding(.top, 60)
            }
            LazyVGrid(columns: metrics.posterColumns, spacing: 22) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterCard(item: item, width: metrics.poster, mark: library.mark(for: item, downloads: downloads))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if case let .custom(id) = route {
                            Button(role: .destructive) { lists.toggle(item, in: id) } label: { Label("Remove from List", systemImage: "minus.circle") }
                        }
                        TitleContextMenu(item: item)
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.Backdrop())
        .navigationTitle(title)
        .toolbar {
            if case let .custom(id) = route {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newName = title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete List", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                    .alert("Rename List", isPresented: $renaming) {
                        TextField("Name", text: $newName)
                        Button("Rename") { lists.rename(id, to: newName) }
                        Button("Cancel", role: .cancel) {}
                    }
                    .confirmationDialog("Delete “\(title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            lists.delete(id)
                            dismiss()
                        }
                    }
                }
            }
        }
        .task {
            guard case let .trakt(list) = route else { return }
            loading = true
            traktItems = (try? await trakt.items(of: list)) ?? []
            loading = false
        }
    }
}
