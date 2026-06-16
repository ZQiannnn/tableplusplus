import SwiftUI
import AppKit

@main
struct TablePlusPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ConnectionStore()
    @State private var session = SessionStore.shared
    @State private var prefs = PrefsStore.shared

    var body: some Scene {
        WindowGroup("TablePlusPlus") {
            RootView()
                .environment(store)
                .environment(session)
                .environment(prefs)
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button(L10n.t("menu.undo")) {
                    if session.hasEdits { session.discardEdits() }
                    else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button(L10n.t("menu.redo")) {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.t("menu.actions")) {
                Button(L10n.t("menu.openDatabase")) { AppCommands.shared.openDbPickerPulse() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!session.isConnected)

                Divider()

                Button(L10n.t("menu.refreshRun")) { AppCommands.shared.runOrRefreshPulse() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!session.isConnected)
                Button(L10n.t("menu.toggleStructure")) {
                    session.viewerMode = session.viewerMode == .data ? .structure : .data
                }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(!session.isConnected)
                Button(L10n.t("menu.prevTab")) { session.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(!session.isConnected)
                Button(L10n.t("menu.nextTab")) { session.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(!session.isConnected)

                Divider()

                Button(L10n.t("menu.focusSearch")) { AppCommands.shared.focusSearchPulse() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!session.isConnected)
                Button(L10n.t("menu.focusWhere")) { AppCommands.shared.focusWherePulse() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!session.isConnected)

                Divider()

                Button(L10n.t("menu.insertRow")) { session.insertRow() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!session.isConnected || session.currentTable == nil)
                Button(L10n.t("menu.toggleDelete")) {
                    if let r = session.detailEditableRow { session.toggleDelete(IndexSet(integer: r)) }
                }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(session.detailEditableRow == nil)
                Button(L10n.t("menu.commit")) {
                    Task { if let e = await session.commitEdits() { session.error = e } }
                }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!session.hasEdits)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        Persistence.importLegacyIfNeeded()
        DispatchQueue.main.async {
            for win in NSApp.windows where !win.isExcludedFromWindowsMenu {
                win.setFrameAutosaveName("")  // disable macOS auto-restore
                win.delegate = self
            }
            if let img = Self.renderDockIcon() {
                NSApp.applicationIconImage = img
            }
            WindowResizer.startObservingResize()
            WindowResizer.trackResize = true
            WindowResizer.restoreToWelcomeSize()
        }
    }

    @MainActor static var gridFieldEditor: NoMenuTextView?

    // Replace the system field editor (with its Search-With-Baidu / Spelling / Services menu) for the
    // grid's inline cell editor with one that vends a concise Cut/Copy/Paste menu.
    @MainActor func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard client is TPPEditField else { return nil }
        if Self.gridFieldEditor == nil {
            let fe = NoMenuTextView()
            fe.isFieldEditor = true
            Self.gridFieldEditor = fe
        }
        return Self.gridFieldEditor
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        let hasSession = MainActor.assumeIsolated {
            SessionStore.shared.isConnected
        }
        if hasSession {
            Task { @MainActor in
                await SessionStore.shared.close()
            }
            return false  // disconnect → resize back to welcome, don't quit
        }
        return true  // welcome state: allow close → app terminates
    }

    @MainActor
    static func renderDockIcon() -> NSImage? {
        // macOS HIG: icon canvas 1024px, content inset ~10% = 820px
        let canvas: CGFloat = 1024
        let inset: CGFloat = 100
        let content = ZStack {
            Color.clear
            AppIcon(size: canvas - inset * 2, withShadow: false)
        }
        .frame(width: canvas, height: canvas)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.nsImage
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            if session.isConnected {
                WorkspaceView()
            } else {
                WelcomeView()
            }
        }
        .onChange(of: session.isConnected) { _, isConnected in
            DispatchQueue.main.async {
                WindowResizer.trackResize = !isConnected  // only persist welcome resize
                if isConnected {
                    WindowResizer.expandToScreen()
                } else {
                    WindowResizer.restoreToWelcomeSize()
                }
            }
        }
    }
}

@MainActor
enum WindowResizer {
    static let welcomeSize = NSSize(width: 720, height: 540)
    /// kept for backward compat; was used by RootView's onChange.
    static var trackResize: Bool = false

    static var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { !$0.isExcludedFromWindowsMenu }
    }

    /// no-op now (we don't persist welcome resize anymore).
    static func startObservingResize() {}

    static func expandToScreen() {
        guard let win = window, let screen = win.screen ?? NSScreen.main else { return }
        win.styleMask.insert(.resizable)
        win.setFrame(screen.visibleFrame, display: true, animate: true)
    }

    static func restoreToWelcomeSize() {
        guard let win = window else { return }
        let screen = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let target = welcomeSize
        let x = screen.midX - target.width / 2
        let y = screen.midY - target.height / 2
        win.setFrame(NSRect(x: x, y: y, width: target.width, height: target.height), display: true, animate: true)
        // Lock welcome window to fixed size (user can't drag-resize)
        win.styleMask.remove(.resizable)
    }
}

/// Field editor for the grid's inline cell editor: replaces the default rich contextual menu
/// (Search With…, Spelling, Substitutions, AutoFill, Services) with a concise Cut/Copy/Paste menu.
/// `NSMenu.popUpContextMenu` and the default text-view menu path auto-append AutoFill + Services, so
/// we present our menu manually with `popUp(positioning:at:in:)` (which doesn't augment) and opt out
/// of the Services menu via `validRequestor`.
final class NoMenuTextView: NSTextView {
    private func editMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ key: String, _ sel: Selector) {
            let it = NSMenuItem(title: L10n.t(key), action: sel, keyEquivalent: "")
            it.target = nil   // route through the responder chain (the field editor)
            m.addItem(it)
        }
        add("menu.cut", #selector(NSText.cut(_:)))
        add("menu.copy", #selector(NSText.copy(_:)))
        add("menu.paste", #selector(NSText.paste(_:)))
        return m
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        editMenu().popUp(positioning: nil, at: pt, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { editMenu() }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? { nil }
}
