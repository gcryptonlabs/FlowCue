//
//  AIScriptExpander.swift
//  FlowCue
//
//  Created by FlowCue Team.
//

import Foundation

@Observable
class AIScriptExpander {
    static let shared = AIScriptExpander()

    var isExpanding = false
    var lastError: String?

    func expand(bulletPoints: String, language: String = "same as input") async throws -> String {
        let apiKey = NotchSettings.shared.aiApiKey
        guard !apiKey.isEmpty else {
            throw AIError.noApiKey
        }

        let systemPrompt = """
        You are a professional speechwriter and teleprompter script expert. \
        Your job is to take bullet points, notes, or an outline and expand them into a natural, \
        ready-to-read teleprompter script.

        Rules:
        - Write in the language of the input (unless told otherwise)
        - Use a conversational, natural speaking tone
        - Add smooth transitions between points
        - Keep sentences short and easy to read aloud
        - Add [pause] markers where natural pauses would occur
        - Do NOT add any preamble, commentary, or meta-text
        - Return ONLY the final script text, ready to read
        """

        let userMessage = """
        Expand these notes into a teleprompter script (\(language)):

        \(bulletPoints)
        """

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "system": systemPrompt,
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
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if let errorBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorBody["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIError.apiError(message)
            }
            throw AIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIError.parseError
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum AIError: LocalizedError {
        case noApiKey
        case networkError(String)
        case apiError(String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .noApiKey:
                return "No API key. Add your Anthropic API key in Settings → AI."
            case .networkError(let msg):
                return "Network error: \(msg)"
            case .apiError(let msg):
                return "API error: \(msg)"
            case .parseError:
                return "Failed to parse AI response."
            }
        }
    }
}
