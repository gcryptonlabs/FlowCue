//
//  PageManager.swift
//  FlowCue
//
//  Extracted from NotchOverlayController.swift — page navigation and content management.
//

import Foundation

class PageManager {

    func populateContent(_ overlayContent: OverlayContent, text: String, hasNextPage: Bool) {
        let normalized = splitTextIntoWords(text)
        overlayContent.words = normalized
        overlayContent.totalCharCount = normalized.joined(separator: " ").count
        overlayContent.hasNextPage = hasNextPage
    }

    func resetSpeechState(_ speechRecognizer: SpeechRecognizer) {
        speechRecognizer.recognizedCharCount = 0
        speechRecognizer.shouldDismiss = false
        speechRecognizer.shouldAdvancePage = false
        speechRecognizer.lastSpokenText = ""
    }
}
