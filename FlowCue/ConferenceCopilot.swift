//
//  ConferenceCopilot.swift
//  FlowCue
//
//  Real-time AI conference copilot — state machine + transcript buffer.
//

import Foundation

@Observable
class ConferenceCopilot {
    static let shared = ConferenceCopilot()

    enum State: String {
        case idle, listening, generating, displaying
    }

    var state: State = .idle
    var rollingTranscript: String = ""
    var currentResponse: String = ""
    var streamedText: String = ""
    var isStreaming: Bool = false
    var error: String?

    struct TranscriptSegment {
        let timestamp: Date
        let text: String
    }
    var transcriptLines: [TranscriptSegment] = []

    private let aiClient = ConferenceAIClient()
    private let speechRecognizer = SpeechRecognizer()

    var recognizerAudioLevels: [CGFloat] { speechRecognizer.audioLevels }
    var isSpeaking: Bool { speechRecognizer.isSpeaking }
    var isListening: Bool { speechRecognizer.isListening }
    var activeLocale: String { speechRecognizer.activeLocale }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else { return }
        state = .listening
        error = nil
        rollingTranscript = ""
        transcriptLines.removeAll()
        currentResponse = ""
        streamedText = ""

        speechRecognizer.freeTranscriptionMode = true
        speechRecognizer.onTranscriptUpdate = { [weak self] text in
            self?.appendTranscript(text)
        }
        speechRecognizer.startFreeTranscription()
    }

    func stop() {
        aiClient.cancelCurrentRequest()
        speechRecognizer.stopFreeTranscription()
        state = .idle
        isStreaming = false
    }

    // MARK: - Transcript Buffer

    func appendTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        transcriptLines.append(TranscriptSegment(timestamp: Date(), text: trimmed))
        pruneOldSegments()
        rollingTranscript = transcriptLines.map(\.text).joined(separator: " ")
    }

    private func pruneOldSegments() {
        let duration = TimeInterval(NotchSettings.shared.conferenceTranscriptDuration)
        let cutoff = Date().addingTimeInterval(-duration)
        transcriptLines.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - AI Answer Generation

    func generateAnswer() {
        // If already displaying, dismiss and go back to listening
        if state == .displaying {
            clearResponse()
            return
        }

        guard state == .listening else { return }
        guard !rollingTranscript.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "No transcript yet. Speak first, then press \u{2318}\u{21E7}A."
            return
        }

        state = .generating
        error = nil
        currentResponse = ""
        streamedText = ""
        isStreaming = true

        let settings = NotchSettings.shared
        let provider = settings.conferenceAIProvider
        let contextHint = settings.conferenceContextHint
        let transcript = rollingTranscript

        // Determine API key and model
        let apiKey: String
        let model: String
        switch provider {
        case .claude:
            apiKey = settings.aiApiKey
            model = settings.conferenceClaudeModel
        case .openai:
            apiKey = settings.openaiApiKey
            model = settings.conferenceOpenAIModel
        }

        guard !apiKey.isEmpty else {
            let providerName = provider == .claude ? "Anthropic" : "OpenAI"
            error = "No \(providerName) API key. Add it in Settings \u{2192} AI."
            state = .listening
            isStreaming = false
            return
        }

        aiClient.streamAnswer(
            transcript: transcript,
            contextHint: contextHint,
            provider: provider,
            apiKey: apiKey,
            model: model,
            onChunk: { [weak self] chunk in
                DispatchQueue.main.async {
                    self?.streamedText += chunk
                    self?.currentResponse = self?.streamedText ?? ""
                }
            },
            onComplete: { [weak self] fullText in
                DispatchQueue.main.async {
                    self?.currentResponse = fullText
                    self?.isStreaming = false
                    self?.state = .displaying
                }
            },
            onError: { [weak self] err in
                DispatchQueue.main.async {
                    self?.error = err.localizedDescription
                    self?.isStreaming = false
                    self?.state = .listening
                }
            }
        )
    }

    func clearResponse() {
        currentResponse = ""
        streamedText = ""
        isStreaming = false
        state = .listening
    }
}
