import SwiftUI

/// The composer's folder menu: the conversation's working folder on this Mac, picked among the recent ones or opened anew.
struct FolderMenu: View {
    @Bindable var store: ConversationStore
    @State private var access = FolderAccess.shared

    private var conversationId: String? { store.conversation?.id }

    var body: some View {
        Menu {
            Button { select(nil) } label: {
                if store.folder == nil { Label("No folder", systemImage: "checkmark") } else { Text("No folder") }
            }
            if !access.folders.isEmpty {
                Section("Recents") {
                    ForEach(access.folders.prefix(8)) { folder in
                        Button { select(folder) } label: {
                            if store.folder?.path == folder.path { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                        }
                        .help(folder.path)
                    }
                }
            }
            Divider()
            Button("Open a Folder…") {
                if let folder = access.choose() { select(folder) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.folder == nil ? "folder" : "folder.fill")
                if let folder = store.folder { Text(folder.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160) }
            }
            .font(.callout)
            .foregroundStyle(store.folder == nil ? Color.text2 : Color.ink)
            .frame(height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The pop-up button ignores its label's frame and sits on the composer row's baseline: a box of the same
        // height as the + button centers it on that button instead.
        .frame(height: 28)
        .help(store.folder.map { String(localized: "Working folder: \($0.path)") } ?? String(localized: "Pick a folder on this Mac for the bot"))
        .onChange(of: conversationId, initial: true) { _, id in restore(id) }
    }

    private func select(_ folder: LocalFolder?) {
        store.folder = folder?.prompt
        if let conversationId { access.assign(folder, to: conversationId) }
    }

    /// A new conversation keeps the folder picked before its first message; an existing one gets its own back.
    private func restore(_ id: String?) {
        guard let id else { return }
        if let saved = access.folder(for: id) {
            store.folder = saved.prompt
        } else if let picked = store.folder, let folder = access.folders.first(where: { $0.path == picked.path }) {
            access.assign(folder, to: id)
        }
    }
}
