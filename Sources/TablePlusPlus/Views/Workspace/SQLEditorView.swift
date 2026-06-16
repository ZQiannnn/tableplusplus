import SwiftUI
import AppKit

/// One auto-completion candidate: its insert text + category (drives the icon and the right-side tag).
struct CompletionItem: Hashable {
    let text: String
    let kind: Kind

    enum Kind: Hashable {
        case keyword, table, view, column
        var label: String {
            switch self {
            case .keyword: return "keyword"
            case .table:   return "table"
            case .view:    return "view"
            case .column:  return "column"
            }
        }
        var icon: String {
            switch self {
            case .keyword: return "k.square"
            case .table:   return "tablecells"
            case .view:    return "rectangle.on.rectangle"
            case .column:  return "square.grid.3x1.below.line.grid.1x2"
            }
        }
    }
}

/// Editable SQL editor: line-number gutter, live syntax highlight (in-place attributes, cursor
/// preserved), cursor position reporting, auto-completion (keywords + schema names), and
/// ⌘↩ (run current) / ⌘I (beautify) interception.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    /// Schema names for completion (tables/views/columns); keywords are added internally.
    var completionItems: () -> [CompletionItem] = { [] }
    var onCursor: (_ line: Int, _ column: Int, _ location: Int) -> Void
    var onSelectionChange: (_ selected: String) -> Void = { _ in }
    var onRunCurrent: () -> Void
    var onBeautify: () -> Void
    var onSave: () -> Void = {}

    private static let bg = NSColor(srgbRed: 30/255, green: 30/255, blue: 30/255, alpha: 1)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = EditorTextView()
        editor.coordinator = context.coordinator
        editor.delegate = context.coordinator
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = NSColor(white: 0.9, alpha: 1)
        editor.insertionPointColor = .white
        editor.drawsBackground = true
        editor.backgroundColor = Self.bg
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.bg
        scroll.borderType = .noBorder
        scroll.clipsToBounds = true   // the ruler's edge hairline otherwise paints past the top edge, over the tab bar

        let ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = editor
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.editor = editor
        context.coordinator.ruler = ruler
        context.coordinator.completion.onAccept = { [weak coordinator = context.coordinator] item in
            coordinator?.insertCompletion(item)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? EditorTextView else { return }
        if tv.hasMarkedText() { return }   // never overwrite text mid-IME-composition (kills the input session)
        if tv.string != text {
            context.coordinator.completion.hide()   // tab switch / external set: drop a stale popup
            tv.string = text
            context.coordinator.rehighlight(tv)
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var editor: EditorTextView?
        weak var ruler: LineNumberRuler?
        let completion = CompletionController()
        init(_ p: SQLEditorView) { parent = p }

        static let keywords: [String] = [
            "SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET",
            "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "JOIN", "LEFT JOIN",
            "RIGHT JOIN", "INNER JOIN", "ON", "AS", "AND", "OR", "NOT", "NULL", "IS NULL",
            "IS NOT NULL", "IN", "LIKE", "BETWEEN", "EXISTS", "DISTINCT", "COUNT", "SUM",
            "MIN", "MAX", "AVG", "ASC", "DESC", "UNION", "CASE", "WHEN", "THEN", "ELSE", "END",
            "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "SHOW", "DESCRIBE", "EXPLAIN",
        ]

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Mid-IME-composition: don't sync/highlight/complete — mutating textStorage attributes or
            // the binding cancels the marked text and breaks Chinese input. Resyncs once composition commits.
            if tv.hasMarkedText() { return }
            parent.text = tv.string
            rehighlight(tv)
            ruler?.needsDisplay = true
            autoComplete(tv)
        }

        private func autoComplete(_ tv: NSTextView) {
            guard !tv.hasMarkedText() else { completion.hide(); return }   // no popup during IME composition
            let range = tv.rangeForUserCompletion
            guard range.length >= 2, range.location != NSNotFound else { completion.hide(); return }
            let items = candidates(forPartialWordRange: range, in: tv)
            if items.isEmpty { completion.hide() } else { completion.update(items: items, textView: tv) }
        }

        /// Candidates (schema names first, then keywords) for the partial word at `charRange`.
        func candidates(forPartialWordRange charRange: NSRange, in textView: NSTextView) -> [CompletionItem] {
            let ns = textView.string as NSString
            guard charRange.location != NSNotFound, NSMaxRange(charRange) <= ns.length else { return [] }
            let prefix = ns.substring(with: charRange).lowercased()
            guard !prefix.isEmpty else { return [] }
            let all = parent.completionItems() + Self.keywords.map { CompletionItem(text: $0, kind: .keyword) }
            let hits = all.filter { $0.text.lowercased().hasPrefix(prefix) && $0.text.lowercased() != prefix }
            return Array(hits.prefix(30))
        }

        /// Replace the partial word under the caret with an accepted completion.
        func insertCompletion(_ item: String) {
            guard let tv = editor else { return }
            let range = tv.rangeForUserCompletion
            guard range.location != NSNotFound else { return }
            tv.insertText(item, replacementRange: range)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let loc = tv.selectedRange().location
            let ns = tv.string as NSString
            var line = 1, lineStart = 0
            var i = 0
            while i < min(loc, ns.length) {
                if ns.character(at: i) == 0x0A { line += 1; lineStart = i + 1 }
                i += 1
            }
            parent.onCursor(line, loc - lineStart + 1, loc)
            let sel = tv.selectedRange()
            parent.onSelectionChange(sel.length > 0 ? ns.substring(with: sel) : "")
        }

        func rehighlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            storage.beginEditing()
            SQLHighlightView.applyHighlight(to: storage)
            storage.endEditing()
        }
    }

    final class EditorTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func keyDown(with event: NSEvent) {
            if let c = coordinator?.completion, c.isVisible {
                switch event.keyCode {
                case 48, 36, 76:  if c.acceptSelected() { return }   // Tab / Return / Enter accept
                case 125:         c.moveDown(); return               // ↓
                case 126:         c.moveUp(); return                 // ↑
                case 53:          c.hide(); return                   // Esc dismisses
                default:          break
                }
            }
            super.keyDown(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            coordinator?.completion.hide()
            super.mouseDown(with: event)
        }

        override func resignFirstResponder() -> Bool {
            coordinator?.completion.hide()
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "\r" { coordinator?.parent.onRunCurrent(); return true }
                if event.charactersIgnoringModifiers == "i" { coordinator?.parent.onBeautify(); return true }
                // ⌘S saves the query only while the editor is focused, so the data-grid's ⌘S (commit) still works.
                if event.charactersIgnoringModifiers == "s", window?.firstResponder === self {
                    coordinator?.parent.onSave(); return true
                }
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Minimal line-number gutter for an NSTextView inside an NSScrollView.
final class LineNumberRuler: NSRulerView {
    private static let bg = NSColor(srgbRed: 26/255, green: 26/255, blue: 26/255, alpha: 1)
    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor(white: 0.45, alpha: 1),
    ]

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 38
    }
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Self.bg.setFill()
        bounds.fill()
        guard let tv = clientView as? NSTextView,
              let lm = tv.layoutManager,
              let container = tv.textContainer else { return }
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let ns = tv.string as NSString

        var lineNo = 1
        var i = 0
        let firstChar = glyphs.location < lm.numberOfGlyphs
            ? lm.characterIndexForGlyph(at: glyphs.location)
            : 0
        while i < firstChar {
            if ns.character(at: i) == 0x0A { lineNo += 1 }
            i += 1
        }

        var glyph = glyphs.location
        while glyph < NSMaxRange(glyphs) {
            var lineGlyphRange = NSRange()
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphRange)
            let charRange = lm.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            // Only number "real" lines (wrapped continuations keep the gutter blank).
            let isLineStart = charRange.location == 0
                || ns.character(at: charRange.location - 1) == 0x0A
            if isLineStart {
                let y = lineRect.minY - visible.minY + tv.textContainerInset.height
                let label = "\(lineNo)" as NSString
                let size = label.size(withAttributes: Self.attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (lineRect.height - size.height) / 2),
                           withAttributes: Self.attrs)
                lineNo += 1
            }
            glyph = NSMaxRange(lineGlyphRange)
        }

        // Empty document: still show "1".
        if ns.length == 0 {
            let label = "1" as NSString
            let size = label.size(withAttributes: Self.attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: tv.textContainerInset.height),
                       withAttributes: Self.attrs)
        }
    }
}

/// Lightweight completion popover: a non-key child panel listing candidates, so it never steals
/// keystrokes (the text view keeps first responder — backspace/Return/typing stay normal). The
/// owning EditorTextView routes ↑/↓/Tab/Esc to it via keyDown.
@MainActor
final class CompletionController: NSObject {
    static let rowH: CGFloat = 24
    private var panel: NSPanel?
    private var scroll: NSScrollView?
    private var list: CompletionListView?
    private(set) var items: [CompletionItem] = []
    private var selected = 0
    weak var textView: NSTextView?
    var onAccept: ((String) -> Void)?

    private static let bg = NSColor(srgbRed: 40/255, green: 40/255, blue: 42/255, alpha: 1)

    var isVisible: Bool { panel?.isVisible ?? false }

    func update(items: [CompletionItem], textView: NSTextView) {
        guard !items.isEmpty else { hide(); return }
        self.textView = textView
        self.items = items
        selected = 0
        ensurePanel()
        list?.items = items
        list?.selected = 0
        list?.frame = NSRect(x: 0, y: 0, width: 340, height: CGFloat(items.count) * Self.rowH)
        list?.needsDisplay = true
        reposition()
        scrollToSelected()
        if let panel, let win = textView.window {
            if panel.parent == nil { win.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
        }
    }

    func hide() {
        items = []
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveDown() { guard !items.isEmpty else { return }; selected = (selected + 1) % items.count; syncSel() }
    func moveUp()   { guard !items.isEmpty else { return }; selected = (selected - 1 + items.count) % items.count; syncSel() }

    private func syncSel() {
        list?.selected = selected
        list?.needsDisplay = true
        scrollToSelected()
    }

    private func scrollToSelected() {
        list?.scrollToVisible(NSRect(x: 0, y: CGFloat(selected) * Self.rowH, width: 1, height: Self.rowH))
    }

    func acceptSelected() -> Bool {
        guard isVisible, items.indices.contains(selected) else { return false }
        let v = items[selected].text
        hide()
        onAccept?(v)
        return true
    }

    private func reposition() {
        guard let tv = textView, let panel else { return }
        let loc = max(tv.selectedRange().location - 1, 0)
        let caret = tv.firstRect(forCharacterRange: NSRange(location: loc, length: 1), actualRange: nil)
        let h = CGFloat(min(items.count, 8)) * Self.rowH
        panel.setFrame(NSRect(x: caret.minX, y: caret.minY - h - 2, width: 340, height: h), display: true)
    }

    private func ensurePanel() {
        if panel != nil { return }
        let lv = CompletionListView()
        lv.onClick = { [weak self] row in
            guard let self else { return }
            self.selected = row
            _ = self.acceptSelected()
        }
        let s = NSScrollView()
        s.documentView = lv
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.scrollerStyle = .overlay
        s.drawsBackground = false
        s.borderType = .noBorder
        s.automaticallyAdjustsContentInsets = false
        s.contentInsets = NSEdgeInsets()

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = Self.bg.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        s.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            s.topAnchor.constraint(equalTo: container.topAnchor),
            s.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.minSize = NSSize(width: 0, height: 0)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.contentView = container
        panel = p
        scroll = s
        list = lv
    }
}

/// Flipped, custom-drawn completion list (top-anchored, no NSTableView layout quirks): each row is
/// icon + name + right-aligned category tag, selected row painted in the app's teal.
private final class CompletionListView: NSView {
    var items: [CompletionItem] = []
    var selected = 0
    var onClick: ((Int) -> Void)?

    override var isFlipped: Bool { true }   // top-origin so a short list sits at the TOP, not bottom

    private static let teal = NSColor(srgbRed: 0/255, green: 117/255, blue: 143/255, alpha: 0.9)
    private static let iconTint = NSColor(white: 0.62, alpha: 1)
    private static let nameAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(white: 0.93, alpha: 1),
    ]
    private static let tagAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor(white: 0.5, alpha: 1),
    ]

    override func draw(_ dirtyRect: NSRect) {
        let h = CompletionController.rowH
        for (i, item) in items.enumerated() {
            let y = CGFloat(i) * h
            if i == selected {
                Self.teal.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: h).fill()
            }
            if let img = NSImage(systemSymbolName: item.kind.icon, accessibilityDescription: nil) {
                let tinted = img.tinted(Self.iconTint)
                tinted.draw(in: NSRect(x: 10, y: y + (h - 13) / 2, width: 13, height: 13))
            }
            (item.text as NSString).draw(at: NSPoint(x: 31, y: y + (h - 15) / 2), withAttributes: Self.nameAttrs)
            let tag = item.kind.label as NSString
            let ts = tag.size(withAttributes: Self.tagAttrs)
            tag.draw(at: NSPoint(x: bounds.width - 12 - ts.width, y: y + (h - ts.height) / 2), withAttributes: Self.tagAttrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = Int(p.y / CompletionController.rowH)
        if items.indices.contains(row) { onClick?(row) }
    }
}

private extension NSImage {
    /// Tint an alpha-bearing image (e.g. an SF symbol) by compositing colour over its opaque pixels.
    func tinted(_ color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
