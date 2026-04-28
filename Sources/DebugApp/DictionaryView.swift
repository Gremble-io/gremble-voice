import SwiftUI
import GrembleVoiceCore

struct DictionaryView: View {
    let store: DictionaryStore
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ─────────────────────────────────────────────────────
            HStack {
                Text("\(store.entries.count) entries")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // ── Entry list ──────────────────────────────────────────────────
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "character.book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No dictionary entries yet.")
                        .foregroundStyle(.secondary)
                    Text("Record something, edit the Raw column to fix a word, then tap Learn.")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.entries) { entry in
                        EntryRow(entry: entry, store: store)
                    }
                    .onDelete { offsets in
                        offsets.forEach { store.remove(id: store.entries[$0].id) }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddEntrySheet(store: store)
        }
    }
}

// MARK: - EntryRow

private struct EntryRow: View {
    let entry: DictionaryEntry
    let store: DictionaryStore

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { _ in store.toggle(id: entry.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word)
                    .bold()
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                if !entry.aliases.isEmpty {
                    Text(entry.aliases.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(entry.language)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Button(role: .destructive) {
                store.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .opacity(entry.isEnabled ? 1 : 0.5)
    }
}

// MARK: - AddEntrySheet

private struct AddEntrySheet: View {
    let store: DictionaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var word = ""
    @State private var alias = ""
    @State private var language = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Dictionary Entry")
                .font(.headline)
                .padding()

            Divider()

            Form {
                Section {
                    LabeledContent("Correct spelling") {
                        TextField("e.g. GrembleVoice", text: $word)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Parakeet hears it as") {
                        TextField("e.g. Gremble Voice", text: $alias)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Language") {
                        TextField("en", text: $language)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                } footer: {
                    Text("The alias is what Parakeet typically transcribes. Leave blank to rely on phonetic matching only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    store.add(word: word.trimmingCharacters(in: .whitespaces),
                              alias: alias.trimmingCharacters(in: .whitespaces),
                              language: language.isEmpty ? "en" : language)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
    }
}
