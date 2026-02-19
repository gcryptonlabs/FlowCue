//
//  OverlayWindowManager.swift
//  FlowCue
//
//  Extracted from NotchOverlayController.swift — handles NSPanel creation and positioning.
//

import AppKit
import SwiftUI

class OverlayWindowManager {

    // MARK: - Panel Creation

    func createPinnedPanel(
        settings: NotchSettings,
        screen: NSScreen,
        overlayContent: OverlayContent,
        speechRecognizer: SpeechRecognizer,
        frameTracker: NotchFrameTracker
    ) -> NSPanel {
        let notchWidth = settings.notchWidth
        let textAreaHeight = settings.textAreaHeight
        let maxExtraHeight: CGFloat = 350
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY

        frameTracker.screenMidX = screenFrame.midX
        frameTracker.screenMaxY = screenFrame.maxY
        frameTracker.menuBarHeight = menuBarHeight
        frameTracker.visibleWidth = notchWidth
        frameTracker.visibleHeight = menuBarHeight + textAreaHeight

        let overlayView = NotchOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            menuBarHeight: menuBarHeight,
            baseTextHeight: textAreaHeight,
            maxExtraHeight: maxExtraHeight,
            frameTracker: frameTracker
        )
        let contentView = NSHostingView(rootView: overlayView)

        let targetHeight = menuBarHeight + textAreaHeight
        let targetY = screenFrame.maxY - targetHeight
        let xPosition = screenFrame.midX - notchWidth / 2

        let panel = NSPanel(
            contentRect: NSRect(x: xPosition, y: targetY, width: notchWidth, height: targetHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        frameTracker.panel = panel

        configurePanel(panel, opaque: false, shadow: false, ignoresMouse: false, settings: settings)
        panel.contentView = contentView
        panel.orderFrontRegardless()
        return panel
    }

    func createFollowCursorPanel(
        settings: NotchSettings,
        overlayContent: OverlayContent,
        speechRecognizer: SpeechRecognizer
    ) -> NSPanel {
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight
        let mouse = NSEvent.mouseLocation
        let cursorOffset: CGFloat = 8

        let floatingView = FloatingOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            baseHeight: panelHeight,
            followingCursor: true
        )
        let contentView = NSHostingView(rootView: floatingView)

        let panel = NSPanel(
            contentRect: NSRect(x: mouse.x + cursorOffset, y: mouse.y - panelHeight, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel, opaque: false, shadow: true, ignoresMouse: true, settings: settings)
        panel.contentView = contentView
        panel.orderFrontRegardless()
        return panel
    }

    func createFloatingPanel(
        settings: NotchSettings,
        screenFrame: CGRect,
        overlayContent: OverlayContent,
        speechRecognizer: SpeechRecognizer
    ) -> NSPanel {
        let panelWidth = settings.notchWidth
        let panelHeight = settings.textAreaHeight

        let floatingView = FloatingOverlayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            baseHeight: panelHeight
        )
        let contentView = NSHostingView(rootView: floatingView)

        let panel = NSPanel(
            contentRect: NSRect(
                x: screenFrame.midX - panelWidth / 2,
                y: screenFrame.midY - panelHeight / 2 + 100,
                width: panelWidth,
                height: panelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel, opaque: false, shadow: true, ignoresMouse: false, settings: settings)
        panel.isMovableByWindowBackground = true
        panel.contentView = contentView
        panel.orderFrontRegardless()
        return panel
    }

    func createFullscreenPanel(
        settings: NotchSettings,
        screen: NSScreen,
        overlayContent: OverlayContent,
        speechRecognizer: SpeechRecognizer
    ) -> NSPanel {
        let screenFrame = screen.frame

        let fullscreenView = ExternalDisplayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            mirrorAxis: nil
        )
        let contentView = NSHostingView(rootView: fullscreenView)

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.sharingType = settings.hideFromScreenShare ? .none : .readOnly
        panel.contentView = contentView
        panel.setFrame(screenFrame, display: true)
        panel.orderFrontRegardless()
        return panel
    }

    // MARK: - Stop Button

    func createStopButton(on screen: NSScreen, onStop: @escaping () -> Void) -> NSPanel {
        let buttonSize: CGFloat = 36
        let margin: CGFloat = 8
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarBottom = visibleFrame.maxY

        let stopView = NSHostingView(rootView: StopButtonView(onStop: onStop))
        let panel = NSPanel(
            contentRect: NSRect(
                x: screenFrame.midX - buttonSize / 2,
                y: menuBarBottom - buttonSize - margin,
                width: buttonSize,
                height: buttonSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.sharingType = .none
        panel.contentView = stopView
        panel.orderFrontRegardless()
        return panel
    }

    // MARK: - Helpers

    func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    private func configurePanel(_ panel: NSPanel, opaque: Bool, shadow: Bool, ignoresMouse: Bool, settings: NotchSettings) {
        panel.isOpaque = opaque
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = ignoresMouse
        panel.sharingType = settings.hideFromScreenShare ? .none : .readOnly
    }
}
