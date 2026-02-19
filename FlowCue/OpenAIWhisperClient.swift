//
//  OpenAIWhisperClient.swift
//  FlowCue
//
//  OpenAI Whisper API client for cloud-based speech transcription.
//

import Foundation
import AVFoundation

class OpenAIWhisperClient {
    enum WhisperError: LocalizedError {
        case noApiKey
        case networkError(String)
        case apiError(String)
        case audioConversionFailed
        case wavWriteFailed

        var errorDescription: String? {
            switch self {
            case .noApiKey: return "No OpenAI API key configured."
            case .networkError(let msg): return "Network error: \(msg)"
            case .apiError(let msg): return "Whisper API: \(msg)"
            case .audioConversionFailed: return "Failed to convert audio format."
            case .wavWriteFailed: return "Failed to write WAV file."
            }
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Transcribe a WAV file using OpenAI Whisper API.
    func transcribe(wavFileURL: URL, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw WhisperError.noApiKey }

        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: wavFileURL)
        var body = Data()

        // model
        body.appendMultipart(boundary: boundary, name: "model", value: "whisper-1")
        // response_format
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")
        // file
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        // close
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw WhisperError.apiError(message)
            }
            throw WhisperError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw WhisperError.apiError("Could not parse response")
        }

        return text
    }

    /// Convert an AVAudioPCMBuffer to 16kHz mono WAV and write to a temp file.
    static func convertToWAV(buffer: AVAudioPCMBuffer, fromFormat: AVAudioFormat) throws -> URL {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: fromFormat, to: targetFormat) else {
            throw WhisperError.audioConversionFailed
        }

        let ratio = 16000.0 / fromFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount + 1024
        ) else {
            throw WhisperError.audioConversionFailed
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return buffer
        }
        if let error { throw error }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let audioFile = try AVAudioFile(
            forWriting: tempURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try audioFile.write(from: outputBuffer)

        return tempURL
    }
}

// MARK: - Data helpers for multipart

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
