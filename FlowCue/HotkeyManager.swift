//
//  HotkeyManager.swift
//  FlowCue
//
//  Global hotkeys: ⌘⇧Space (toggle), ⌘⇧R (reset), ⌘⇧← (jump back).
//

import AppKit

class HotkeyManager {
    static let shared = HotkeyManager()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        guard globalMonitor == nil else { return }

        // Global monitor — when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }

        // Local monitor — when app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKey(event) == true {
                return nil // consumed
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        guard flags.contains(cmdShift) else { return false }

        switch event.keyCode {
        case 49: // Space — toggle play/pause
            togglePlayPause()
            return true
        case 15: // R — reset to beginning
            resetToBeginning()
            return true
        case 123: // Left arrow — jump back
            jumpBack()
            return true
        default:
            return false
        }
    }

    private func togglePlayPause() {
        DispatchQueue.main.async {
            let service = FlowCueService.shared
            if service.overlayController.isShowing {
                service.overlayController.dismiss()
            } else {
                service.readCurrentPage()
            }
        }
    }

    private func resetToBeginning() {
        DispatchQueue.main.async {
            let service = FlowCueService.shared
            guard service.overlayController.isShowing else { return }
            service.currentPageIndex = 0
            service.readPages.removeAll()
            service.readCurrentPage()
        }
    }

    private func jumpBack() {
        DispatchQueue.main.async {
            let recognizer = FlowCueService.shared.overlayController.speechRecognizer
            guard FlowCueService.shared.overlayController.isShowing else { return }
            let current = recognizer.recognizedCharCount
            let jumpAmount = 90 // ~15 words
            recognizer.jumpTo(charOffset: max(0, current - jumpAmount))
        }
    }
}
