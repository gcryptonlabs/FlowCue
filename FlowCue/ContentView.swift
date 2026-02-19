//
//  ContentView.swift
//  FlowCue
//
//  Created by FlowCue Team.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var service = FlowCueService.shared
    @State private var isRunning = false
    @State private var isDroppingPresentation = false
    @State private var dropError: String?
    @State private var dropAlertTitle: String = "Import Error"
    @State private var showSettingsSidebar = false
    @State private var showAbout = false
    @State private var isExpandingAI = false
    @State private var aiError: String?
    @FocusState private var isTextFocused: Bool

    private let defaultText = """
Welcome to FlowCue! This is your personal teleprompter that sits right below your MacBook's notch. [smile]

As you read aloud, the text will highlight in real-time, following your voice. The speech recognition matches your words and keeps track of your progress. [pause]

You can pause at any time, go back and re-read sections, and the highlighting will follow along. When you finish reading all the text, the overlay will automatically close with a smooth animation. [nod]

Try reading this passage out loud to see how the highlighting works. The waveform at the bottom shows your voice activity, and you'll see the last few words you spoke displayed next to it.

Happy presenting! [wave]
"""

    private var languageLabel: String {
        let locale = NotchSettings.shared.speechLocale
        return Locale.current.localizedString(forIdentifier: locale)
            ?? locale
    }

    private var currentText: Binding<String> {
        Binding(
            get: {
                guard service.currentPageIndex < service.pages.count else { return "" }
                return service.pages[service.currentPageIndex]
            },
            set: { newValue in
                guard service.currentPageIndex < service.pages.count else { return }
                service.pages[service.currentPageIndex] = newValue
            }
        )
    }

    private var hasAnyContent: Bool {
        service.pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Settings sidebar
                if showSettingsSidebar {
                    SettingsView(
                        settings: NotchSettings.shared,
                        isSidebar: true,
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSettingsSidebar = false
                            }
                        }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                // Sidebar with page squares
                if service.pages.count > 1 {
                    pageSidebar
                }

                // Main content area
                ZStack {
                    TextEditor(text: currentText)
                        .font(.system(size: 15, weight: .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .focused($isTextFocused)

                    // Floating action button (bottom-right)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                if isRunning {
                                    stop()
                                } else {
                                    run()
                                }
                            } label: {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(isRunning ? Color.red : Color.accentColor)
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isRunning && !hasAnyContent)
                            .opacity(!hasAnyContent && !isRunning ? 0.4 : 1)
                        }
                        .padding(16)
                    }
                }
            }

            // Drop zone overlay — sits on top so TextEditor doesn't steal the drop
            if isDroppingPresentation {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Import File")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("PowerPoint, Text, Markdown, RTF")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 12)))
                )
                .padding(8)
            }

            // Invisible drop target covering entire window
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $isDroppingPresentation) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let ext = url.pathExtension.lowercased()
                        if ext == "key" {
                            DispatchQueue.main.async {
                                dropAlertTitle = "Conversion Required"
                                dropError = "Keynote files can't be imported directly. Please export your Keynote presentation as PowerPoint (.pptx) first, then drop the exported file here."
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            self.handleFileDrop(url: url)
                        }
                    }
                    return true
                }
                .allowsHitTesting(isDroppingPresentation)
        }
        .alert(dropAlertTitle, isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK") { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
        .alert("AI Error", isPresented: Binding(get: { aiError != nil }, set: { if !$0 { aiError = nil } })) {
            Button("OK") { aiError = nil }
            if NotchSettings.shared.aiApiKey.isEmpty {
                Button("Open Settings") {
                    aiError = nil
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsSidebar = true
                    }
                }
            }
        } message: {
            Text(aiError ?? "")
        }
        .frame(minWidth: showSettingsSidebar ? 780 : 480, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let fileURL = service.currentFileURL {
                    Button {
                        service.openFile()
                    } label: {
                        HStack(spacing: 4) {
                            if service.pages != service.savedPages {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 6, height: 6)
                            }
                            Text(fileURL.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        service.pages.append("")
                        service.currentPageIndex = service.pages.count - 1
                    }
                } label: {
                    Label("Page", systemImage: "doc.badge.plus")
                }
                .help("Add new page")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    splitIntoSections()
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                .help("Split into sections")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    expandWithAI()
                } label: {
                    if isExpandingAI {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("AI", systemImage: "sparkles")
                    }
                }
                .disabled(isExpandingAI || !hasAnyContent)
                .help("Expand notes into a script")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsSidebar.toggle()
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showSettingsSidebar.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
            showAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Sync button state when app is re-activated (e.g. dock click)
            isRunning = service.overlayController.isShowing
        }
        .onAppear {
            // Set default text for the first page if empty
            if service.pages.count == 1 && service.pages[0].isEmpty {
                service.pages[0] = defaultText
            }
            // Sync button state with overlay
            if service.overlayController.isShowing {
                isRunning = true
            }
            if FlowCueService.shared.launchedExternally {
                DispatchQueue.main.async {
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(nil)
                    }
                }
            } else {
                isTextFocused = true
            }
        }
    }

    // MARK: - Page Sidebar

    private var pageSidebar: some View {
        VStack(spacing: 0) {
            Text("Pages")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(service.pages.enumerated()), id: \.offset) { index, _ in
                        let isRead = service.readPages.contains(index)
                        let isCurrent = service.currentPageIndex == index
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                service.currentPageIndex = index
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: isCurrent ? .bold : .regular, design: .monospaced))
                                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                                    .frame(width: 16)
                                if let title = pageTitle(for: index) {
                                    Text(title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(isCurrent ? .primary : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer(minLength: 0)
                                if isRead && !isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if service.pages.count > 1 {
                                Button(role: .destructive) {
                                    removePage(at: index)
                                } label: {
                                    Label("Delete Page", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider().padding(.horizontal, 8)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    service.pages.append("")
                    service.currentPageIndex = service.pages.count - 1
                }
            } label: {
                Label("Add Page", systemImage: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: 120)
    }

    // MARK: - Section Helpers

    /// Preview title for a page (first non-empty line, stripped of markdown headers)
    private func pageTitle(for index: Int) -> String? {
        guard index < service.pages.count else { return nil }
        let text = service.pages[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        return String(clean.prefix(20))
    }

    /// Split current page text into multiple pages by `---` or `# ` markers
    private func splitIntoSections() {
        let text = service.pages[service.currentPageIndex]
        let sections = text.components(separatedBy: "\n")
        var pages: [String] = []
        var current: [String] = []

        for line in sections {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("---") && trimmed.allSatisfy({ $0 == "-" || $0 == " " }) {
                // Separator line — flush current section
                let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty { pages.append(block) }
                current = []
            } else if trimmed.hasPrefix("# ") && !current.isEmpty {
                // Header line — start new section (keep header in new section)
                let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty { pages.append(block) }
                current = [line]
            } else {
                current.append(line)
            }
        }
        // Flush remaining
        let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !block.isEmpty { pages.append(block) }

        guard pages.count > 1 else { return }

        // Replace current page with sections
        withAnimation(.easeInOut(duration: 0.2)) {
            let beforeIndex = service.currentPageIndex
            service.pages.remove(at: beforeIndex)
            service.pages.insert(contentsOf: pages, at: beforeIndex)
            service.currentPageIndex = beforeIndex
        }
    }

    // MARK: - AI

    private func expandWithAI() {
        let text = service.pages[service.currentPageIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isExpandingAI = true
        Task {
            do {
                let expanded = try await AIScriptExpander.shared.expand(bulletPoints: text)
                await MainActor.run {
                    service.pages[service.currentPageIndex] = expanded
                    isExpandingAI = false
                }
            } catch {
                await MainActor.run {
                    aiError = error.localizedDescription
                    isExpandingAI = false
                }
            }
        }
    }

    // MARK: - Actions

    private func removePage(at index: Int) {
        guard service.pages.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.pages.remove(at: index)
            if service.currentPageIndex >= service.pages.count {
                service.currentPageIndex = service.pages.count - 1
            } else if service.currentPageIndex > index {
                service.currentPageIndex -= 1
            }
        }
    }

    private func run() {
        guard hasAnyContent else { return }
        // Resign text editor focus before hiding the window to avoid ViewBridge crashes
        isTextFocused = false
        service.onOverlayDismissed = { [self] in
            isRunning = false
            service.readPages.removeAll()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        // Auto-save script to library
        ScriptLibrary.shared.saveFromPages(service.pages)

        service.readPages.removeAll()
        service.currentPageIndex = 0
        service.readCurrentPage()
        isRunning = true
    }

    @State private var isImporting = false

    private func handleFileDrop(url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pptx":
            handlePresentationDrop(url: url)
        case "txt", "md":
            service.importTextFile(from: url)
        case "rtf":
            service.importRTFFile(from: url)
        case "flowcue":
            service.openFileAtURL(url)
        default:
            dropAlertTitle = "Import Error"
            dropError = "Unsupported file type: .\(ext)"
        }
    }

    private func handlePresentationDrop(url: URL) {
        guard service.confirmDiscardIfNeeded() else { return }
        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    service.pages = notes
                    service.savedPages = notes
                    service.currentPageIndex = 0
                    service.readPages.removeAll()
                    service.currentFileURL = nil
                    isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    dropError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    private func stop() {
        service.overlayController.dismiss()
        service.readPages.removeAll()
        isRunning = false
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
    }

    var body: some View {
        VStack(spacing: 20) {
            // App icon
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }

            VStack(spacing: 6) {
                Text("FlowCue")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("v\(appVersion)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text("Smart teleprompter with AI script preparation, real-time voice tracking, and multi-display support.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 20)

            Link(destination: URL(string: "https://github.com/gcryptonlabs/FlowCue")!) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .bold))
                    Text("github.com/gcryptonlabs/FlowCue")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
            }

            Spacer().frame(height: 4)

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Text("GCRYPTON LABS")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(28)
        .frame(width: 340)
        .background(.regularMaterial)
    }
}

#Preview {
    ContentView()
}
