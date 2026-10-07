import SwiftUI
import SDRCore

struct BookmarksView: View {
    @Environment(RadioController.self) private var radio
    @State private var selection: Bookmark.ID?
    @State private var filter = ""
    @State private var editing: Bookmark?

    private var groups: [(String, [Bookmark])] {
        let f = filter.lowercased()
        let items = radio.bookmarks.filter {
            f.isEmpty || $0.name.lowercased().contains(f) || $0.group.lowercased().contains(f)
                || FrequencyFormat.dotted($0.frequency).contains(f)
        }
        return Dictionary(grouping: items, by: \.group)
            .map { ($0.key, $0.value.sorted { $0.frequency < $1.frequency }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(Theme.amber)
                    .accessibilityHidden(true)
                Text("Favourites")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    radio.addBookmark()
                } label: {
                    Label("Add to Favourites", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Add the current frequency to favourites (⌘D)")
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Theme.panelHeader)

            SearchField(text: $filter, prompt: "Filter")
                .padding(6)

            List(selection: $selection) {
                ForEach(groups, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items) { b in
                            BookmarkRow(bookmark: b, active: abs(b.frequency - radio.vfoFrequency) < 1)
                                .tag(b.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { radio.recall(b) }
                                .onTapGesture { selection = b.id; radio.recall(b) }
                                .contextMenu {
                                    Button("Tune") { radio.recall(b) }
                                    Button("Edit…") { editing = b }
                                    Button("Update to Current Frequency") { update(b) }
                                    Divider()
                                    Button("Delete", role: .destructive) { delete(b) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onDeleteCommand {
                if let id = selection, let b = radio.bookmarks.first(where: { $0.id == id }) { delete(b) }
            }
        }
        .background(Theme.window)
        .sheet(item: $editing) { b in
            BookmarkEditor(bookmark: b) { updated in
                if let i = radio.bookmarks.firstIndex(where: { $0.id == updated.id }) {
                    radio.bookmarks[i] = updated
                }
            }
        }
    }

    private func delete(_ b: Bookmark) {
        radio.bookmarks.removeAll { $0.id == b.id }
    }

    private func update(_ b: Bookmark) {
        guard let i = radio.bookmarks.firstIndex(where: { $0.id == b.id }) else { return }
        radio.bookmarks[i].frequency = radio.vfoFrequency
        radio.bookmarks[i].mode = radio.mode
        radio.bookmarks[i].bandwidth = radio.bandwidth
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(bookmark.name)
                .font(.body.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.accent : .primary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(FrequencyFormat.dotted(bookmark.frequency))
                    .font(.caption.monospaced())
                Text(bookmark.mode.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 3)
                    .background(Theme.fillStrong, in: RoundedRectangle(cornerRadius: 2))
                Text(FrequencyFormat.bandwidth(bookmark.bandwidth))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
        .padding(.vertical, 1)
    }
}

private struct BookmarkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var bookmark: Bookmark
    @State private var frequencyText = ""
    let onSave: (Bookmark) -> Void

    var body: some View {
        Form {
            TextField("Name", text: $bookmark.name)
            TextField("Group", text: $bookmark.group)
            TextField("Frequency", text: $frequencyText)
            Picker("Mode", selection: $bookmark.mode) {
                ForEach(DemodMode.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Bandwidth (Hz)", value: $bookmark.bandwidth, format: .number)
        }
        .padding()
        .frame(width: 340)
        .onAppear { frequencyText = String(format: "%.6f", bookmark.frequency / 1e6) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let f = FrequencyFormat.parse(frequencyText) { bookmark.frequency = f }
                    onSave(bookmark)
                    dismiss()
                }
            }
        }
    }
}

/// Native search field (magnifying glass, clear button, Esc clears). SwiftUI only offers one
/// through `.searchable`, which needs a navigation container.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // The clear button sends the action without a text-change notification.
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func search(_ field: NSSearchField) { text.wrappedValue = field.stringValue }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
