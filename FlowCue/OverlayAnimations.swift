//
//  OverlayAnimations.swift
//  FlowCue
//
//  Extracted from NotchOverlayController.swift — all animation and dismiss logic.
//

import AppKit
import Combine

class OverlayAnimationController {
    private var cancellables = Set<AnyCancellable>()
    private var isDismissing = false

    var onPageJump: ((Int) -> Void)?
    var onNextPage: (() -> Void)?
    var onDismissComplete: (() -> Void)?

    func observeDismiss(speechRecognizer: SpeechRecognizer, overlayContent: OverlayContent, cleanup: @escaping () -> Void) {
        isDismissing = false
        cancellables.removeAll()

        // Poll for shouldAdvancePage (next page requested from overlay)
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if speechRecognizer.shouldAdvancePage {
                    speechRecognizer.shouldAdvancePage = false
                    self.onNextPage?()
                }
                // Poll for page jump from page picker
                if let targetIndex = overlayContent.jumpToPageIndex {
                    overlayContent.jumpToPageIndex = nil
                    self.onPageJump?(targetIndex)
                }
            }
            .store(in: &cancellables)

        // Poll for shouldDismiss becoming true (from view setting it on completion)
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, speechRecognizer.shouldDismiss, !self.isDismissing else { return }
                self.isDismissing = true
                // Wait for shrink animation, then cleanup
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.cancellables.removeAll()
                    cleanup()
                    self.onDismissComplete?()
                }
            }
            .store(in: &cancellables)
    }

    func triggerDismiss(speechRecognizer: SpeechRecognizer, cleanup: @escaping () -> Void) {
        speechRecognizer.shouldDismiss = true
        speechRecognizer.forceStop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            cleanup()
            self?.onDismissComplete?()
        }
    }

    func cancelObservers() {
        cancellables.removeAll()
        isDismissing = false
    }
}
