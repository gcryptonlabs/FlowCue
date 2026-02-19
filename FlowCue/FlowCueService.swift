//
//  FlowCueService.swift
//  FlowCue
//
//  Created by FlowCue Team.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

class FlowCueService: NSObject, ObservableObject {
    static let shared = FlowCueService()
    let overlayController = NotchOverlayController()
    let externalDisplayController = ExternalDisplayController()
    let browserServer = BrowserServer()
    var onOverlayDismissed: (() -> Void)?
    var launchedExternally = false

    @Published var pages: [String] = [""]
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []

    var hasNextPage: Bool {
        for i in (currentPageIndex + 1)..<pages.count {
            if !pages[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var currentPageText: String {
        guard currentPageIndex < pages.count else { return "" }
        return pages[currentPageIndex]
    }

    func readText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        launchedExternally = true
        hideMainWindow()

        overlayController.show(text: trimmed, hasNextPage: hasNextPage) { [weak self] in
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()

        // Also show on external display if configured (same parsing as overlay)
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            hasNextPage: hasNextPage
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: hasNextPage
            )
        }
    }

    func readCurrentPage() {
        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        readPages.insert(currentPageIndex)
        readText(trimmed)
    }

    func advanceToNextPage() {
        // Skip empty pages
        var nextIndex = currentPageIndex + 1
        while nextIndex < pages.count {
            let text = pages[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            nextIndex += 1
        }
        guard nextIndex < pages.count else { return }
        jumpToPage(index: nextIndex)
    }

    func jumpToPage(index: Int) {
        guard index >= 0 && index < pages.count else { return }
        let text = pages[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Mute mic before switching page content
        let wasListening = overlayController.speechRecognizer.isListening
        if wasListening {
            overlayController.speechRecognizer.stop()
        }

        currentPageIndex = index
        readPages.insert(currentPageIndex)

        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Update content in-place without recreating the panel
        overlayController.updateContent(text: trimmed, hasNextPage: hasNextPage)
        updatePageInfo()

        // Also update external display content in-place
        let words = splitTextIntoWords(trimmed)
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.totalCharCount = words.joined(separator: " ").count
        externalDisplayController.overlayContent.hasNextPage = hasNextPage

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: words.joined(separator: " ").count,
                hasNextPage: hasNextPage
            )
        }

        // Unmute after new page content is loaded
        if wasListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.overlayController.speechRecognizer.resume()
            }
        }
    }

    func updatePageInfo() {
        let content = overlayController.overlayContent
        content.pageCount = pages.count
        content.currentPageIndex = currentPageIndex
        content.pagePreviews = pages.enumerated().map { (i, text) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let preview = String(trimmed.prefix(40))
            return preview + (trimmed.count > 40 ? "…" : "")
        }
    }

    func startAllPages() {
        readPages.removeAll()
        currentPageIndex = 0
        readCurrentPage()
    }

    func hideMainWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
            }
        }
    }

    @Published var currentFileURL: URL?
    @Published var savedPages: [String] = [""]

    // MARK: - File Operations

    func saveFile() {
        if let url = currentFileURL {
            saveToURL(url)
        } else {
            saveFileAs()
        }
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "flowcue")!]
        panel.nameFieldStringValue = "Untitled.flowcue"
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToURL(url)
        }
    }

    private func saveToURL(_ url: URL) {
        do {
            let data = try JSONEncoder().encode(pages)
            try data.write(to: url, options: .atomic)
            currentFileURL = url
            savedPages = pages
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    var hasUnsavedChanges: Bool {
        pages != savedPages
    }

    func openFile() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "flowcue")!,
            .init(filenameExtension: "key")!,
            .init(filenameExtension: "pptx")!,
            .plainText,
            .init(filenameExtension: "md")!,
            .rtf,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "key" {
                let alert = NSAlert()
                alert.messageText = "Keynote files can't be imported directly"
                alert.informativeText = "Please export your Keynote presentation as PowerPoint (.pptx) first:\n\nIn Keynote: File → Export To → PowerPoint"
                alert.alertStyle = .informational
                alert.runModal()
            } else if ext == "pptx" {
                self?.importPresentation(from: url)
            } else if ext == "txt" || ext == "md" {
                self?.importTextFile(from: url)
            } else if ext == "rtf" {
                self?.importRTFFile(from: url)
            } else {
                self?.openFileAtURL(url)
            }
        }
    }

    func importTextFile(from url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            pages = [trimmed]
            savedPages = pages
            currentPageIndex = 0
            readPages.removeAll()
            currentFileURL = nil
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Error"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func importRTFFile(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else {
                let alert = NSAlert()
                alert.messageText = "Import Error"
                alert.informativeText = "Could not read RTF file."
                alert.runModal()
                return
            }
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            pages = [text]
            savedPages = pages
            currentPageIndex = 0
            readPages.removeAll()
            currentFileURL = nil
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Error"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func importPresentation(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    self?.pages = notes
                    self?.savedPages = notes
                    self?.currentPageIndex = 0
                    self?.readPages.removeAll()
                    self?.currentFileURL = nil
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Import Error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    func importFromURL() {
        let alert = NSAlert()
        alert.messageText = "Import from URL"
        alert.informativeText = "Paste a web page URL to import its text content.\nWorks with Notion public pages, Google Docs (published), blog posts, and other web pages."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.placeholderString = "https://..."
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let urlString = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            let err = NSAlert()
            err.messageText = "Invalid URL"
            err.informativeText = "Please enter a valid web URL starting with http:// or https://"
            err.runModal()
            return
        }

        guard confirmDiscardIfNeeded() else { return }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        let err = NSAlert()
                        err.messageText = "Import Failed"
                        err.informativeText = "Could not fetch the URL. Check the link and try again."
                        err.runModal()
                    }
                    return
                }

                let html = String(data: data, encoding: .utf8) ?? ""
                let text = Self.extractTextFromHTML(html)
                guard !text.isEmpty else {
                    await MainActor.run {
                        let err = NSAlert()
                        err.messageText = "No Content"
                        err.informativeText = "The page didn't contain any readable text."
                        err.runModal()
                    }
                    return
                }

                await MainActor.run {
                    pages = [text]
                    savedPages = pages
                    currentPageIndex = 0
                    readPages.removeAll()
                    currentFileURL = nil
                }
            } catch {
                await MainActor.run {
                    let err = NSAlert()
                    err.messageText = "Import Failed"
                    err.informativeText = error.localizedDescription
                    err.runModal()
                }
            }
        }
    }

    static func extractTextFromHTML(_ html: String) -> String {
        // Remove script and style blocks
        var cleaned = html
        let blockPatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<nav[^>]*>[\\s\\S]*?</nav>",
            "<footer[^>]*>[\\s\\S]*?</footer>",
            "<header[^>]*>[\\s\\S]*?</header>",
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
            }
        }

        // Replace block elements with newlines
        let blockElements = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "<br>", "<br/>", "<br />", "</li>", "</tr>"]
        for tag in blockElements {
            cleaned = cleaned.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Strip all remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
        }

        // Decode HTML entities
        cleaned = cleaned
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse whitespace and blank lines
        let lines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n\n")
    }

    /// Returns true if it's safe to proceed (saved, discarded, or no changes).
    /// Returns false if the user cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before opening another file?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveFile()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func openFileAtURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loadedPages = try JSONDecoder().decode([String].self, from: data)
            guard !loadedPages.isEmpty else { return }
            pages = loadedPages
            savedPages = loadedPages
            currentPageIndex = 0
            readPages.removeAll()
            currentFileURL = url
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Browser Server

    func updateBrowserServer() {
        if NotchSettings.shared.browserServerEnabled {
            if !browserServer.isRunning {
                browserServer.start()
            }
        } else {
            browserServer.stop()
        }
    }

    // macOS Services handler
    @objc func readInFlowCue(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text found on pasteboard" as NSString
            return
        }
        readText(text)
    }

    // URL scheme handler: flowcue://read?text=Hello%20World
    func handleURL(_ url: URL) {
        guard url.scheme == "flowcue" else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                readText(textParam)
            }
        }
    }
}
