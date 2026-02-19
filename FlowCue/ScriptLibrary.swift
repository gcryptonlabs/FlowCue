//
//  ScriptLibrary.swift
//  FlowCue
//
//  Script library model and JSON persistence.
//

import Foundation

struct Script: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var language: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, content: String, language: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.language = language
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Observable
class ScriptLibrary {
    static let shared = ScriptLibrary()

    var scripts: [Script] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FlowCue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("scripts.json")
        load()
    }

    func save(_ script: Script) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = script
        } else {
            scripts.append(script)
        }
        persist()
    }

    func delete(_ script: Script) {
        scripts.removeAll { $0.id == script.id }
        persist()
    }

    func rename(_ script: Script, to newTitle: String) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index].title = newTitle
        scripts[index].updatedAt = Date()
        persist()
    }

    /// Save pages as a new script with auto-generated title
    func saveFromPages(_ pages: [String]) {
        let combined = pages.joined(separator: "\n\n---\n\n")
        let title = generateTitle(from: combined)
        let script = Script(title: title, content: combined)
        save(script)
    }

    /// Load a script's content back into pages
    func loadIntoPages(_ script: Script) -> [String] {
        let separator = "\n\n---\n\n"
        if script.content.contains(separator) {
            return script.content.components(separatedBy: separator)
        }
        return [script.content]
    }

    private func generateTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let preview = String(firstLine.prefix(40))
        if preview.isEmpty { return "Untitled Script" }
        return preview + (firstLine.count > 40 ? "…" : "")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            scripts = try JSONDecoder().decode([Script].self, from: data)
        } catch {
            scripts = []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(scripts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silently fail — not critical
        }
    }
}
