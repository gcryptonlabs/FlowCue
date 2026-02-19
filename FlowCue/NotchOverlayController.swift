//
//  NotchOverlayController.swift
//  FlowCue
//
//  Main coordinator — delegates to OverlayWindowManager, MouseTracker,
//  OverlayAnimationController, and PageManager.
//

import AppKit
import SwiftUI
import Combine

// MARK: - Data Models

@Observable
class NotchFrameTracker {
    var visibleHeight: CGFloat = 37 {
        didSet { updatePanel() }
    }
    var visibleWidth: CGFloat = 200 {
        didSet { updatePanel() }
    }
    weak var panel: NSPanel?
    var screenMidX: CGFloat = 0
    var screenMaxY: CGFloat = 0
    var menuBarHeight: CGFloat = 0

    func updatePanel() {
        guard let panel else { return }
        let x = screenMidX - visibleWidth / 2
        let y = screenMaxY - visibleHeight
        panel.setFrame(NSRect(x: x, y: y, width: visibleWidth, height: visibleHeight), display: false)
    }
}

@Observable
class OverlayContent {
    var words: [String] = []
    var totalCharCount: Int = 0
    var hasNextPage: Bool = false

    // Page picker
    var pageCount: Int = 1
    var currentPageIndex: Int = 0
    var pagePreviews: [String] = []
    var showPagePicker: Bool = false
    var jumpToPageIndex: Int? = nil
}

// MARK: - Main Coordinator

class NotchOverlayController: NSObject {
    private var panel: NSPanel?
    let speechRecognizer = SpeechRecognizer()
    let overlayContent = OverlayContent()
    var onComplete: (() -> Void)?

    // Extracted modules
    private let windowManager = OverlayWindowManager()
    private let mouseTracker = MouseTracker()
    private let animationController = OverlayAnimationController()
    private let pageManager = PageManager()

    private var frameTracker: NotchFrameTracker?
    private var stopButtonPanel: NSPanel?
    private var escMonitor: Any?

    func show(text: String, hasNextPage: Bool = false, onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
        forceClose()

        // Configure animation callbacks
        animationController.onNextPage = { [weak self] in
            FlowCueService.shared.advanceToNextPage()
        }
        animationController.onPageJump = { index in
            FlowCueService.shared.jumpToPage(index: index)
        }
        animationController.onDismissComplete = { [weak self] in
            self?.onComplete?()
        }
        animationController.observeDismiss(
            speechRecognizer: speechRecognizer,
            overlayContent: overlayContent,
            cleanup: { [weak self] in self?.cleanupPanel() }
        )

        // Populate content
        pageManager.populateContent(overlayContent, text: text, hasNextPage: hasNextPage)

        let settings = NotchSettings.shared
        let screen: NSScreen
        switch settings.notchDisplayMode {
        case .followMouse:
            screen = windowManager.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens[0]
        case .fixedDisplay:
            screen = NSScreen.screens.first(where: { $0.displayID == settings.pinnedScreenID }) ?? NSScreen.main ?? NSScreen.screens[0]
        }

        // Create appropriate panel
        if settings.overlayMode == .fullscreen {
            let fsScreen: NSScreen
            if settings.fullscreenScreenID != 0,
               let match = NSScreen.screens.first(where: { $0.displayID == settings.fullscreenScreenID }) {
                fsScreen = match
            } else {
                fsScreen = screen
            }
            panel = windowManager.createFullscreenPanel(
                settings: settings, screen: fsScreen,
                overlayContent: overlayContent, speechRecognizer: speechRecognizer
            )
            installKeyMonitor()
        } else if settings.overlayMode == .floating && settings.followCursorWhenUndocked {
            panel = windowManager.createFollowCursorPanel(
                settings: settings,
                overlayContent: overlayContent, speechRecognizer: speechRecognizer
            )
            mouseTracker.startCursorTracking(panel: panel!)
            installKeyMonitor()
            stopButtonPanel = windowManager.createStopButton(on: screen) { [weak self] in
                self?.dismiss()
            }
        } else if settings.overlayMode == .floating {
            panel = windowManager.createFloatingPanel(
                settings: settings, screenFrame: screen.frame,
                overlayContent: overlayContent, speechRecognizer: speechRecognizer
            )
            installKeyMonitor()
        } else {
            // Pinned
            let tracker = NotchFrameTracker()
            self.frameTracker = tracker
            panel = windowManager.createPinnedPanel(
                settings: settings, screen: screen,
                overlayContent: overlayContent, speechRecognizer: speechRecognizer,
                frameTracker: tracker
            )
            if settings.notchDisplayMode == .followMouse {
                mouseTracker.onScreenChanged = { [weak self] newScreen in
                    self?.repositionToScreen(newScreen)
                }
                mouseTracker.startMouseTracking(initialScreenID: screen.displayID)
            }
        }

        // Start speech recognition (not needed for classic mode)
        if settings.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
    }

    func updateContent(text: String, hasNextPage: Bool) {
        pageManager.resetSpeechState(speechRecognizer)
        pageManager.populateContent(overlayContent, text: text, hasNextPage: hasNextPage)

        if NotchSettings.shared.listeningMode != .classic {
            speechRecognizer.start(with: text)
        }
    }

    func dismiss() {
        animationController.triggerDismiss(speechRecognizer: speechRecognizer) { [weak self] in
            self?.cleanupPanel()
        }
    }

    var isShowing: Bool {
        panel != nil
    }

    // MARK: - Private

    private func repositionToScreen(_ screen: NSScreen) {
        guard let panel, let frameTracker else { return }
        let screenFrame = screen.frame
        frameTracker.screenMidX = screenFrame.midX
        frameTracker.screenMaxY = screenFrame.maxY

        let w = frameTracker.visibleWidth
        let h = frameTracker.visibleHeight
        let x = screenFrame.midX - w / 2
        let y = screenFrame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func cleanupPanel() {
        mouseTracker.stopAll()
        removeStopButton()
        removeEscMonitor()
        panel?.orderOut(nil)
        panel = nil
        frameTracker = nil
        speechRecognizer.shouldDismiss = false
    }

    private func forceClose() {
        mouseTracker.stopAll()
        removeStopButton()
        removeEscMonitor()
        animationController.cancelObservers()
        speechRecognizer.forceStop()
        speechRecognizer.recognizedCharCount = 0
        panel?.orderOut(nil)
        panel = nil
        frameTracker = nil
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
    }

    private func installKeyMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // ESC
                if self.overlayContent.showPagePicker {
                    self.overlayContent.showPagePicker = false
                    return nil
                }
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func removeStopButton() {
        stopButtonPanel?.orderOut(nil)
        stopButtonPanel = nil
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
    }
}

// MARK: - Floating Stop Button View

struct StopButtonView: View {
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.red.opacity(0.85))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dynamic Island Shape (concave top corners, convex bottom corners)

struct DynamicIslandShape: Shape {
    var topInset: CGFloat = 16
    var bottomRadius: CGFloat = 18

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topInset, bottomRadius) }
        set {
            topInset = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let t = topInset
        let br = bottomRadius
        var p = Path()

        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: t, y: h - br))
        p.addQuadCurve(to: CGPoint(x: t + br, y: h), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: w - t - br, y: h))
        p.addQuadCurve(to: CGPoint(x: w - t, y: h - br), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Glass Effect View

struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

// MARK: - Overlay SwiftUI View (Pinned / Notch mode)

struct NotchOverlayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let menuBarHeight: CGFloat
    let baseTextHeight: CGFloat
    let maxExtraHeight: CGFloat
    var frameTracker: NotchFrameTracker

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    @State private var expansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var extraHeight: CGFloat = 0
    @State private var dragStartHeight: CGFloat = -1
    @State private var isHovering: Bool = false

    @State private var timerWordProgress: Double = 0
    @State private var isPaused: Bool = false
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    @State private var countdownRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil

    private let topInset: CGFloat = 16
    private let collapsedInset: CGFloat = 8
    private let notchHeight: CGFloat = 37
    private let notchWidth: CGFloat = 200

    private var listeningMode: ListeningMode { NotchSettings.shared.listeningMode }

    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) {
            offset += words[i].count + 1
        }
        if wholeWord < words.count {
            offset += Int(Double(words[wholeWord].count) * frac)
        }
        return min(offset, totalCharCount)
    }

    private func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end {
                let frac = Double(charOffset - offset) / Double(max(1, word.count))
                return Double(i) + frac
            }
            offset = end + 1
        }
        return Double(words.count)
    }

    private var effectiveCharCount: Int {
        switch listeningMode {
        case .wordTracking: return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused: return charOffsetForWordProgress(timerWordProgress)
        }
    }

    var isDone: Bool { totalCharCount > 0 && effectiveCharCount >= totalCharCount }

    private var currentTopInset: CGFloat { collapsedInset + (topInset - collapsedInset) * expansion }
    private var currentBottomRadius: CGFloat { 8 + (18 - 8) * expansion }

    var body: some View {
        GeometryReader { geo in
            let targetHeight = menuBarHeight + baseTextHeight + extraHeight
            let currentHeight = notchHeight + (targetHeight - notchHeight) * expansion
            let currentWidth = notchWidth + (geo.size.width - notchWidth) * expansion

            ZStack(alignment: .top) {
                DynamicIslandShape(topInset: currentTopInset, bottomRadius: currentBottomRadius)
                    .fill(.black.opacity(0.75))
                    .frame(width: currentWidth, height: currentHeight)

                if contentVisible {
                    VStack(spacing: 0) {
                        HStack {
                            EstimatedTimeView(
                                totalWords: words.count,
                                highlightedCharCount: effectiveCharCount,
                                totalCharCount: totalCharCount,
                                fontSize: 11
                            )
                            .padding(.leading, 12)
                            Spacer()
                            WPMIndicatorView(
                                startTime: speechRecognizer.speechStartTime,
                                wordsCompleted: Int(Double(words.count) * (totalCharCount > 0 ? Double(effectiveCharCount) / Double(totalCharCount) : 0)),
                                fontSize: 11
                            )
                            Spacer()
                            if NotchSettings.shared.showElapsedTime {
                                ElapsedTimeView(fontSize: 11)
                                    .padding(.trailing, 12)
                            }
                        }
                        .frame(height: menuBarHeight)

                        if content.showPagePicker {
                            pagePickerView
                        } else if isDone {
                            doneView
                        } else {
                            prompterView
                        }
                    }
                    .padding(.horizontal, topInset)
                    .frame(width: currentWidth, height: targetHeight)
                    .clipped()
                    .transition(.opacity)
                }
            }
            .frame(width: currentWidth, height: currentHeight, alignment: .top)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onChange(of: extraHeight) { _, _ in updateFrameTracker() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { expansion = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.25)) { contentVisible = true }
            }
        }
        .onChange(of: speechRecognizer.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                withAnimation(.easeIn(duration: 0.15)) { contentVisible = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeIn(duration: 0.3)) { expansion = 0 }
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: isDone)
        .onChange(of: isDone) { _, done in
            if done {
                speechRecognizer.stop()
                if !hasNextPage {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        speechRecognizer.shouldDismiss = true
                    }
                } else if NotchSettings.shared.autoNextPage {
                    startCountdown()
                }
            } else {
                cancelCountdown()
            }
        }
        .onReceive(scrollTimer) { _ in
            guard !isDone, !isUserScrolling else { return }
            let speed = NotchSettings.shared.scrollSpeed
            switch listeningMode {
            case .classic:
                if !isPaused { timerWordProgress += speed * 0.05 }
            case .silencePaused:
                if !isPaused && speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.05
                }
            case .wordTracking: break
            }
        }
        .onChange(of: content.totalCharCount) { _, _ in timerWordProgress = 0 }
    }

    private func updateFrameTracker() {
        frameTracker.visibleHeight = menuBarHeight + baseTextHeight + extraHeight
        frameTracker.visibleWidth = NotchSettings.shared.notchWidth
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused: return speechRecognizer.isListening
        case .classic: return !isPaused
        }
    }

    private var prompterView: some View {
        VStack(spacing: 0) {
            SpeechScrollView(
                words: words,
                highlightedCharCount: effectiveCharCount,
                font: NotchSettings.shared.font,
                highlightColor: NotchSettings.shared.fontColorPreset.color,
                onWordTap: { charOffset in
                    if listeningMode == .wordTracking {
                        speechRecognizer.jumpTo(charOffset: charOffset)
                    } else {
                        timerWordProgress = wordProgressForCharOffset(charOffset)
                    }
                },
                onManualScroll: { scrolling, newProgress in
                    isUserScrolling = scrolling
                    if !scrolling {
                        timerWordProgress = max(0, min(Double(words.count), newProgress))
                    }
                },
                smoothScroll: listeningMode != .wordTracking,
                smoothWordProgress: timerWordProgress,
                isListening: isEffectivelyListening
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))

            Group {
                HStack(alignment: .center, spacing: 8) {
                    AudioWaveformProgressView(
                        levels: speechRecognizer.audioLevels,
                        progress: totalCharCount > 0
                            ? Double(effectiveCharCount) / Double(totalCharCount) : 0
                    )
                    .frame(width: 80, height: 24)
                    .clipped()

                    if listeningMode == .wordTracking {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(speechRecognizer.lastSpokenText.split(separator: " ").suffix(3).joined(separator: " "))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(speechRecognizer.debugStatus)
                                .font(.system(size: 8, weight: .regular, design: .monospaced))
                                .foregroundStyle(.yellow.opacity(0.6))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }

                    if content.pageCount > 1 {
                        Text("\(content.currentPageIndex + 1)/\(content.pageCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))

                        if hasNextPage {
                            Button {
                                speechRecognizer.shouldAdvancePage = true
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(width: 24, height: 24)
                                    .background(.white.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in content.showPagePicker = true }
                            )
                        } else {
                            Button {
                                content.jumpToPageIndex = 0
                            } label: {
                                Image(systemName: "backward.end.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(width: 24, height: 24)
                                    .background(.white.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in content.showPagePicker = true }
                            )
                        }
                    }

                    if listeningMode == .classic {
                        Button { isPaused.toggle() } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isPaused ? .white.opacity(0.6) : Color.accentColor.opacity(0.9))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            if speechRecognizer.isListening { speechRecognizer.stop() }
                            else { speechRecognizer.resume() }
                        } label: {
                            Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(speechRecognizer.isListening ? Color.accentColor.opacity(0.9) : .white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        speechRecognizer.forceStop()
                        speechRecognizer.shouldDismiss = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 24)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                if isHovering {
                    VStack(spacing: 0) {
                        Spacer().frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 36, height: 4)
                        Spacer().frame(height: 8)
                    }
                    .frame(height: 16)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartHeight < 0 { dragStartHeight = extraHeight }
                                extraHeight = max(0, min(maxExtraHeight, dragStartHeight + value.translation.height))
                            }
                            .onEnded { _ in dragStartHeight = -1 }
                    )
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() }
                        else { NSCursor.pop() }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) { isHovering = hovering }
            }
            .transition(.opacity)
        }
    }

    private var pagePickerView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Jump to page")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 2)

                ForEach(0..<content.pageCount, id: \.self) { i in
                    let preview = i < content.pagePreviews.count ? content.pagePreviews[i] : ""
                    if !preview.isEmpty {
                        Button {
                            content.jumpToPageIndex = i
                            content.showPagePicker = false
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(i + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(i == content.currentPageIndex ? Color.accentColor : .white.opacity(0.8))
                                    .frame(width: 20)
                                Text(preview)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(i == content.currentPageIndex ? Color.accentColor.opacity(0.7) : .white.opacity(0.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(i == content.currentPageIndex ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Tap a page to jump")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .transition(.opacity)
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownRemaining = NotchSettings.shared.autoNextPageDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                self.countdownRemaining -= 1
                if self.countdownRemaining <= 0 {
                    timer.invalidate()
                    self.countdownTimer = nil
                    self.speechRecognizer.shouldAdvancePage = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private var doneView: some View {
        VStack {
            Spacer()
            if hasNextPage {
                VStack(spacing: 6) {
                    if countdownRemaining > 0 {
                        Text("\(countdownRemaining)")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: countdownRemaining)
                    }
                    Button {
                        cancelCountdown()
                        speechRecognizer.shouldAdvancePage = true
                    } label: {
                        VStack(spacing: 4) {
                            Text("Next Page")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Image(systemName: "forward.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Done!")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Floating Overlay View

struct FloatingOverlayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let baseHeight: CGFloat
    var followingCursor: Bool = false

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    @State private var appeared = false
    @State private var countdownRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil
    @State private var timerWordProgress: Double = 0
    @State private var isPaused: Bool = false
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var listeningMode: ListeningMode { NotchSettings.shared.listeningMode }

    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) { offset += words[i].count + 1 }
        if wholeWord < words.count { offset += Int(Double(words[wholeWord].count) * frac) }
        return min(offset, totalCharCount)
    }

    private func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end {
                return Double(i) + Double(charOffset - offset) / Double(max(1, word.count))
            }
            offset = end + 1
        }
        return Double(words.count)
    }

    private var effectiveCharCount: Int {
        switch listeningMode {
        case .wordTracking: return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused: return charOffsetForWordProgress(timerWordProgress)
        }
    }

    var isDone: Bool { totalCharCount > 0 && effectiveCharCount >= totalCharCount }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused: return speechRecognizer.isListening
        case .classic: return !isPaused
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if content.showPagePicker {
                floatingPagePickerView
            } else if isDone {
                floatingDoneView
            } else {
                floatingPrompterView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            EstimatedTimeView(
                totalWords: words.count,
                highlightedCharCount: effectiveCharCount,
                totalCharCount: totalCharCount,
                fontSize: 11
            )
            .padding(.top, 6)
            .padding(.leading, 10)
        }
        .overlay(alignment: .top) {
            WPMIndicatorView(
                startTime: speechRecognizer.speechStartTime,
                wordsCompleted: Int(Double(words.count) * (totalCharCount > 0 ? Double(effectiveCharCount) / Double(totalCharCount) : 0)),
                fontSize: 11
            )
            .padding(.top, 6)
        }
        .overlay(alignment: .topTrailing) {
            if NotchSettings.shared.showElapsedTime {
                ElapsedTimeView(fontSize: 11)
                    .padding(.top, 6)
                    .padding(.trailing, 10)
            }
        }
        .background(
            Group {
                if NotchSettings.shared.floatingGlassEffect {
                    ZStack {
                        GlassEffectView()
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.black.opacity(NotchSettings.shared.glassOpacity))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.75))
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.9)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        }
        .onChange(of: speechRecognizer.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                withAnimation(.easeIn(duration: 0.25)) { appeared = false }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: isDone)
        .onChange(of: isDone) { _, done in
            if done {
                speechRecognizer.stop()
                if !hasNextPage {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        speechRecognizer.shouldDismiss = true
                    }
                } else if followingCursor || NotchSettings.shared.autoNextPage {
                    startCountdown()
                }
            } else {
                cancelCountdown()
            }
        }
        .onReceive(scrollTimer) { _ in
            guard !isDone, !isUserScrolling else { return }
            let speed = NotchSettings.shared.scrollSpeed
            switch listeningMode {
            case .classic:
                if !isPaused { timerWordProgress += speed * 0.05 }
            case .silencePaused:
                if !isPaused && speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.05
                }
            case .wordTracking: break
            }
        }
        .onChange(of: content.totalCharCount) { _, _ in timerWordProgress = 0 }
    }

    private var floatingPrompterView: some View {
        VStack(spacing: 0) {
            SpeechScrollView(
                words: words,
                highlightedCharCount: effectiveCharCount,
                font: NotchSettings.shared.font,
                highlightColor: NotchSettings.shared.fontColorPreset.color,
                onWordTap: { charOffset in
                    if listeningMode == .wordTracking {
                        speechRecognizer.jumpTo(charOffset: charOffset)
                    } else {
                        timerWordProgress = wordProgressForCharOffset(charOffset)
                    }
                },
                onManualScroll: { scrolling, newProgress in
                    isUserScrolling = scrolling
                    if !scrolling {
                        timerWordProgress = max(0, min(Double(words.count), newProgress))
                    }
                },
                smoothScroll: listeningMode != .wordTracking,
                smoothWordProgress: timerWordProgress,
                isListening: isEffectivelyListening
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(alignment: .center, spacing: 8) {
                AudioWaveformProgressView(
                    levels: speechRecognizer.audioLevels,
                    progress: totalCharCount > 0
                        ? Double(effectiveCharCount) / Double(totalCharCount) : 0
                )
                .frame(width: 160, height: 24)

                if listeningMode == .wordTracking {
                    Text(speechRecognizer.lastSpokenText.split(separator: " ").suffix(3).joined(separator: " "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }

                if !followingCursor && content.pageCount > 1 {
                    Text("\(content.currentPageIndex + 1)/\(content.pageCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))

                    if hasNextPage {
                        Button {
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in content.showPagePicker = true }
                        )
                    } else {
                        Button {
                            content.jumpToPageIndex = 0
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in content.showPagePicker = true }
                        )
                    }
                }

                if !followingCursor {
                    if listeningMode == .classic {
                        Button { isPaused.toggle() } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isPaused ? .white.opacity(0.6) : Color.accentColor.opacity(0.9))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            if speechRecognizer.isListening { speechRecognizer.stop() }
                            else { speechRecognizer.resume() }
                        } label: {
                            Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(speechRecognizer.isListening ? Color.accentColor.opacity(0.9) : .white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        speechRecognizer.forceStop()
                        speechRecognizer.shouldDismiss = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownRemaining = NotchSettings.shared.autoNextPageDelay
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownRemaining -= 1
                if countdownRemaining <= 0 {
                    timer.invalidate()
                    countdownTimer = nil
                    speechRecognizer.shouldAdvancePage = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }

    private var floatingPagePickerView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Jump to page")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 4)

                ForEach(0..<content.pageCount, id: \.self) { i in
                    let preview = i < content.pagePreviews.count ? content.pagePreviews[i] : ""
                    if !preview.isEmpty {
                        Button {
                            content.jumpToPageIndex = i
                            content.showPagePicker = false
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundStyle(i == content.currentPageIndex ? Color.accentColor : .white.opacity(0.8))
                                    .frame(width: 24)
                                Text(preview)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(i == content.currentPageIndex ? Color.accentColor.opacity(0.7) : .white.opacity(0.5))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(i == content.currentPageIndex ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Tap a page to jump")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .transition(.opacity)
    }

    private var floatingDoneView: some View {
        VStack {
            Spacer()
            if hasNextPage {
                VStack(spacing: 6) {
                    if countdownRemaining > 0 {
                        Text("\(countdownRemaining)")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: countdownRemaining)
                    }
                    if followingCursor {
                        Text("Next Page")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Button {
                            cancelCountdown()
                            speechRecognizer.shouldAdvancePage = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Next Page")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Done!")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .transition(.scale.combined(with: .opacity))
    }
}
