//
//  ConferenceAIClient.swift
//  FlowCue
//
//  SSE streaming client for Claude and OpenAI — Conference Copilot.
//

import Foundation

class ConferenceAIClient: NSObject, URLSessionDataDelegate {

    private var currentTask: URLSessionDataTask?
    private var session: URLSession?
    private var buffer = ""

    private var onChunk: ((String) -> Void)?
    private var onComplete: ((String) -> Void)?
    private var onError: ((Error) -> Void)?
    private var accumulated = ""

    private static let systemPrompt = """
    You are helping someone answer questions during a live video call.
    They read your response from a teleprompter as their own words.

    Rules:
    - Write EXACTLY how a person talks. Use contractions (I'm, we've, that's).
    - Use filler phrases sparingly: "honestly", "the thing is", "so basically"
    - 2-4 sentences for simple questions, up to 6 for complex ones
    - Never use bullet points, lists, markdown, or formatting
    - Never reference yourself as AI. This is THEIR answer.
    - Match the tone: casual question → casual answer
    - Start with the answer immediately. No "Great question!" preamble
    - Use natural connectors: "So basically...", "What we found is...", "I think..."
    - End naturally. No summary wrap-up.
    """

    func streamAnswer(
        transcript: String,
        contextHint: String,
        provider: AIProvider,
        apiKey: String,
        model: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        cancelCurrentRequest()

        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onError = onError
        self.accumulated = ""
        self.buffer = ""

        let systemWithContext: String
        if contextHint.trimmingCharacters(in: .whitespaces).isEmpty {
            systemWithContext = Self.systemPrompt
        } else {
            systemWithContext = Self.systemPrompt + "\n\nContext about the speaker: \(contextHint)"
        }

        let userMessage = "Here is the recent conversation transcript. Answer the last question or respond to the last statement naturally:\n\n\(transcript)"

        let request: URLRequest
        do {
            switch provider {
            case .claude:
                request = try buildClaudeRequest(apiKey: apiKey, model: model, system: systemWithContext, userMessage: userMessage)
            case .openai:
                request = try buildOpenAIRequest(apiKey: apiKey, model: model, system: systemWithContext, userMessage: userMessage)
            }
        } catch {
            onError(error)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        currentTask = session?.dataTask(with: request)
        currentTask?.resume()
    }

    func cancelCurrentRequest() {
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        onChunk = nil
        onComplete = nil
        onError = nil
    }

    // MARK: - Request Builders

    private func buildClaudeRequest(apiKey: String, model: String, system: String, userMessage: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": system,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData
        return request
    }

    private func buildOpenAIRequest(apiKey: String, model: String, system: String, userMessage: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userMessage]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.httpBody = jsonData
        return request
    }

    // MARK: - URLSessionDataDelegate (SSE Parsing)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        buffer += chunk

        // Process complete SSE lines
        while let lineEnd = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<lineEnd])
            buffer = String(buffer[buffer.index(after: lineEnd)...])

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))

            if payload == "[DONE]" {
                onComplete?(accumulated)
                cleanup()
                return
            }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            // Detect provider from response shape
            if let contentType = json["type"] as? String {
                // Claude SSE
                handleClaudeEvent(type: contentType, json: json)
            } else if let choices = json["choices"] as? [[String: Any]] {
                // OpenAI SSE
                handleOpenAIEvent(choices: choices)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            // Check if we got an HTTP error
            if let httpResponse = task.response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                onError?(ConferenceAIError.apiError("HTTP \(httpResponse.statusCode): \(error.localizedDescription)"))
            } else {
                onError?(error)
            }
            cleanup()
        } else if error == nil && !accumulated.isEmpty {
            // Stream ended without [DONE] — still deliver what we have
            onComplete?(accumulated)
            cleanup()
        }
    }

    // MARK: - Event Handlers

    private func handleClaudeEvent(type: String, json: [String: Any]) {
        switch type {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                accumulated += text
                onChunk?(text)
            }
        case "message_stop":
            onComplete?(accumulated)
            cleanup()
        case "error":
            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                onError?(ConferenceAIError.apiError(message))
                cleanup()
            }
        default:
            break
        }
    }

    private func handleOpenAIEvent(choices: [[String: Any]]) {
        guard let choice = choices.first,
              let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return }
        accumulated += content
        onChunk?(content)
    }

    private func cleanup() {
        currentTask = nil
        onChunk = nil
        onComplete = nil
        onError = nil
    }

    enum ConferenceAIError: LocalizedError {
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .apiError(let msg): return "AI error: \(msg)"
            }
        }
    }
}
