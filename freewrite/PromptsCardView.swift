import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Cursor helpers
//
// NSCursor.push()/pop() in `.onHover` is unreliable when the popup overlays
// an NSTextView — the text view's tracking area sets I-beam and our pushes
// race against it. Instead we register a proper cursor rect via an NSView
// installed as a small SwiftUI layer; click events pass through (`hitTest` returns nil),
// so SwiftUI controls underneath remain interactive.
struct CursorRegionView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        CursorRegionNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let nsView = nsView as? CursorRegionNSView else { return }
        nsView.cursor = cursor
    }
}

private final class CursorRegionNSView: NSView {
    private var trackingArea: NSTrackingArea?

    var cursor: NSCursor {
        didSet {
            guard oldValue !== cursor else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.cursor = .arrow
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Registers a cursor rect over this view while letting clicks pass through
    /// to SwiftUI controls underneath.
    func cursorRegion(_ cursor: NSCursor) -> some View {
        self.overlay(CursorRegionView(cursor: cursor))
    }

    /// Shows the pointing-hand cursor when hovered, without intercepting clicks.
    func pointerCursor() -> some View {
        cursorRegion(.pointingHand)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.pointingHand.set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
    }

    /// Keeps non-interactive popup space from inheriting the editor's I-beam.
    func arrowCursor() -> some View {
        cursorRegion(.arrow)
            .onContinuousHover { phase in
                if case .active = phase {
                    NSCursor.arrow.set()
                }
            }
    }

    /// Explicitly preserves text insertion cursor behavior inside popup fields.
    func iBeamCursor() -> some View {
        cursorRegion(.iBeam)
            .onContinuousHover { phase in
                if case .active = phase {
                    NSCursor.iBeam.set()
                }
            }
    }
}

// MARK: - View model

@MainActor
final class PromptsCardViewModel: ObservableObject {
    @Published var showing: Bool = false
    @Published var view: ViewMode = .list
    @Published var historyFilter: String = ""
    @Published var draft: String = ""
    @Published var draftRecurring: Bool = false
    @Published var editingID: UUID? = nil
    @Published var editingText: String = ""
    /// Set to true to make the add-prompt input first responder once it appears.
    @Published var focusAddInputOnAppear: Bool = false

    enum ViewMode { case list, history }

    func open(focusInput: Bool = true) {
        view = .list
        focusAddInputOnAppear = focusInput
        showing = true
    }

    func close() {
        editingID = nil
        showing = false
    }
}

// MARK: - Palette

private struct PromptsPalette {
    let cardBackground: Color
    let cardBorder: Color
    let rowHover: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let insertGlyph: Color
    let dropIndicator: Color

    static func current(_ scheme: ColorScheme) -> PromptsPalette {
        if scheme == .dark {
            return PromptsPalette(
                cardBackground: Color(red: 0.12, green: 0.12, blue: 0.12),
                cardBorder: Color(red: 0.22, green: 0.22, blue: 0.22),
                rowHover: Color(red: 0.18, green: 0.18, blue: 0.18),
                textPrimary: Color(red: 0.92, green: 0.92, blue: 0.92),
                textSecondary: Color(red: 0.62, green: 0.62, blue: 0.62),
                textTertiary: Color(red: 0.42, green: 0.42, blue: 0.42),
                insertGlyph: Color(red: 0.55, green: 0.55, blue: 0.55),
                dropIndicator: Color(red: 0.55, green: 0.55, blue: 0.55)
            )
        } else {
            return PromptsPalette(
                cardBackground: Color(red: 0.984, green: 0.980, blue: 0.969), // #fbfaf7
                cardBorder: Color(red: 0.925, green: 0.925, blue: 0.918),     // #ececea
                rowHover: Color(red: 0.941, green: 0.933, blue: 0.913),       // #f0eee9
                textPrimary: Color(red: 0.165, green: 0.165, blue: 0.165),    // #2a2a2a
                textSecondary: Color(red: 0.604, green: 0.604, blue: 0.604),  // #9a9a9a
                textTertiary: Color(red: 0.741, green: 0.741, blue: 0.741),   // #bdbdbd
                insertGlyph: Color(red: 0.741, green: 0.741, blue: 0.741),
                dropIndicator: Color(red: 0.165, green: 0.165, blue: 0.165)
            )
        }
    }
}

// MARK: - Card root

struct PromptsCardView: View {
    @ObservedObject var store: PromptsStore
    @ObservedObject var model: PromptsCardViewModel
    @Environment(\.colorScheme) private var colorScheme
    let onInsert: (Prompt) -> Void

    var body: some View {
        let palette = PromptsPalette.current(colorScheme)
        VStack(spacing: 0) {
            if model.view == .list {
                listView(palette: palette)
            } else {
                historyView(palette: palette)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.07), radius: 18, x: 0, y: 12)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.04), radius: 3, x: 0, y: 2)
    }

    // MARK: List

    @ViewBuilder
    private func listView(palette: PromptsPalette) -> some View {
        cardHeader(
            palette: palette,
            title: "PROMPTS",
            leadingBackButton: false,
            trailing: {
                AnyView(
                    HStack(spacing: 2) {
                        cardIconButton(.clock, palette: palette) {
                            model.view = .history
                        }
                        cardIconButton(.close, palette: palette) {
                            model.close()
                        }
                    }
                )
            }
        )

        PromptSectionView(
            section: .oneShot,
            items: store.oneShotPrompts,
            store: store,
            model: model,
            palette: palette,
            onInsert: onInsert
        )

        PromptSectionView(
            section: .recurring,
            items: store.recurringPrompts,
            store: store,
            model: model,
            palette: palette,
            onInsert: onInsert
        )
        .padding(.top, 18)

        addRow(palette: palette)
    }

    @ViewBuilder
    private func addRow(palette: PromptsPalette) -> some View {
        VStack(spacing: 0) {
            DashedDivider(color: palette.cardBorder)
                .padding(.top, 24)
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                Text("+")
                    .foregroundColor(palette.textTertiary)
                    .font(.system(size: 15))
                    .frame(width: 14, alignment: .center)

                AddPromptField(
                    text: $model.draft,
                    placeholder: "add a prompt...",
                    palette: palette,
                    shouldFocusOnAppear: model.focusAddInputOnAppear,
                    onCommit: submit
                )

                RecurringCheckbox(
                    isOn: $model.draftRecurring,
                    palette: palette
                )
            }
        }
    }

    private func submit() {
        let trimmed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.add(text: trimmed, isRecurring: model.draftRecurring)
        model.draft = ""
    }

    // MARK: History

    @ViewBuilder
    private func historyView(palette: PromptsPalette) -> some View {
        cardHeader(
            palette: palette,
            title: "HISTORY",
            count: store.history.count,
            leadingBackButton: true,
            onBack: { model.view = .list },
            trailing: {
                AnyView(
                    cardIconButton(.close, palette: palette) {
                        model.close()
                    }
                )
            }
        )

        HStack {
            HistoryFilterField(text: $model.historyFilter, palette: palette)
        }
        .padding(.bottom, 6)
        .padding(.top, 2)

        let filtered = filteredHistory()
        ScrollView {
            VStack(spacing: 0) {
                if filtered.isEmpty {
                    HStack {
                        Text("no entries match")
                            .italic()
                            .foregroundColor(palette.textTertiary)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                } else {
                    ForEach(filtered) { entry in
                        HistoryRow(entry: entry, palette: palette)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }

    private func filteredHistory() -> [PromptHistoryEntry] {
        let query = model.historyFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.history }
        return store.history.filter { $0.promptText.lowercased().contains(query) }
    }

    // MARK: Header

    @ViewBuilder
    private func cardHeader(
        palette: PromptsPalette,
        title: String,
        count: Int? = nil,
        leadingBackButton: Bool,
        onBack: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> AnyView
    ) -> some View {
        HStack(spacing: 6) {
            if leadingBackButton {
                cardIconButton(.back, palette: palette) {
                    onBack?()
                }
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(palette.textSecondary)
            if let count = count {
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(palette.textTertiary)
            }
            Spacer()
            trailing()
        }
        .padding(.bottom, 8)
    }

    // MARK: Icon buttons

    private func cardIconButton(
        _ glyph: PromptsGlyph,
        palette: PromptsPalette,
        action: @escaping () -> Void
    ) -> some View {
        IconButton(glyph: glyph, palette: palette, action: action)
    }
}

// MARK: - Header icon button

private struct IconButton: View {
    let glyph: PromptsGlyph
    let palette: PromptsPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? palette.rowHover : Color.clear)
                glyph.shape
                    .stroke(hovering ? palette.textPrimary : palette.textSecondary, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

// MARK: - Section

private struct PromptSectionView: View {
    let section: PromptSectionKind
    let items: [Prompt]
    @ObservedObject var store: PromptsStore
    @ObservedObject var model: PromptsCardViewModel
    let palette: PromptsPalette
    let onInsert: (Prompt) -> Void
    @State private var dropTargetID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            VStack(spacing: 0) {
                if items.isEmpty {
                    Text(emptyText)
                        .italic()
                        .foregroundColor(palette.textTertiary)
                        .font(.system(size: 13))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(items) { prompt in
                        VStack(spacing: 0) {
                            if dropTargetID == prompt.id {
                                Rectangle()
                                    .fill(palette.dropIndicator)
                                    .frame(height: 1.5)
                                    .padding(.horizontal, 6)
                            }
                            PromptRowView(
                                prompt: prompt,
                                section: section,
                                model: model,
                                store: store,
                                palette: palette,
                                onInsert: onInsert,
                                dropTargetID: $dropTargetID
                            )
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            section.icon
                .stroke(palette.textTertiary, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 11)
            Text(section.title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.cardBorder).frame(height: 1)
        }
        .padding(.bottom, 2)
    }

    private var emptyText: String {
        switch section {
        case .recurring: return "no recurring prompts yet"
        case .oneShot: return "no one-time prompts yet"
        }
    }
}

private extension PromptSectionKind {
    var title: String {
        switch self {
        case .recurring: return "RECURRING"
        case .oneShot: return "ONE TIME USE"
        }
    }
    var subtitle: String {
        switch self {
        case .recurring: return "stays after inserting"
        case .oneShot: return "removed once inserted"
        }
    }
    var icon: Path {
        switch self {
        case .recurring:
            return Path { p in
                let scale: CGFloat = 11.0 / 14.0
                p.move(to: CGPoint(x: 2.5 * scale, y: 6 * scale))
                p.addCurve(to: CGPoint(x: 7 * scale, y: 2.5 * scale),
                           control1: CGPoint(x: 3.0 * scale, y: 4 * scale),
                           control2: CGPoint(x: 5.0 * scale, y: 2.5 * scale))
                p.addCurve(to: CGPoint(x: 11 * scale, y: 5 * scale),
                           control1: CGPoint(x: 8.7 * scale, y: 2.5 * scale),
                           control2: CGPoint(x: 10.2 * scale, y: 3.5 * scale))
                p.move(to: CGPoint(x: 11.5 * scale, y: 8 * scale))
                p.addCurve(to: CGPoint(x: 7 * scale, y: 11.5 * scale),
                           control1: CGPoint(x: 11.0 * scale, y: 10 * scale),
                           control2: CGPoint(x: 9.1 * scale, y: 11.5 * scale))
                p.addCurve(to: CGPoint(x: 3 * scale, y: 9 * scale),
                           control1: CGPoint(x: 5.3 * scale, y: 11.5 * scale),
                           control2: CGPoint(x: 3.8 * scale, y: 10.5 * scale))
                p.move(to: CGPoint(x: 9.5 * scale, y: 5.5 * scale))
                p.addLine(to: CGPoint(x: 11.5 * scale, y: 5.5 * scale))
                p.addLine(to: CGPoint(x: 11.5 * scale, y: 3.5 * scale))
                p.move(to: CGPoint(x: 4.5 * scale, y: 8.5 * scale))
                p.addLine(to: CGPoint(x: 2.5 * scale, y: 8.5 * scale))
                p.addLine(to: CGPoint(x: 2.5 * scale, y: 10.5 * scale))
            }
        case .oneShot:
            // Right-pointing arrow inside an 11x11 viewbox — suggests
            // "send it once" and visually contrasts with the loop arrow
            // used for the recurring section.
            return Path { p in
                p.move(to: CGPoint(x: 2, y: 5.5))
                p.addLine(to: CGPoint(x: 9, y: 5.5))
                p.move(to: CGPoint(x: 6, y: 2.5))
                p.addLine(to: CGPoint(x: 9, y: 5.5))
                p.addLine(to: CGPoint(x: 6, y: 8.5))
            }
        }
    }
}

// MARK: - Prompt row

private struct PromptRowView: View {
    let prompt: Prompt
    let section: PromptSectionKind
    @ObservedObject var model: PromptsCardViewModel
    @ObservedObject var store: PromptsStore
    let palette: PromptsPalette
    let onInsert: (Prompt) -> Void
    @Binding var dropTargetID: UUID?

    @State private var hovering = false

    var body: some View {
        Group {
            if model.editingID == prompt.id {
                editingRow
            } else {
                normalRow
            }
        }
        .draggable(PromptDragPayload(id: prompt.id, sectionKey: section.key)) {
            PromptDragPreview(text: prompt.text, palette: palette)
        }
        .dropDestination(for: PromptDragPayload.self) { items, _ in
            guard let item = items.first,
                  item.sectionKey == section.key,
                  item.id != prompt.id else { return false }
            store.move(sourceID: item.id, before: prompt.id, in: section)
            return true
        } isTargeted: { hovered in
            if hovered {
                dropTargetID = prompt.id
            } else if dropTargetID == prompt.id {
                dropTargetID = nil
            }
        }
    }

    private var normalRow: some View {
        HStack(alignment: .center, spacing: 8) {
            ReturnGlyph()
                .stroke(hovering ? palette.textPrimary : palette.insertGlyph,
                        style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)

            Text(prompt.text)
                .font(.system(size: 14))
                .foregroundColor(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if section == .recurring, let meta = PromptDateFormat.relative(from: prompt.lastAnsweredAt) {
                Text(meta)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(palette.textTertiary)
                    .opacity(hovering ? 1.0 : 0.0)
            }

            HStack(spacing: 1) {
                SmallRowButton(glyph: .pencil, palette: palette) {
                    model.editingID = prompt.id
                    model.editingText = prompt.text
                }
                SmallRowButton(glyph: .trash, palette: palette) {
                    store.remove(id: prompt.id)
                }
            }
            .frame(width: 48, alignment: .trailing)
            .opacity(hovering ? 1.0 : 0.0)
            .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? palette.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onInsert(prompt)
        }
        .onHover { hovering = $0 }
        .pointerCursor()
    }

    private var editingRow: some View {
        HStack(alignment: .top, spacing: 8) {
            ReturnGlyph()
                .stroke(palette.insertGlyph,
                        style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            EditingPromptField(
                text: $model.editingText,
                palette: palette,
                onCommit: commitEdit,
                onCancel: { model.editingID = nil }
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(colorSchemeBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(palette.textTertiary.opacity(0.6), lineWidth: 1)
                )
        )
    }

    private var colorSchemeBg: Color {
        palette.cardBackground.opacity(0.0001) // transparent over card; ring is provided by stroke
    }

    private func commitEdit() {
        store.rename(id: prompt.id, to: model.editingText)
        model.editingID = nil
    }
}

private struct SmallRowButton: View {
    let glyph: PromptsGlyph
    let palette: PromptsPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? palette.cardBorder : Color.clear)
                glyph.shape
                    .stroke(hovering ? palette.textPrimary : palette.textSecondary,
                            style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 13)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

// MARK: - Drag/drop

/// JSON-encoded payload shipped with the drag. We restrict drops to within the
/// same section by checking `sectionKey` in the drop handler.
struct PromptDragPayload: Codable, Transferable {
    let id: UUID
    let sectionKey: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

private extension PromptSectionKind {
    var key: String {
        switch self {
        case .recurring: return "r"
        case .oneShot: return "o"
        }
    }
}

/// Compact drag preview rendered while the user is dragging a prompt.
private struct PromptDragPreview: View {
    let text: String
    let palette: PromptsPalette

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(palette.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
            )
            .frame(maxWidth: 360)
    }
}

// MARK: - History

private struct HistoryRow: View {
    let entry: PromptHistoryEntry
    let palette: PromptsPalette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(PromptDateFormat.short(entry.answeredAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(palette.textTertiary)
                .frame(width: 56, alignment: .leading)

            Text(entry.promptText)
                .font(.system(size: 13))
                .foregroundColor(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            PromptsGlyph.historyArrow.shape
                .stroke(hovering ? palette.textPrimary : palette.textTertiary,
                        style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 11)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hovering ? palette.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Filter field

private struct HistoryFilterField: View {
    @Binding var text: String
    let palette: PromptsPalette
    @FocusState private var focused: Bool

    var body: some View {
        TextField("filter history...", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.system(size: 13))
            .foregroundColor(palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(palette.cardBorder, lineWidth: 1)
                    )
            )
            .iBeamCursor()
    }
}

// MARK: - Add field

private struct AddPromptField: View {
    @Binding var text: String
    let placeholder: String
    let palette: PromptsPalette
    let shouldFocusOnAppear: Bool
    let onCommit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onCommit() }
            .font(.system(size: 14))
            .foregroundColor(palette.textPrimary)
            .onAppear {
                if shouldFocusOnAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focused = true
                    }
                }
            }
            .iBeamCursor()
    }
}

private struct EditingPromptField: View {
    @Binding var text: String
    let palette: PromptsPalette
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onCommit() }
            .font(.system(size: 14))
            .foregroundColor(palette.textPrimary)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    focused = true
                }
            }
            .onExitCommand { onCancel() }
            .iBeamCursor()
    }
}

// MARK: - Recurring checkbox

private struct RecurringCheckbox: View {
    @Binding var isOn: Bool
    let palette: PromptsPalette
    @State private var hovering = false

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(hovering ? palette.textPrimary : palette.textSecondary, lineWidth: 1)
                        .frame(width: 12, height: 12)
                    if isOn {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(hovering ? palette.textPrimary : palette.textSecondary)
                            .frame(width: 8, height: 8)
                    }
                }
                Text("recurring")
                    .font(.system(size: 11))
                    .foregroundColor(hovering ? palette.textPrimary : palette.textSecondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering ? palette.rowHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

// MARK: - Dashed divider

private struct DashedDivider: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}

// MARK: - Glyphs (SVG -> Path)

enum PromptsGlyph {
    case clock, close, back, pencil, trash, historyArrow

    var shape: Path {
        switch self {
        case .clock:
            return Path { p in
                p.addEllipse(in: CGRect(x: 1, y: 1, width: 12, height: 12))
                p.move(to: CGPoint(x: 7, y: 3.5))
                p.addLine(to: CGPoint(x: 7, y: 7))
                p.addLine(to: CGPoint(x: 9.5, y: 8.5))
            }
        case .close:
            return Path { p in
                p.move(to: CGPoint(x: 3.5, y: 3.5))
                p.addLine(to: CGPoint(x: 10.5, y: 10.5))
                p.move(to: CGPoint(x: 10.5, y: 3.5))
                p.addLine(to: CGPoint(x: 3.5, y: 10.5))
            }
        case .back:
            return Path { p in
                p.move(to: CGPoint(x: 8.5, y: 3))
                p.addLine(to: CGPoint(x: 4.5, y: 7))
                p.addLine(to: CGPoint(x: 8.5, y: 11))
                p.move(to: CGPoint(x: 5, y: 7))
                p.addLine(to: CGPoint(x: 11, y: 7))
            }
        case .pencil:
            return Path { p in
                p.move(to: CGPoint(x: 9.5, y: 2.5))
                p.addLine(to: CGPoint(x: 11.5, y: 4.5))
                p.addLine(to: CGPoint(x: 5, y: 11))
                p.addLine(to: CGPoint(x: 3, y: 11))
                p.addLine(to: CGPoint(x: 3, y: 9))
                p.closeSubpath()
            }
        case .trash:
            return Path { p in
                p.move(to: CGPoint(x: 3, y: 4))
                p.addLine(to: CGPoint(x: 11, y: 4))
                p.move(to: CGPoint(x: 5.5, y: 4))
                p.addLine(to: CGPoint(x: 5.5, y: 3))
                p.addLine(to: CGPoint(x: 8.5, y: 3))
                p.addLine(to: CGPoint(x: 8.5, y: 4))
                p.move(to: CGPoint(x: 4, y: 4))
                p.addLine(to: CGPoint(x: 4.5, y: 12))
                p.addLine(to: CGPoint(x: 9.5, y: 12))
                p.addLine(to: CGPoint(x: 10, y: 4))
            }
        case .historyArrow:
            return Path { p in
                p.move(to: CGPoint(x: 4, y: 10))
                p.addLine(to: CGPoint(x: 10, y: 4))
                p.move(to: CGPoint(x: 5, y: 4))
                p.addLine(to: CGPoint(x: 10, y: 4))
                p.addLine(to: CGPoint(x: 10, y: 9))
            }
        }
    }
}

private struct ReturnGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // 12x12 viewbox of the return arrow from the design
        Path { p in
            let scale = rect.width / 12.0
            p.move(to: CGPoint(x: 10.0 * scale, y: 2.5 * scale))
            p.addLine(to: CGPoint(x: 10.0 * scale, y: 5.0 * scale))
            // curve down/left into the hook
            p.addCurve(
                to: CGPoint(x: 8.0 * scale, y: 7.0 * scale),
                control1: CGPoint(x: 10.0 * scale, y: 6.2 * scale),
                control2: CGPoint(x: 9.1 * scale, y: 7.0 * scale)
            )
            p.addLine(to: CGPoint(x: 2.5 * scale, y: 7.0 * scale))
            p.move(to: CGPoint(x: 5.0 * scale, y: 4.5 * scale))
            p.addLine(to: CGPoint(x: 2.5 * scale, y: 7.0 * scale))
            p.addLine(to: CGPoint(x: 5.0 * scale, y: 9.5 * scale))
        }
    }
}
