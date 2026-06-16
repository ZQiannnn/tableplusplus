import SwiftUI

enum FormPresentation: Identifiable {
    case new
    case edit(ConnectionProfile)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let p): p.id.uuidString
        }
    }
    var profile: ConnectionProfile? {
        switch self {
        case .new: nil
        case .edit(let p): p
        }
    }
}

struct WelcomeView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(SessionStore.self) private var session
    @State private var search: String = ""
    @State private var formPresentation: FormPresentation?
    @State private var connectError: String?
    @State private var pendingDelete: ConnectionProfile?

    var filtered: [ConnectionProfile] {
        search.isEmpty
            ? store.profiles
            : store.profiles.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HSplitView {
            WelcomeSidebar(
                onCreate: { formPresentation = .new }
            )
            .frame(width: 240)

            WelcomeList(
                profiles: filtered,
                search: $search,
                onOpen: { openConnection($0, password: "") },
                onEdit: { formPresentation = .edit($0) },
                onDelete: { p in pendingDelete = p },
                onCreate: { formPresentation = .new },
                profileCount: store.profiles.count
            )
            .frame(minWidth: 420)
        }
        .sheet(item: $formPresentation) { presentation in
            ConnectionFormView(initial: presentation.profile) { profile in
                store.upsert(profile)
                formPresentation = nil
            } onCancel: {
                formPresentation = nil
            } onConnect: { profile, password in
                store.upsert(profile)
                if !password.isEmpty {
                    KeychainService.savePassword(password, for: profile.id)
                }
                formPresentation = nil
                openConnection(profile, password: password)
            }
        }
        .sheet(isPresented: Binding(
            get: { connectError != nil },
            set: { if !$0 { connectError = nil } }
        )) {
            ErrorDialog(
                title: L10n.t("welcome.connectFailed"),
                message: connectError ?? "",
                onDismiss: { connectError = nil }
            )
        }
        .sheet(item: $pendingDelete) { p in
            ConfirmDialog(
                title: L10n.t("welcome.confirmDelete"),
                message: String(format: L10n.t("welcome.confirmDeleteMsg"), p.name),
                confirmLabel: L10n.t("welcome.menuDelete"),
                destructive: true,
                onConfirm: {
                    store.remove(p.id)
                    KeychainService.deletePassword(for: p.id)
                    pendingDelete = nil
                },
                onCancel: { pendingDelete = nil }
            )
        }
    }

    private func openConnection(_ profile: ConnectionProfile, password explicit: String) {
        let pwd = explicit.isEmpty ? (KeychainService.readPassword(for: profile.id) ?? "") : explicit
        Task {
            do {
                try await session.open(profile: profile, password: pwd)
            } catch {
                await MainActor.run {
                    connectError = error.localizedDescription
                }
            }
        }
    }
}

private struct WelcomeSidebar: View {
    var onCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AppIcon(size: 72)
                .padding(.bottom, 12)

            Text("TablePlusPlus")
                .font(.system(size: 18, weight: .semibold))

            HStack(spacing: 4) {
                Text("\(L10n.t("welcome.version")) 0.1.0 · ")
                Button(L10n.t("welcome.checkUpdate")) {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.bottom, 20)

            VStack(spacing: 8) {
                Button(action: onCreate) {
                    Label(L10n.t("welcome.createConnection"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button {} label: {
                    Label(L10n.t("welcome.importOther"), systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {} label: {
                    Label(L10n.t("welcome.sampleDatabase"), systemImage: "cylinder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 16)

            Spacer()

            FooterHints()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                Color(.windowBackgroundColor)
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        )
    }
}

private struct FooterHints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.55))
                Text(L10n.t("welcome.syncOff"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Kbd("⌘N")
                Text(L10n.t("welcome.newConnection"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Kbd("⌘,")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct Kbd: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }
}

private struct WelcomeList: View {
    let profiles: [ConnectionProfile]
    @Binding var search: String
    var onOpen: (ConnectionProfile) -> Void
    var onEdit: (ConnectionProfile) -> Void
    var onDelete: (ConnectionProfile) -> Void
    var onCreate: () -> Void
    var profileCount: Int

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar — pinned to top, traffic-light reserved on left side via padding
            HStack(spacing: 10) {
                Text(L10n.t("welcome.connections"))
                    .font(.system(size: 13, weight: .semibold))
                if profileCount > 0 {
                    Text("\(profileCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                TextField(L10n.t("welcome.searchConnection"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer(minLength: 4)
                Button(action: onCreate) {
                    Image(systemName: "plus")
                }
                Button {} label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.windowBackgroundColor))

            Divider()

            if profiles.isEmpty {
                VStack {
                    Spacer()
                    Text(L10n.t("welcome.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(profiles) { p in
                            ConnectionRowView(profile: p)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onOpen(p) }
                                .contextMenu {
                                    Button(L10n.t("welcome.menuOpen")) { onOpen(p) }
                                    Button(L10n.t("welcome.menuEdit")) { onEdit(p) }
                                    Divider()
                                    Button(L10n.t("welcome.menuDelete"), role: .destructive) { onDelete(p) }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(.windowBackgroundColor))
    }
}

private struct ConnectionRowView: View {
    let profile: ConnectionProfile
    @State private var hovered: Bool = false

    var hostDescription: String {
        if let ssh = profile.ssh {
            return "\(profile.user)@\(profile.host):\(profile.port) via \(ssh.host)"
        }
        return "\(profile.host):\(profile.port)"
    }

    var body: some View {
        HStack(spacing: 12) {
            MysqlBadge()
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(hostDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovered = $0 }
    }
}

private struct MysqlBadge: View {
    var body: some View {
        AppIcon(size: 36, withShadow: false)
    }
}
