import SwiftUI
import AppKit

struct WorkspaceView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ConnectionStore.self) private var connStore
    @State private var sidebarTab: SidebarTab = .items
    @State private var itemSearch: String = ""
    @State private var dbPickerOpen: Bool = false
    @State private var connPickerOpen: Bool = false
    @State private var collapsedSections: Set<String> = ["recently", "views"]
    @State private var sidebarSel = SidebarSelection()
    @State private var sidebarWidth: CGFloat = 220
    @State private var rightWidth: CGFloat = 220
    @FocusState private var searchFocused: Bool
    @FocusState private var itemsListFocused: Bool
    @Environment(PrefsStore.self) private var prefs
    private var cmds: AppCommands { .shared }

    enum SidebarTab: String, Hashable { case items, queries, history }

    private func selectItem(_ name: String) {
        session.openInTab(name)
        session.touchRecent(name)
        if let id = session.profile?.id {
            PrefsStore.shared.setLastView(connID: id, database: session.currentDatabase, table: name)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTopBar(
                tag: session.profile?.tag ?? "—",
                serverInfo: session.serverInfo ?? (session.profile?.engine.label ?? "—"),
                connectionName: session.profile?.name ?? "—",
                database: session.activeDatabase,
                table: session.activeTab,
                isReconnecting: session.isReconnecting,
                onDisconnect: { Task { await session.close() } },
                onOpenDbPicker: { dbPickerOpen = true },
                onOpenConnPicker: { connPickerOpen = true },
                onOpenSQLConsole: { sidebarTab = sidebarTab == .queries ? .items : .queries }
            )
            Divider()
            HStack(spacing: 0) {
                if !session.contexts.isEmpty {
                    databaseRail
                    Divider()
                }
                // Custom split (not HSplitView): panes abut directly (no divider, no band); the resize
                // handle is a ZERO-width overlay straddling the edge (shows a resize cursor, no paint).
                sidebar
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) {
                        PaneResizeHandle { sidebarWidth = min(max(sidebarWidth + $0, 200), 360) }.offset(x: 4)
                    }
                main
                    .frame(minWidth: 360, maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        PaneResizeHandle { rightWidth = min(max(rightWidth - $0, 200), 360) }.offset(x: 4)
                    }
                RightPanelView()
                    .frame(width: rightWidth)
            }
        }
        .background(
            Button("") {
                if session.activeTab != nil { session.closeActiveTab() }
                else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
        )
        .onChange(of: sidebarTab) { _, _ in session.clearDetail() }
        .onChange(of: cmds.focusSearch) { _, _ in
            sidebarTab = .items
            searchFocused = true
        }
        .onChange(of: cmds.openDbPicker) { _, _ in dbPickerOpen = true }
        .sheet(isPresented: Binding(
            get: { session.error != nil },
            set: { if !$0 { session.error = nil } }
        )) {
            ErrorDialog(message: session.error ?? "") {
                session.error = nil
            }
        }
        .sheet(isPresented: $dbPickerOpen) {
            DatabasePickerView(
                databases: session.databases,
                current: session.currentDatabase,
                onPick: { name in
                    dbPickerOpen = false
                    Task {
                        do { try await session.selectDatabase(name) }
                        catch { session.error = error.localizedDescription }
                    }
                },
                onCreate: { name, enc, col in
                    Task {
                        do { try await session.createDatabase(name, encoding: enc, collation: col) }
                        catch { session.error = error.localizedDescription }
                    }
                },
                onClose: { dbPickerOpen = false }
            )
        }
        .sheet(isPresented: $connPickerOpen) {
            OpenConnectionView(
                profiles: connStore.profiles,
                currentID: session.profile?.id,
                onPick: { profile in
                    connPickerOpen = false
                    let pwd = KeychainService.readPassword(for: profile.id) ?? ""
                    Task {
                        do { try await session.switchConnection(profile: profile, password: pwd) }
                        catch { session.error = error.localizedDescription }
                    }
                },
                onClose: { connPickerOpen = false }
            )
        }
    }

    private var databaseRail: some View {
        VStack(spacing: 6) {
            ForEach(session.contexts) { ctx in
                DatabaseRailItem(
                    name: ctx.database,
                    active: ctx.database == session.activeDatabase,
                    onSelect: { Task { try? await session.openOrActivateDatabase(ctx.database) } },
                    onClose: { Task { await session.closeDatabase(ctx.database) } }
                )
            }
            Button { dbPickerOpen = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.t("workspace.addDatabase"))
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 64)
        .background(Color(red: 24/255, green: 24/255, blue: 24/255))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([SidebarTab.items, .queries, .history], id: \.self) { tab in
                    Button {
                        sidebarTab = tab
                    } label: {
                        Text(L10n.t("workspace.tab.\(tab.rawValue)"))
                            .font(.system(size: 11, weight: sidebarTab == tab ? .semibold : .regular))
                            .foregroundStyle(sidebarTab == tab ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(sidebarTab == tab ? Color.primary.opacity(0.06) : .clear)
                }
            }

            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField(L10n.t("workspace.searchItem"), text: $itemSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                    Button { itemSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .opacity(itemSearch.isEmpty ? 0.35 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(itemSearch.isEmpty)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))

                Menu {
                    Toggle(L10n.t("workspace.showRecently"),   isOn: prefBinding(\.showRecently,   setter: prefs.setShowRecently))
                    Toggle(L10n.t("workspace.showFunctions"),  isOn: prefBinding(\.showFunctions,  setter: prefs.setShowFunctions))
                    Toggle(L10n.t("workspace.showViews"),      isOn: prefBinding(\.showViews,      setter: prefs.setShowViews))
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            Group {
                switch sidebarTab {
                case .items:
                    if session.currentDatabase == nil {
                        sidebarEmpty(L10n.t("workspace.noDbSelected"))
                    } else {
                        itemsTree
                    }
                case .queries:
                    if session.savedQueries.isEmpty {
                        sidebarEmpty(L10n.t("workspace.queriesHint"))
                    } else {
                        savedQueryList
                    }
                case .history:
                    if session.history.isEmpty {
                        sidebarEmpty(L10n.t("workspace.noHistory"))
                    } else {
                        historyList
                    }
                }
            }

            Spacer()
            HStack {
                Button { dbPickerOpen = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .padding(8)
                Spacer()
            }
        }
        .background(Color(red: 37/255, green: 37/255, blue: 39/255))
    }

    private func fuzzyFilter(_ items: [String]) -> [String] {
        guard !itemSearch.isEmpty else { return items }
        let scored: [(String, Int)] = items.compactMap { name in
            FuzzyMatch.score(query: itemSearch, in: name).map { (name, $0) }
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    private var filteredTables: [String]    { fuzzyFilter(session.tables) }
    private var filteredViews: [String]     { fuzzyFilter(session.views) }
    private var filteredFunctions: [String] { fuzzyFilter(session.functions) }
    private var filteredProcedures: [String]{ fuzzyFilter(session.procedures) }
    private var filteredRecent: [String]    {
        let known = Set(session.tables).union(session.views)
        return fuzzyFilter(session.recent.filter { known.contains($0) })
    }

    // The items list is an Equatable child view: per-click state (activeTab / selection / dirty)
    // is read ONLY inside row bodies, so a click re-renders the ~30 realized rows instead of
    // re-diffing the whole ForEach (20k+ tables in big schemas froze the main thread per click).
    @ViewBuilder private var itemsTree: some View {
        SidebarItemsList(
            showRecently: prefs.showRecently,
            showFunctions: prefs.showFunctions,
            showViews: prefs.showViews,
            expandedRecently: !collapsedSections.contains("recently"),
            expandedFunctions: !collapsedSections.contains("functions"),
            expandedViews: !collapsedSections.contains("views"),
            expandedTables: !collapsedSections.contains("tables"),
            recentItems: prefs.showRecently ? filteredRecent : [],
            functionItems: prefs.showFunctions ? filteredFunctions : [],
            procedureItems: prefs.showFunctions ? filteredProcedures : [],
            viewItems: prefs.showViews ? filteredViews : [],
            tableItems: filteredTables,
            sel: sidebarSel,
            onToggle: { key in
                if collapsedSections.contains(key) { collapsedSections.remove(key) } else { collapsedSections.insert(key) }
            },
            onTap: handleSidebarTap,
            onCopy: copySidebarSelection(clicked:)
        )
        .equatable()
        .focusable()
        .focused($itemsListFocused)
        .onKeyPress { press in
            guard press.key == "c", press.modifiers.contains(.command) else { return .ignored }
            copyCurrentSidebarSelection()
            return .handled
        }
        .onChange(of: session.restoredTable) { _, restored in
            if let r = restored, session.tables.contains(r) || session.views.contains(r) {
                session.openInTab(r)
            }
        }
        .onAppear {
            if let r = session.restoredTable, (session.tables.contains(r) || session.views.contains(r)) {
                session.openInTab(r)
            }
        }
    }

    /// Items in the same top-to-bottom order they appear in the tree (for shift-range selection).
    private var flatVisibleItems: [String] {
        var out: [String] = []
        if prefs.showRecently && !collapsedSections.contains("recently") { out += filteredRecent }
        if prefs.showFunctions && !collapsedSections.contains("functions") { out += filteredFunctions + filteredProcedures }
        if prefs.showViews && !collapsedSections.contains("views") { out += filteredViews }
        if !collapsedSections.contains("tables") { out += filteredTables }
        return out
    }

    private func handleSidebarTap(_ name: String) {
        itemsListFocused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if sidebarSel.items.contains(name) { sidebarSel.items.remove(name) } else { sidebarSel.items.insert(name) }
            sidebarSel.anchor = name
        } else if mods.contains(.shift), let anchor = sidebarSel.anchor ?? session.activeTab {
            let flat = flatVisibleItems
            if let a = flat.firstIndex(of: anchor), let b = flat.firstIndex(of: name) {
                sidebarSel.items = Set(flat[min(a, b)...max(a, b)])
            } else {
                sidebarSel.items = [name]
            }
        } else {
            sidebarSel.items = [name]
            sidebarSel.anchor = name
            selectItem(name)
        }
    }

    /// Right-click target set: the multi-selection if the clicked row is part of it, else just that row.
    private func effectiveSelection(clicked name: String) -> [String] {
        if sidebarSel.items.contains(name) && sidebarSel.items.count > 1 {
            return flatVisibleItems.filter { sidebarSel.items.contains($0) }
        }
        return [name]
    }

    private func copySidebarSelection(clicked name: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(effectiveSelection(clicked: name).joined(separator: ", "), forType: .string)
    }

    /// ⌘C in the items list: copy the current selection (ordered), falling back to the open table.
    private func copyCurrentSidebarSelection() {
        var names = flatVisibleItems.filter { sidebarSel.items.contains($0) }
        if names.isEmpty { names = sidebarSel.items.isEmpty ? [session.activeTab].compactMap { $0 } : Array(sidebarSel.items) }
        guard !names.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(names.joined(separator: ", "), forType: .string)
    }

    private func prefBinding(_ kp: KeyPath<PrefsStore, Bool>, setter: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(
            get: { prefs[keyPath: kp] },
            set: { setter($0) }
        )
    }

    @ViewBuilder private var main: some View {
        VStack(spacing: 0) {
            Group {
                if sidebarTab == .queries {
                    QueryEditorView()
                } else {
                    tableMain
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            consolePanel
        }
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
    }

    /// Shared SQL execution log, pinned to the bottom in both table and query modes.
    private var consolePanel: some View {
        Group {
            if session.consoleLog.isEmpty {
                Text(L10n.t("workspace.consoleLog"))
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SQLHighlightView(text: session.consoleText, scrollsToEnd: true)
            }
        }
        .frame(height: 150)
        .background(Color(red: 24/255, green: 24/255, blue: 24/255))
    }

    private var tableMain: some View {
        VStack(spacing: 0) {
            if let table = session.activeTab {
                tabBar
                Divider()
                TableViewerView(table: table)
            } else if session.currentDatabase == nil {
                VStack(spacing: 8) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(L10n.t("workspace.noDbSelected"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button(L10n.t("workspace.selectButton")) { dbPickerOpen = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(L10n.t("workspace.chooseTable"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
    }

    private var activeTabIndex: Int? {
        session.activeTab.flatMap { session.openTabs.firstIndex(of: $0) }
    }

    @ViewBuilder private func tabMenu(_ name: String) -> some View {
        let idx = session.openTabs.firstIndex(of: name)
        let count = session.openTabs.count
        Button(L10n.t("tab.close")) { session.closeTab(name) }
        Button(L10n.t("tab.closeOthers")) { session.closeOtherTabs(name) }
            .disabled(count <= 1)
        Button(L10n.t("tab.closeLeft")) { session.closeTabsToLeft(name) }
            .disabled((idx ?? 0) <= 0)
        Button(L10n.t("tab.closeRight")) { session.closeTabsToRight(name) }
            .disabled(idx == nil || idx! >= count - 1)
        Button(L10n.t("tab.closeAll")) { session.closeAllTabs() }
        Divider()
        Button(L10n.t("sidebar.copyName")) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(name, forType: .string)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            Button { session.selectAdjacentTab(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.trailing, 4)
            .disabled((activeTabIndex ?? 0) <= 0)

            Button { session.selectAdjacentTab(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.trailing, 6)
            .disabled(activeTabIndex.map { $0 >= session.openTabs.count - 1 } ?? true)

            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 18)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(session.openTabs, id: \.self) { name in
                            TabChip(
                                name: name,
                                active: session.activeTab == name,
                                onSelect: { session.selectTab(name) },
                                onClose: { session.closeTab(name) }
                            )
                            .id(name)
                            .contextMenu { tabMenu(name) }
                        }
                    }
                }
                .onChange(of: session.activeTab) { _, new in
                    if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
                }
            }

            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 18)

            Menu {
                ForEach(session.openTabs, id: \.self) { name in
                    Button {
                        session.selectTab(name)
                    } label: {
                        if session.activeTab == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .foregroundStyle(.secondary)
            .help(L10n.t("workspace.allTabs"))
        }
        .frame(height: 32)
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(session.history) { rec in
                    Button {
                        session.editorSQL = rec.sql
                        sidebarTab = .queries
                    } label: {
                        HistoryRow(record: rec)
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private var savedQueryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(session.savedQueries) { rec in
                    Button {
                        session.openSavedQuery(rec)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 0/255, green: 117/255, blue: 143/255))
                            Text(rec.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L10n.t("common.delete"), role: .destructive) { session.deleteSavedQuery(rec) }
                    }
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func sidebarEmpty(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DatabaseRailItem: View {
    let name: String
    let active: Bool
    var onSelect: () -> Void
    var onClose: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 3) {
            AppIcon(size: 22, cornerRatio: 0.25, glyphRatio: 0.55, withShadow: false)
                .opacity(active ? 1 : 0.5)
            Text(name)
                .font(.system(size: 8))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(active ? .primary : .secondary)
                .frame(width: 56)
        }
        .frame(width: 60, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active ? Color.white.opacity(0.10) : (hovered ? Color.white.opacity(0.05) : .clear))
        )
        .overlay(alignment: .topTrailing) {
            if hovered, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .help(name)
    }
}

private struct TabChip: View {
    let name: String
    let active: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hovered = false

    private static let accent = Color(red: 0.00, green: 0.46, blue: 0.56)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tablecells")
                .font(.system(size: 10))
                .foregroundStyle(active ? Self.accent : .secondary)
            Text(name)
                .font(.system(size: 11, weight: active ? .medium : .regular))
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered || active ? 0.8 : 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(
            ZStack(alignment: .top) {
                if active {
                    Color.white.opacity(0.10)
                    Rectangle().fill(Self.accent).frame(height: 2)
                } else if hovered {
                    Color.white.opacity(0.05)
                }
            }
        )
        .overlay(Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 18), alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
    }
}

/// Invisible 6pt-wide vertical splitter: no drawn line, shows a resize cursor on hover, drags to
/// resize the adjacent pane. Replaces HSplitView's non-hideable divider.
private struct PaneResizeHandle: View {
    var onDrag: (CGFloat) -> Void
    @State private var lastX: CGFloat = 0

    var body: some View {
        Color.clear   // overlay-only: no paint (panes abut directly), just a hit area + resize cursor
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { v in
                        if lastX == 0 { lastX = v.startLocation.x }
                        onDrag(v.location.x - lastX)
                        lastX = v.location.x
                    }
                    .onEnded { _ in lastX = 0 }
            )
    }
}

private struct QueryTabChip: View {
    let name: String
    let active: Bool
    let editing: Bool
    @Binding var editingName: String
    let canClose: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onBeginRename: () -> Void
    var onCommitRename: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    private static let accent = Color(red: 0.00, green: 0.46, blue: 0.56)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(active ? Self.accent : .secondary)
            if editing {
                TextField("", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 72)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit(onCommitRename)
                    .onChange(of: focused) { _, f in if !f { onCommitRename() } }
            } else {
                Text(name)
                    .font(.system(size: 11, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered || active ? 0.8 : 0)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        // Hover wash fills the chip; active = teal bar pinned to the TOP edge (overlay, so it can't
        // collapse-and-center into a strikethrough).
        .background((hovered && !active) ? Color.white.opacity(0.05) : Color.clear)
        .overlay(alignment: .top) {
            if active { Rectangle().fill(Self.accent).frame(height: 2) }
        }
        .overlay(Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 18), alignment: .trailing)
        .contentShape(Rectangle())
        // Single tap must fire immediately: chaining it after onTapGesture(count: 2) makes SwiftUI
        // hold every click for the double-tap timeout. Simultaneous recognition removes that wait.
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onBeginRename))
        .onHover { hovered = $0 }
    }
}

private struct HistoryRow: View {
    let record: QueryHistoryRecord
    @State private var hovered = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: record.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(record.ok ? .green : .red)
                Text(Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(record.executed_at))))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let ms = record.duration_ms {
                    Text("\(ms) ms")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(record.sql)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

struct QueryEditorView: View {
    @Environment(SessionStore.self) private var session
    @State private var cursorLine = 1
    @State private var cursorColumn = 1
    @State private var cursorLocation = 0
    @State private var selectedSQL = ""
    @State private var resultTab: ResultTab = .data
    @State private var editingTabID: UUID?
    @State private var editingName = ""
    @State private var saveTask: Task<Void, Never>?
    private var cmds: AppCommands { .shared }

    enum ResultTab: Hashable { case data, message, chart }

    private static let limitOptions: [Int?] = [nil, 50, 100, 300, 500, 1000]

    private var sqlEmpty: Bool {
        session.editorSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runAll() {
        guard !session.anyQueryRunning, !sqlEmpty else { return }
        Task { await session.runQuery(session.editorSQL) }
    }

    private var hasSelection: Bool {
        !selectedSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runCurrent() {
        guard !session.anyQueryRunning else { return }
        if hasSelection {
            let stmts = SQLTools.statements(in: selectedSQL).map(\.sql)
            guard !stmts.isEmpty else { return }
            Task { await session.runStatements(stmts) }
            return
        }
        guard let stmt = SQLTools.statement(in: session.editorSQL, at: cursorLocation) else { return }
        Task { await session.runStatements([stmt.sql]) }
    }

    private func beautify() {
        guard !sqlEmpty else { return }
        session.editorSQL = SQLTools.beautify(session.editorSQL)
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                queryTabBar
                Divider()
                if session.queryTabs.isEmpty {
                    newTabPrompt
                } else {
                    SQLEditorView(
                        text: Binding(
                            get: { session.editorSQL },
                            set: { session.editorSQL = $0 }
                        ),
                        completionItems: {
                            session.tables.map { CompletionItem(text: $0, kind: .table) }
                            + session.views.map { CompletionItem(text: $0, kind: .view) }
                            + (session.activeTabState?.tableColumns ?? []).map { CompletionItem(text: $0, kind: .column) }
                        },
                        onCursor: { line, col, loc in
                            cursorLine = line; cursorColumn = col; cursorLocation = loc
                        },
                        onSelectionChange: { selectedSQL = $0 },
                        onRunCurrent: { runCurrent() },
                        onBeautify: { beautify() },
                        onSave: {
                            if let tab = session.activeContext?.activeQueryTab { saveQueryTab(tab) }
                        }
                    )
                    Divider()
                    statusBar
                }
            }
            .frame(minHeight: 130, idealHeight: 200)

            VStack(spacing: 0) {
                if session.queryPages.count > 1 {
                    pageTabs
                    Divider()
                }
                resultArea
                if let page = session.currentQueryPage, page.isEditable, page.hasQueryEdits {
                    Divider()
                    queryEditBar(page)
                }
                Divider()
                resultFooter
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
        .onChange(of: cmds.runOrRefresh) { _, _ in runAll() }
        .onChange(of: session.activeQueryPage) { _, _ in syncResultTab() }
        .onChange(of: session.currentQueryPage?.running) { _, _ in syncResultTab() }
        .onChange(of: session.editorSQL) { _, _ in scheduleSave() }
    }

    /// Debounced persist of the active tab's draft SQL (so a restart keeps unsaved drafts).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            session.persistActiveQueryTab()
        }
    }

    private var activeQueryTabIndex: Int? {
        session.activeQueryTabID.flatMap { id in session.queryTabs.firstIndex(where: { $0.id == id }) }
    }

    @ViewBuilder private func queryTabMenu(_ tab: QueryTabState) -> some View {
        let idx = session.queryTabs.firstIndex(where: { $0.id == tab.id })
        let count = session.queryTabs.count
        Button(L10n.t("tab.rename")) {
            editingName = tab.name
            editingTabID = tab.id
        }
        Button(L10n.t("tab.saveQuery")) { saveQueryTab(tab) }
            .disabled(tab.editorSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Divider()
        Button(L10n.t("tab.close")) { session.closeQueryTab(tab.id) }
        Button(L10n.t("tab.closeOthers")) { session.closeOtherQueryTabs(tab.id) }
            .disabled(count <= 1)
        Button(L10n.t("tab.closeLeft")) { session.closeQueryTabsToLeft(tab.id) }
            .disabled((idx ?? 0) <= 0)
        Button(L10n.t("tab.closeRight")) { session.closeQueryTabsToRight(tab.id) }
            .disabled(idx == nil || idx! >= count - 1)
        Button(L10n.t("tab.closeAll")) { session.closeAllQueryTabs() }
    }

    private func saveQueryTab(_ tab: QueryTabState) {
        let sql = tab.editorSQL
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let alert = NSAlert()
        let iconRenderer = ImageRenderer(content: AppIcon(size: 64, withShadow: false).frame(width: 64, height: 64))
        iconRenderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        alert.icon = iconRenderer.nsImage
        alert.messageText = L10n.t("tab.saveQuery")
        alert.addButton(withTitle: L10n.t("common.save"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.saveQuery(name: field.stringValue, sql: sql)
    }

    private var queryTabBar: some View {
        HStack(spacing: 0) {
            Button { session.selectAdjacentQueryTab(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.trailing, 4)
            .disabled((activeQueryTabIndex ?? 0) <= 0)

            Button { session.selectAdjacentQueryTab(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.trailing, 6)
            .disabled(activeQueryTabIndex.map { $0 >= session.queryTabs.count - 1 } ?? true)

            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 18)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(session.queryTabs) { tab in
                            QueryTabChip(
                                name: tab.name,
                                active: session.activeQueryTabID == tab.id,
                                editing: editingTabID == tab.id,
                                editingName: $editingName,
                                canClose: true,
                                onSelect: { session.selectQueryTab(tab.id) },
                                onClose: { session.closeQueryTab(tab.id) },
                                onBeginRename: { editingName = tab.name; editingTabID = tab.id },
                                onCommitRename: {
                                    session.renameQueryTab(tab.id, name: editingName)
                                    editingTabID = nil
                                }
                            )
                            .id(tab.id)
                            .contextMenu { queryTabMenu(tab) }
                        }

                        Button { session.addQueryTab() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("query.newTab"))

                        Spacer(minLength: 0)
                    }
                }
                .onChange(of: session.activeQueryTabID) { _, new in
                    if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
                }
            }

            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 18)

            Menu {
                ForEach(session.queryTabs) { tab in
                    Button {
                        session.selectQueryTab(tab.id)
                    } label: {
                        if session.activeQueryTabID == tab.id {
                            Label(tab.name, systemImage: "checkmark")
                        } else {
                            Text(tab.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .foregroundStyle(.secondary)
            .help(L10n.t("workspace.allTabs"))
        }
        .frame(height: 32)
        .background(DataGrid.bgChrome)
    }

    private var newTabPrompt: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Button { session.addQueryTab() } label: {
                Text(L10n.t("workspace.newTabPrompt"))
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0/255, green: 117/255, blue: 143/255))
            .controlSize(.regular)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 30/255, green: 30/255, blue: 30/255))
    }

    /// Show Message for statements that returned no result set (INSERT/UPDATE/DDL), else Data.
    private func syncResultTab() {
        guard resultTab != .chart, let page = session.currentQueryPage, !page.running else { return }
        if page.columns.isEmpty && page.error == nil {
            resultTab = .message
        } else if resultTab == .message && (!page.columns.isEmpty || page.error != nil) {
            resultTab = .data
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(String(format: L10n.t("query.cursor"), cursorLine, cursorColumn, cursorLocation))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            if session.queryRunning { ProgressView().controlSize(.small) }

            Menu {
                ForEach(Array(Self.limitOptions.enumerated()), id: \.offset) { _, opt in
                    Button {
                        session.queryLimit = opt
                    } label: {
                        if session.queryLimit == opt {
                            Label(limitLabel(opt), systemImage: "checkmark")
                        } else {
                            Text(limitLabel(opt))
                        }
                    }
                }
            } label: {
                Text(limitLabel(session.queryLimit))
                    .font(.system(size: 12))
            }
            .menuStyle(.borderedButton)
            .controlSize(.regular)
            .tint(.secondary)
            .fixedSize()

            Menu {
                Button("\(L10n.t("query.beautify")) ⌘I") { beautify() }
            } label: {
                Text("\(L10n.t("query.beautify")) ⌘I")
                    .font(.system(size: 12))
            } primaryAction: {
                beautify()
            }
            .menuStyle(.borderedButton)
            .controlSize(.regular)
            .fixedSize()
            .disabled(sqlEmpty)

            if session.queryRunning {
                Button {
                    session.cancelQuery()
                } label: {
                    Text("\(L10n.t("query.cancel")) ⌘.")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Menu {
                    Button("\(L10n.t("query.runAll")) ⌘R") { runAll() }
                } label: {
                    Text("\(L10n.t(hasSelection ? "query.runSelected" : "query.runCurrent")) ⌘↩")
                        .font(.system(size: 12))
                        .fontWeight(.medium)
                } primaryAction: {
                    runCurrent()
                }
                .menuStyle(.borderedButton)
                .controlSize(.regular)
                .tint(Color(red: 0/255, green: 117/255, blue: 143/255))
                .fixedSize()
                .disabled(sqlEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DataGrid.bgChrome)
    }

    private var resultFooter: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                footerTab(L10n.t("query.tabData"), .data)
                footerTab(L10n.t("query.tabMessage"), .message)
                footerTab(L10n.t("query.tabChart"), .chart)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))

            if let page = session.currentQueryPage {
                if page.running {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(String(format: "%@ %.1fs", L10n.t("query.fetching"), page.elapsed))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(String(format: "%.3f s", page.elapsed))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(rowsLabel(page))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                exportCurrentPage()
            } label: {
                Label(L10n.t("query.export"), systemImage: "square.and.arrow.up")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(session.currentQueryPage?.rows.isEmpty ?? true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DataGrid.bgChrome)
    }

    private func queryEditBar(_ page: QueryPage) -> some View {
        HStack(spacing: 8) {
            Button { session.focusFirstQueryEdit() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.86, green: 0.52, blue: 0.10))
                    Text(String(format: L10n.t("query.editPending"), page.queryEdits.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("query.locateEdit"))
            Spacer()
            Button { session.discardQueryEdits() } label: {
                Label(L10n.t("edit.discard"), systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(page.committingEdits)

            Button {
                Task { if let err = await session.commitQueryEdits() { session.error = err } }
            } label: {
                Label(L10n.t("edit.commit"), systemImage: "checkmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(page.committingEdits)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DataGrid.bgChrome)
    }

    private func footerTab(_ title: String, _ tab: ResultTab) -> some View {
        Button { resultTab = tab } label: {
            Text(title)
                .font(.system(size: 11, weight: resultTab == tab ? .semibold : .regular))
                .foregroundStyle(resultTab == tab ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(resultTab == tab ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowsLabel(_ page: QueryPage) -> String {
        if page.columns.isEmpty, let a = page.rowsAffected {
            return String(format: L10n.t("query.rowsAffected"), a)
        }
        let f = NumberFormatter(); f.numberStyle = .decimal
        let n = f.string(from: NSNumber(value: page.rows.count)) ?? "\(page.rows.count)"
        return String(format: L10n.t("query.rows"), n)
    }

    private func exportCurrentPage() {
        guard let page = session.currentQueryPage, !page.rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "query_result.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = page.columns.map(csvField).joined(separator: ",") + "\n"
        for row in page.rows {
            csv += page.columns.map { csvField(row.string($0) ?? "") }.joined(separator: ",") + "\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private func limitLabel(_ n: Int?) -> String {
        n.map { "Limit \($0)" } ?? L10n.t("query.noLimit")
    }

    private var pageTabs: some View {
        HStack(spacing: 0) {
            ForEach(Array(session.queryPages.enumerated()), id: \.element.id) { i, page in
                Button {
                    session.activeQueryPage = i
                    session.clearDetail()
                } label: {
                    HStack(spacing: 4) {
                        if page.error != nil {
                            Circle().fill(.red).frame(width: 5, height: 5)
                        }
                        Text("Query \(i + 1)")
                            .font(.system(size: 11, weight: i == session.activeQueryPage ? .semibold : .regular))
                            .foregroundStyle(i == session.activeQueryPage ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(i == session.activeQueryPage ? Color.white.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1), alignment: .trailing)
            }
        }
        .background(DataGrid.bgChrome)
    }

    @ViewBuilder private var resultArea: some View {
        switch resultTab {
        case .message:
            messagePanel
        case .chart:
            chartPanel
        case .data:
            dataPanel
        }
    }

    @ViewBuilder private var dataPanel: some View {
        if let page = session.currentQueryPage {
            if let err = page.error {
                ScrollView {
                    Text(err)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if page.columns.isEmpty {
                VStack {
                    Text("Query \(pageNumber(page)) \(page.message ?? "OK")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Spacer()
                }
            } else {
                AppKitDataGrid(
                    columns: page.columns,
                    rows: page.rows,
                    dataKey: "q\(page.id)|\(page.rows.count)|\(page.running ? 1 : 0)|\(page.editsVersion)",
                    selectionKey: "q\(page.id)",
                    onSelect: { i in
                        if let i { session.showQueryRowDetail(i) } else { session.clearDetail() }
                    },
                    editable: page.isEditable,
                    focusToken: session.queryFocusToken,
                    focusRow: session.queryFocusRow,
                    editOverride: page.isEditable ? { r, c in session.queryEditOverride(row: r, column: c) } : nil,
                    onEditCommit: page.isEditable ? { r, c, v in session.setQueryEdit(row: r, column: c, newValue: v) } : nil
                )
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(L10n.t("query.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var messagePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(session.queryPages.enumerated()), id: \.element.id) { i, page in
                    HStack(alignment: .top, spacing: 6) {
                        Text("Query \(i + 1)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let err = page.error {
                            Text(err)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.red)
                        } else {
                            Text(messageFor(page))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 24/255, green: 24/255, blue: 24/255))
    }

    private func messageFor(_ page: QueryPage) -> String {
        if let m = page.message { return m }
        if page.running { return "Running…" }
        return page.columns.isEmpty ? "OK" : "\(page.rows.count) rows"
    }

    private var chartPanel: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(L10n.t("query.chartSoon"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pageNumber(_ page: QueryPage) -> Int {
        (session.queryPages.firstIndex(where: { $0.id == page.id }) ?? 0) + 1
    }
}

private struct RightPanelView: View {
    @Environment(SessionStore.self) private var session
    @State private var detailsTab: DetailsTab = .details
    @State private var fieldSearch: String = ""
    enum DetailsTab: Hashable { case details, assistant }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                pillTab(L10n.t("workspace.details"),  isOn: detailsTab == .details)   { detailsTab = .details }
                pillTab(L10n.t("workspace.assistant"), isOn: detailsTab == .assistant) { detailsTab = .assistant }
            }
            .padding(.vertical, 6)

            HStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField(L10n.t("workspace.searchField"), text: $fieldSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    Button { fieldSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .opacity(fieldSearch.isEmpty ? 0.35 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(fieldSearch.isEmpty)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            if session.detailFields.isEmpty {
                VStack {
                    Spacer()
                    Text(L10n.t("workspace.noRowSelected"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                detailList
            }
        }
        .background(Color(red: 37/255, green: 37/255, blue: 39/255))
    }

    private var detailList: some View {
        let visible = fieldSearch.isEmpty
            ? session.detailFields
            : session.detailFields.filter { $0.label.localizedCaseInsensitiveContains(fieldSearch) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(visible) { detailFieldRow($0) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func detailFieldRow(_ f: DetailField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if f.isKey {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.0))
                }
                Text(f.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let tag = f.tag, !tag.isEmpty {
                    Text(displayType(tag))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.10)))
                }
            }
            if let row = session.detailEditableRow, session.detailEditableColumn(f.label) {
                DetailValueField(row: row, column: f.label)
                    .id("\(row)|\(f.label)")
            } else {
                Group {
                    if let v = f.value, !v.isEmpty {
                        Text(v)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    } else {
                        Text(f.value == nil ? "NULL" : "EMPTY")
                            .font(.system(size: 11).italic())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
                .contextMenu {
                    Button(L10n.t("menu.copy")) { copyToPasteboard(f.value ?? "") }
                        .disabled(f.value == nil)
                    Button(L10n.t("detail.copyFieldName")) { copyToPasteboard(f.label) }
                }
            }
        }
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// AppKit-backed editable detail field. A SwiftUI TextField's `.contextMenu`, and even an
    /// NSTextField's `menu(for:)`, are shadowed by the field-editor's native menu. NSTextView's own
    /// `menu(for:)` IS consulted (even while editing), so we wrap one — keeping multiline + dark style
    /// and appending the value-semantics items (Set NULL / Set Empty / Revert) to the native edit menu.
    private struct DetailValueField: NSViewRepresentable {
        let row: Int
        let column: String

        func makeCoordinator() -> Coordinator { Coordinator(row: row, column: column) }

        func makeNSView(context: Context) -> NSScrollView {
            let tv = MenuTextView()
            tv.coordinator = context.coordinator
            tv.delegate = context.coordinator
            tv.isRichText = false
            tv.isEditable = true
            tv.isSelectable = true
            tv.allowsUndo = true
            tv.font = .systemFont(ofSize: 11)
            tv.textColor = .labelColor
            tv.drawsBackground = true
            tv.textContainerInset = NSSize(width: 4, height: 4)
            tv.textContainer?.lineFragmentPadding = 2
            tv.textContainer?.widthTracksTextView = true
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.autoresizingMask = [.width]
            tv.minSize = NSSize(width: 0, height: 0)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

            let scroll = NSScrollView()
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 5
            scroll.layer?.masksToBounds = true
            context.coordinator.field = tv
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let tv = scroll.documentView as? MenuTextView else { return }
            context.coordinator.row = row
            context.coordinator.column = column
            context.coordinator.field = tv
            let s = SessionStore.shared
            if tv.window?.firstResponder !== tv {   // don't stomp the value mid-edit
                tv.string = s.fieldDisplayValue(row: row, column: column)
            }
            let bg = s.fieldHasEdit(row: row, column: column)
                ? NSColor(srgbRed: 0.42, green: 0.30, blue: 0.10, alpha: 1)
                : NSColor(white: 1, alpha: 0.06)
            tv.backgroundColor = bg
            scroll.backgroundColor = bg
            scroll.drawsBackground = true
        }

        // Grow with content; cap at ~360pt and let longer content scroll internally.
        func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
            let width = proposal.width ?? 240
            guard let tv = scroll.documentView as? MenuTextView,
                  let container = tv.textContainer, let lm = tv.layoutManager else { return nil }
            container.containerSize = NSSize(width: max(width - 8, 20), height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: container)
            let used = lm.usedRect(for: container).height
            return CGSize(width: width, height: min(max(used + 12, 24), 360))
        }

        @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
            var row: Int
            var column: String
            weak var field: MenuTextView?
            private var editingInitial: String?
            init(row: Int, column: String) { self.row = row; self.column = column }

            func textDidBeginEditing(_ notification: Notification) {
                editingInitial = field?.string
            }

            func textDidEndEditing(_ notification: Notification) {
                // Row-aware (coordinator.row), never writes to a since-changed detailEditableRow.
                // Unchanged ⇒ don't record an edit (focusing a NULL field then leaving keeps it NULL).
                let value = field?.string ?? ""
                guard let initial = editingInitial, value != initial else { return }
                SessionStore.shared.setCellValue(row: row, column: column, newValue: value)
            }

            /// Concise field menu (NSTextView's native menu carries too much rich-text noise).
            func buildMenu() -> NSMenu {
                let m = NSMenu()
                func add(_ key: String, _ sel: Selector, enabled: Bool = true) {
                    let it = NSMenuItem(title: L10n.t(key), action: sel, keyEquivalent: "")
                    it.target = self; it.isEnabled = enabled; m.addItem(it)
                }
                add("menu.copy", #selector(menuCopy))
                add("menu.paste", #selector(menuPaste))
                m.addItem(.separator())
                add("menu.setNull", #selector(menuSetNull))
                add("menu.setEmpty", #selector(menuSetEmpty))
                add("menu.revertField", #selector(menuRevert),
                    enabled: SessionStore.shared.fieldHasEdit(row: row, column: column))
                return m
            }

            @objc private func menuCopy() {
                let pb = NSPasteboard.general; pb.clearContents(); pb.setString(field?.string ?? "", forType: .string)
            }
            @objc private func menuPaste() {
                guard let s = NSPasteboard.general.string(forType: .string) else { return }
                field?.string = s
                SessionStore.shared.setCellValue(row: row, column: column, newValue: s)
            }
            @objc private func menuSetNull()  { field?.string = ""; SessionStore.shared.setCellValue(row: row, column: column, newValue: nil) }
            @objc private func menuSetEmpty() { field?.string = ""; SessionStore.shared.setCellValue(row: row, column: column, newValue: "") }
            @objc private func menuRevert() {
                SessionStore.shared.revertField(column: column)
                field?.string = SessionStore.shared.fieldDisplayValue(row: row, column: column)
            }
        }
    }

    private final class MenuTextView: NSTextView {
        weak var coordinator: DetailValueField.Coordinator?
        // Present manually with popUp (not popUpContextMenu) so AppKit doesn't append AutoFill /
        // Services, and opt out of the Services menu via validRequestor.
        override func rightMouseDown(with event: NSEvent) {
            guard let menu = coordinator?.buildMenu() else { return super.rightMouseDown(with: event) }
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }
        override func menu(for event: NSEvent) -> NSMenu? { coordinator?.buildMenu() }
        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                     returnType: NSPasteboard.PasteboardType?) -> Any? { nil }
    }

    private func displayType(_ raw: String) -> String {
        switch raw {
        case "tiny", "short", "long", "longlong", "int24", "year", "bit", "decimal", "float", "double": return "number"
        case "string", "var_string", "varchar", "char": return "string"
        case "date", "time", "datetime", "timestamp":     return "date"
        case "blob", "tiny_blob", "medium_blob", "long_blob": return "blob"
        case "":  return ""
        default:  return raw
        }
    }

    private func pillTab(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.primary.opacity(0.13) : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceTopBar: View {
    let tag: String
    let serverInfo: String
    let connectionName: String
    var database: String? = nil
    var table: String? = nil
    var isReconnecting: Bool = false
    var onDisconnect: () -> Void
    var onOpenDbPicker: () -> Void
    var onOpenConnPicker: () -> Void
    var onOpenSQLConsole: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                TopBarIconButton(icon: "power", help: L10n.t("workspace.disconnect"), action: onDisconnect)
                TopBarIconButton(icon: "powerplug", help: L10n.t("workspace.openConnection"), action: onOpenConnPicker)
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 14)
                TopBarIconButton(icon: "cylinder", help: L10n.t("workspace.selectDb"), action: onOpenDbPicker)
                TopBarIconButton(icon: "terminal", help: L10n.t("workspace.sqlConsole"), action: onOpenSQLConsole)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            if isReconnecting {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("workspace.reconnecting"))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Text(tag.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: 10)
                Text(serverInfo)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(":")
                    .foregroundStyle(.secondary)
                Text(connectionName)
                    .font(.system(size: 11, weight: .medium))
                if let database {
                    Text(":").foregroundStyle(.secondary)
                    Text(database)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let table {
                    Text(":").foregroundStyle(.secondary)
                    Text(table)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct TopBarIconButton: View {
    let icon: String
    let help: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 26, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovered ? Color.white.opacity(0.10) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct OpenConnectionView: View {
    let profiles: [ConnectionProfile]
    let currentID: UUID?
    var onPick: (ConnectionProfile) -> Void
    var onClose: () -> Void

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0

    private var filtered: [ConnectionProfile] {
        query.isEmpty
            ? profiles
            : profiles.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.host.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.t("workspace.openConnection"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.vertical, 10)
            HStack(spacing: 6) {
                KeyNavField(
                    text: $query,
                    placeholder: L10n.t("conn.search"),
                    onMoveUp: { moveSelection(-1) },
                    onMoveDown: { moveSelection(1) },
                    onEnter: { pickSelected() },
                    onCancel: onClose
                )
                .frame(height: 22)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, p in
                            ConnectionPickRow(profile: p, isCurrent: p.id == currentID, isSelected: i == selectedIndex) {
                                selectedIndex = i
                                onPick(p)
                            }
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedIndex) { _, i in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
        .frame(width: 460, height: 440)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), filtered.count - 1)
    }

    private func pickSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        onPick(filtered[selectedIndex])
    }
}

private struct ConnectionPickRow: View {
    let profile: ConnectionProfile
    let isCurrent: Bool
    var isSelected: Bool = false
    var onTap: () -> Void
    @State private var hovered = false

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.30) }
        return hovered ? Color.primary.opacity(0.08) : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(red: 0.97, green: 0.55, blue: 0.07))
                Text(String(profile.engine.label.prefix(2)))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(profile.name)
                        .font(.system(size: 12, weight: .medium))
                    if !profile.tag.isEmpty {
                        Text("(\(profile.tag))")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                }
                Text(profile.host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovered = $0 }
    }
}

private struct DatabasePickerView: View {
    let databases: [String]
    let current: String?
    var onPick: (String) -> Void
    var onCreate: (String, String?, String?) -> Void
    var onClose: () -> Void

    @State private var query: String = ""
    @State private var creating: Bool = false
    @State private var selectedIndex: Int = 0

    var filtered: [String] {
        query.isEmpty
            ? databases
            : databases.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("workspace.selectButton"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button(L10n.t("db.close"), action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 6) {
                KeyNavField(
                    text: $query,
                    placeholder: L10n.t("db.search"),
                    onMoveUp: { moveSelection(-1) },
                    onMoveDown: { moveSelection(1) },
                    onEnter: { pickSelected() },
                    onCancel: onClose
                )
                .frame(height: 22)
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(L10n.t("db.createTooltip"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { i, name in
                            DatabaseRow(name: name, isCurrent: name == current, isSelected: i == selectedIndex) {
                                selectedIndex = i
                                onPick(name)
                            }
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedIndex) { _, i in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
        .frame(width: 360, height: 420)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .sheet(isPresented: $creating) {
            NewDatabaseSheet(
                onCreate: { name, enc, col in
                    creating = false
                    onCreate(name, enc, col)
                },
                onCancel: { creating = false }
            )
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), filtered.count - 1)
    }

    private func pickSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        onPick(filtered[selectedIndex])
    }
}

/// Single-line text field that reports arrow-up/down, Enter and Escape so a list can be driven
/// from the keyboard while focus stays in the field. Auto-focuses when it appears.
private struct KeyNavField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onEnter: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.delegate = context.coordinator
        tf.placeholderString = placeholder
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.font = .systemFont(ofSize: 12)
        tf.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        DispatchQueue.main.async { [weak tf] in tf?.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if tf.stringValue != text { tf.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyNavField
        init(_ p: KeyNavField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)):          parent.onMoveUp();   return true
            case #selector(NSResponder.moveDown(_:)):        parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)):   parent.onEnter();    return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel();   return true
            default: return false
            }
        }
    }
}

private struct NewDatabaseSheet: View {
    var onCreate: (String, String?, String?) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var encoding: String = "Default"
    @State private var collation: String = "Default"

    private let encodings = ["Default", "utf8mb4", "utf8", "latin1", "ascii", "gbk"]
    private let collations = ["Default", "utf8mb4_unicode_ci", "utf8mb4_general_ci", "utf8mb4_0900_ai_ci", "utf8_general_ci", "latin1_swedish_ci"]

    var body: some View {
        VStack(spacing: 14) {
            Text(L10n.t("db.new"))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 4)

            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name:").foregroundStyle(.secondary)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.t("db.encoding")).foregroundStyle(.secondary)
                    Picker("", selection: $encoding) {
                        ForEach(encodings, id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("db.collation")).foregroundStyle(.secondary)
                    Picker("", selection: $collation) {
                        ForEach(collations, id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button(L10n.t("form.cancel"), action: onCancel)
                Button(L10n.t("db.ok")) {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    onCreate(
                        n,
                        encoding == "Default" ? nil : encoding,
                        collation == "Default" ? nil : collation
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    let count: Int
    var defaultExpanded: Bool = true
    var hideIfEmpty: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var expanded: Bool

    init(title: String, count: Int, defaultExpanded: Bool = true, hideIfEmpty: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self.defaultExpanded = defaultExpanded
        self.hideIfEmpty = hideIfEmpty
        self.content = content
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        if hideIfEmpty && count == 0 {
            EmptyView()
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                content()
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct DatabaseRow: View {
    let name: String
    let isCurrent: Bool
    var isSelected: Bool = false
    var onTap: () -> Void
    @State private var hovered: Bool = false

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.30) }
        return hovered ? Color.primary.opacity(0.08) : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(size: 18, cornerRatio: 0.25, glyphRatio: 0.55, withShadow: false)
            Text(name)
                .font(.system(size: 12))
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovered = $0 }
    }
}

/// Transparent overlay that intercepts ONLY right-clicks (left-clicks fall through to the SwiftUI
/// content behind it) and pops up a lightweight NSMenu — a per-row replacement for `.contextMenu`,
/// which makes large sidebar Lists janky on left-click.
private struct RightClickArea: NSViewRepresentable {
    let items: [(String, () -> Void)]

    func makeNSView(context: Context) -> NSView {
        let v = RCView()
        v.items = items
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RCView)?.items = items
    }

    final class RCView: NSView {
        var items: [(String, () -> Void)] = []
        private var handlers: [() -> Void] = []

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? self : nil
        }

        // SwiftUI's macOS List leaves NSTableView's default intercell gap between rows — dead space
        // that swallows clicks. Zero it from inside the first row that lands in the table.
        // Deferred: at viewDidMoveToWindow the row may not be parented into the table yet.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                var v: NSView? = self?.superview
                while let cur = v, !(cur is NSTableView) { v = cur.superview }
                if let tv = v as? NSTableView, tv.intercellSpacing.height != 0 {
                    tv.intercellSpacing = NSSize(width: tv.intercellSpacing.width, height: 0)
                }
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            handlers = items.map { $0.1 }
            let menu = NSMenu()
            for (i, item) in items.enumerated() {
                let mi = NSMenuItem(title: item.0, action: #selector(invoke(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = i
                menu.addItem(mi)
            }
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }

        @objc private func invoke(_ sender: NSMenuItem) {
            guard handlers.indices.contains(sender.tag) else { return }
            handlers[sender.tag]()
        }
    }
}

/// Sidebar multi-selection state. A reference type so row taps mutate it without invalidating the
/// parent view body — only rows observing `items` re-render.
@MainActor
@Observable
final class SidebarSelection {
    var items: Set<String> = []
    var anchor: String?
}

/// Equatable sidebar list: SwiftUI skips its body (and the huge ForEach diff) whenever the value
/// inputs are unchanged — clicks, tab switches and edits don't touch them. Unchanged arrays hit
/// Array's buffer-identity == fast path, so the comparison itself is O(1) per click.
private struct SidebarItemsList: View, Equatable {
    let showRecently: Bool
    let showFunctions: Bool
    let showViews: Bool
    let expandedRecently: Bool
    let expandedFunctions: Bool
    let expandedViews: Bool
    let expandedTables: Bool
    let recentItems: [String]
    let functionItems: [String]
    let procedureItems: [String]
    let viewItems: [String]
    let tableItems: [String]
    let sel: SidebarSelection
    let onToggle: (String) -> Void
    let onTap: (String) -> Void
    let onCopy: (String) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.showRecently == b.showRecently
            && a.showFunctions == b.showFunctions
            && a.showViews == b.showViews
            && a.expandedRecently == b.expandedRecently
            && a.expandedFunctions == b.expandedFunctions
            && a.expandedViews == b.expandedViews
            && a.expandedTables == b.expandedTables
            && a.recentItems == b.recentItems
            && a.functionItems == b.functionItems
            && a.procedureItems == b.procedureItems
            && a.viewItems == b.viewItems
            && a.tableItems == b.tableItems
    }

    var body: some View {
        List {
            if showRecently {
                header("recently", L10n.t("workspace.recently"), count: recentItems.count, expanded: expandedRecently)
                if expandedRecently {
                    ForEach(recentItems, id: \.self) { rowView($0, "clock.arrow.circlepath") }
                }
            }
            if showFunctions {
                header("functions", L10n.t("workspace.functions"), count: functionItems.count + procedureItems.count, expanded: expandedFunctions)
                if expandedFunctions {
                    ForEach(functionItems, id: \.self) { rowView($0, "function") }
                    ForEach(procedureItems, id: \.self) { rowView($0, "scroll") }
                }
            }
            if showViews {
                header("views", L10n.t("workspace.views"), count: viewItems.count, expanded: expandedViews)
                if expandedViews {
                    ForEach(viewItems, id: \.self) { rowView($0, "eye") }
                }
            }
            header("tables", L10n.t("workspace.tables"), count: tableItems.count, expanded: expandedTables)
            if expandedTables {
                ForEach(tableItems, id: \.self) { rowView($0, "tablecells") }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(red: 37/255, green: 37/255, blue: 39/255))
    }

    private func rowView(_ name: String, _ icon: String) -> some View {
        SidebarRowView(name: name, icon: icon, sel: sel, onTap: onTap, onCopy: onCopy)
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
    }

    private func header(_ key: String, _ title: String, count: Int, expanded: Bool) -> some View {
        Button {
            onToggle(key)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}

/// One sidebar row. Reads selection / activeTab / dirty state in ITS OWN body, so those per-click
/// changes invalidate only the realized (visible) rows, never the surrounding ForEach.
private struct SidebarRowView: View {
    @Environment(SessionStore.self) private var session
    let name: String
    let icon: String
    let sel: SidebarSelection
    let onTap: (String) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        let selected = sel.items.contains(name) || (sel.items.isEmpty && session.activeTab == name)
        HStack(spacing: 4) {
            Label(name, systemImage: icon)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if session.tableHasEdits(name) {
                Circle()
                    .fill(TableViewerView.editAmber)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap(name) }
        // Right-click only (left clicks pass through to the tap gesture); avoids per-row SwiftUI
        // .contextMenu, which makes a large sidebar List janky.
        .overlay(RightClickArea(items: [(L10n.t("sidebar.copyName"), { onCopy(name) })]))
    }
}
