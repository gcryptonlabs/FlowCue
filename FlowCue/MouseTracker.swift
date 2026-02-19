//
//  MouseTracker.swift
//  FlowCue
//
//  Extracted from NotchOverlayController.swift — cursor following and screen tracking.
//

import AppKit
import Combine

class MouseTracker {
    private var mouseTrackingTimer: AnyCancellable?
    private var cursorTrackingTimer: AnyCancellable?
    private var currentScreenID: UInt32 = 0

    var onScreenChanged: ((NSScreen) -> Void)?

    func startMouseTracking(initialScreenID: UInt32) {
        currentScreenID = initialScreenID
        mouseTrackingTimer?.cancel()
        mouseTrackingTimer = Timer.publish(every: 0.3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkMouseScreen()
            }
    }

    func stopMouseTracking() {
        mouseTrackingTimer?.cancel()
        mouseTrackingTimer = nil
    }

    func startCursorTracking(panel: NSPanel) {
        cursorTrackingTimer?.cancel()
        cursorTrackingTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateCursorPosition(panel: panel)
            }
    }

    func stopCursorTracking() {
        cursorTrackingTimer?.cancel()
        cursorTrackingTimer = nil
    }

    func stopAll() {
        stopMouseTracking()
        stopCursorTracking()
    }

    private func updateCursorPosition(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let cursorOffset: CGFloat = 8
        let x = mouse.x + cursorOffset
        let h = panel.frame.height
        var y = mouse.y - h
        let w = panel.frame.width

        // Keep panel below the menu bar so the status bar stop button stays visible
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let menuBarBottom = screen.visibleFrame.maxY
            if y + h > menuBarBottom {
                y = menuBarBottom - h
            }
        }

        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }

    private func checkMouseScreen() {
        let mouseLocation = NSEvent.mouseLocation
        guard let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) else { return }
        let mouseScreenID = mouseScreen.displayID
        guard mouseScreenID != currentScreenID else { return }

        currentScreenID = mouseScreenID
        onScreenChanged?(mouseScreen)
    }
}
