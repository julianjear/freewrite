import Foundation
import SwiftUI

// MARK: - Models

struct Prompt: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isRecurring: Bool
    var lastAnsweredAt: Date?

    init(id: UUID = UUID(), text: String, isRecurring: Bool, lastAnsweredAt: Date? = nil) {
        self.id = id
        self.text = text
        self.isRecurring = isRecurring
        self.lastAnsweredAt = lastAnsweredAt
    }
}

struct PromptHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var promptText: String
    var answeredAt: Date
    var entryFilename: String?

    init(id: UUID = UUID(), promptText: String, answeredAt: Date = Date(), entryFilename: String? = nil) {
        self.id = id
        self.promptText = promptText
        self.answeredAt = answeredAt
        self.entryFilename = entryFilename
    }
}

enum PromptSectionKind: Equatable {
    case recurring
    case oneShot
}

// MARK: - Store

@MainActor
final class PromptsStore: ObservableObject {
    static let shared = PromptsStore()

    @Published var prompts: [Prompt] = []
    @Published var history: [PromptHistoryEntry] = []

    private let promptsURL: URL
    private let historyURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("freewrite", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        self.promptsURL = folder.appendingPathComponent("prompts.json")
        self.historyURL = folder.appendingPathComponent("prompt_history.json")
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: promptsURL),
           let decoded = try? decoder.decode([Prompt].self, from: data) {
            prompts = decoded
        }
        if let data = try? Data(contentsOf: historyURL),
           let decoded = try? decoder.decode([PromptHistoryEntry].self, from: data) {
            history = decoded
        }
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }

    private func savePrompts() {
        if let data = try? encoder().encode(prompts) {
            try? data.write(to: promptsURL, options: .atomic)
        }
    }

    private func saveHistory() {
        if let data = try? encoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    // MARK: - Mutations

    func add(text: String, isRecurring: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prompts.append(Prompt(text: trimmed, isRecurring: isRecurring))
        savePrompts()
    }

    func remove(id: UUID) {
        prompts.removeAll { $0.id == id }
        savePrompts()
    }

    func rename(id: UUID, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let i = prompts.firstIndex(where: { $0.id == id }) {
            prompts[i].text = trimmed
            savePrompts()
        }
    }

    /// Reorders within a section. `sourceID` is the prompt being moved,
    /// `destinationID` is the prompt it should land *before* (or nil = end of section).
    func move(sourceID: UUID, before destinationID: UUID?, in section: PromptSectionKind) {
        guard let sourceIndex = prompts.firstIndex(where: { $0.id == sourceID }) else { return }
        let source = prompts[sourceIndex]
        let sourceSection: PromptSectionKind = source.isRecurring ? .recurring : .oneShot
        guard sourceSection == section else { return }

        prompts.remove(at: sourceIndex)

        if let destinationID = destinationID,
           let destinationIndex = prompts.firstIndex(where: { $0.id == destinationID }) {
            prompts.insert(source, at: destinationIndex)
        } else {
            // Append after the last item in the section
            if let lastIndex = prompts.lastIndex(where: {
                ($0.isRecurring ? PromptSectionKind.recurring : .oneShot) == section
            }) {
                prompts.insert(source, at: lastIndex + 1)
            } else {
                prompts.append(source)
            }
        }
        savePrompts()
    }

    /// Records an insertion of `prompt` into an entry. Updates lastAnsweredAt,
    /// removes the prompt if it's one-shot, and prepends a history entry.
    func recordInsertion(of prompt: Prompt, intoEntry entryFilename: String?) {
        let now = Date()
        history.insert(
            PromptHistoryEntry(promptText: prompt.text, answeredAt: now, entryFilename: entryFilename),
            at: 0
        )
        saveHistory()

        if let i = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[i].lastAnsweredAt = now
            if !prompts[i].isRecurring {
                prompts.remove(at: i)
            }
        }
        savePrompts()
    }

    // MARK: - Convenience

    var recurringPrompts: [Prompt] { prompts.filter { $0.isRecurring } }
    var oneShotPrompts: [Prompt] { prompts.filter { !$0.isRecurring } }
}

// MARK: - Date formatting

enum PromptDateFormat {
    static func relative(from date: Date?, now: Date = Date()) -> String? {
        guard let date = date else { return nil }
        let days = Int(round(now.timeIntervalSince(date) / 86_400))
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(Int(round(Double(days) / 7)))w ago" }
        return "\(Int(round(Double(days) / 30)))mo ago"
    }

    static func short(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date).lowercased()
    }
}

// MARK: - Notifications for cross-component signals

extension Notification.Name {
    /// Posted when the global hotkey (⌘⇧P) is pressed. Tells ContentView to
    /// open the prompts card and focus the add-prompt input.
    static let freewriteOpenAddPrompt = Notification.Name("freewriteOpenAddPrompt")
}
