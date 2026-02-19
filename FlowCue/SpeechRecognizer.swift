//
//  SpeechRecognizer.swift
//  FlowCue
//
//  Created by FlowCue Team.
//

import AppKit
import Foundation
import NaturalLanguage
import Speech
import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

@Observable
class SpeechRecognizer {
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false
    var speechStartTime: Date? = nil
    var debugStatus: String = ""
    /// The locale actually used for the current recognition session (for UI display)
    var activeLocale: String = ""

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        let recent = audioLevels.suffix(10)
        guard !recent.isEmpty else { return false }
        let avg = recent.reduce(0, +) / CGFloat(recent.count)
        return avg > 0.08
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var suppressConfigChange: Bool = false
    /// Locales that failed with error 1107 in this session — skip on retry
    private var failedLocales: Set<String> = []

    // MARK: - Whisper backends
    private var whisperProcess: Process?
    private var whisperOutputBuffer: String = ""

    // MARK: - OpenAI Whisper cloud backend
    private let whisperClient = OpenAIWhisperClient()
    private var cloudAudioEngine: AVAudioEngine?
    private var cloudChunkBuffers: [AVAudioPCMBuffer] = []
    private var cloudChunkTimer: Timer?
    private var cloudRecordingFormat: AVAudioFormat?
    private var isCloudTranscribing = false
    private var cloudAccumulatedText = ""

    /// Jump highlight to a specific char offset (e.g. when user taps a word)
    func jumpTo(charOffset: Int) {
        recognizedCharCount = charOffset
        matchStartOffset = charOffset
        retryCount = 0
        if isListening {
            restartRecognition()
        }
    }

    /// Detect the dominant language of the given text and return a matching SFSpeechRecognizer locale identifier.
    static func detectLanguage(from text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        let supported = SFSpeechRecognizer.supportedLocales()
        let matching = supported.filter { $0.identifier.hasPrefix(lang.rawValue) }
        guard !matching.isEmpty else { return nil }
        // Prefer locale matching the user's region, then standard variants (US, RU, DE, etc.)
        let userRegion = Locale.current.region?.identifier ?? "US"
        let standardRegions = ["US", "RU", "GB", "DE", "FR", "ES", "IT", "JP", "KR", "CN", "BR", "IN"]
        let sorted = matching.sorted { a, b in
            let aRegion = Locale(identifier: a.identifier).region?.identifier ?? ""
            let bRegion = Locale(identifier: b.identifier).region?.identifier ?? ""
            if aRegion == userRegion && bRegion != userRegion { return true }
            if bRegion == userRegion && aRegion != userRegion { return false }
            let aStd = standardRegions.firstIndex(of: aRegion) ?? standardRegions.count
            let bStd = standardRegions.firstIndex(of: bRegion) ?? standardRegions.count
            return aStd < bStd
        }
        return sorted.first?.identifier
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        recognizedCharCount = 0
        matchStartOffset = 0
        retryCount = 0
        error = nil
        speechStartTime = Date()
        sessionGeneration += 1
        failedLocales.removeAll()

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow FlowCue."
            openMicrophoneSettings()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.requestSpeechAuthAndBegin()
                    } else {
                        self?.error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow FlowCue."
                    }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        switch NotchSettings.shared.speechEngine {
        case .whisperLocal:
            beginWhisperRecognition()
            return
        case .whisperCloud:
            beginCloudWhisperRecognition()
            return
        case .apple:
            requestSpeechAuthAndBegin()
        }
    }

    private func requestSpeechAuthAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.beginRecognition()
                default:
                    self?.error = "Speech recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition to allow FlowCue."
                    self?.openSpeechRecognitionSettings()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        isListening = false
        speechStartTime = nil
        stopWhisper()
        stopCloudWhisper()
        cleanupRecognition()
    }

    func forceStop() {
        isListening = false
        speechStartTime = nil
        sourceText = ""
        retryCount = maxRetries
        stopWhisper()
        stopCloudWhisper()
        cleanupRecognition()
    }

    func resume() {
        retryCount = 0
        matchStartOffset = recognizedCharCount
        shouldDismiss = false
        beginRecognition()
    }

    private func cleanupRecognition() {
        // Cancel any pending restart to prevent overlapping beginRecognition calls
        pendingRestart?.cancel()
        pendingRestart = nil

        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        // Ensure clean state
        cleanupRecognition()

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            let inputUnit = audioEngine.inputNode.audioUnit
            if let audioUnit = inputUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                // Re-initialize audio unit so it picks up the new device's format
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            // Allow config changes again after a settle period
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressConfigChange = false
            }
        }

        let locale: String
        if NotchSettings.shared.autoDetectLanguage, let detected = Self.detectLanguage(from: sourceText), !failedLocales.contains(detected) {
            locale = detected
            debugStatus = "Auto: \(detected)"
        } else {
            let manual = NotchSettings.shared.speechLocale
            if !failedLocales.contains(manual) {
                locale = manual
                debugStatus = "Manual: \(manual)"
            } else {
                // Last resort fallback
                locale = "en-US"
                debugStatus = "Fallback: en-US"
            }
        }
        activeLocale = locale
        NSLog("[FlowCue] Speech locale: \(locale)")
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available for \(locale). Try downloading the language in System Settings → General → Keyboard → Dictation → Languages."
            debugStatus = "ERR: unavailable \(locale)"
            NSLog("[FlowCue] Speech recognizer NOT available for \(locale)")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        if NotchSettings.shared.forceOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against invalid format during device transitions (e.g. mic switch)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            // Retry after a longer delay to let the audio system settle
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                error = "Audio input unavailable"
                isListening = false
            }
            return
        }

        // Observe audio configuration changes (e.g. mic switched externally) to restart gracefully
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.suppressConfigChange, !self.sourceText.isEmpty else { return }
            self.restartRecognition()
        }

        // Belt-and-suspenders: ensure no stale tap exists before installing
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            recognitionRequest.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                self?.audioLevels.append(level)
                if (self?.audioLevels.count ?? 0) > 30 {
                    self?.audioLevels.removeFirst()
                }
            }
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    // Ignore stale results from a previous session
                    guard self.sessionGeneration == currentGeneration else { return }
                    self.retryCount = 0 // Reset on success
                    self.lastSpokenText = spoken
                    self.debugStatus = "Heard: \(spoken.suffix(30))"
                    NSLog("[FlowCue] Recognized: \(spoken.suffix(50))")
                    self.matchCharacters(spoken: spoken)
                    NSLog("[FlowCue] charCount=\(self.recognizedCharCount)/\(self.sourceText.count)")
                }
            }
            if let err = error {
                DispatchQueue.main.async {
                    let nsErr = err as NSError
                    NSLog("[FlowCue] Recognition error: domain=\(nsErr.domain) code=\(nsErr.code) \(err.localizedDescription)")
                    self.debugStatus = "ERR: \(err.localizedDescription.prefix(40))"
                    // If recognitionRequest is nil, cleanup already ran (intentional cancel) — don't retry
                    guard self.recognitionRequest != nil else { return }

                    // Error 1107: locale-specific failure (language model missing or unsupported)
                    // Mark locale as failed and try fallback
                    if nsErr.code == 1107 {
                        self.failedLocales.insert(self.activeLocale)
                        NSLog("[FlowCue] Locale \(self.activeLocale) failed (1107), trying fallback. Failed: \(self.failedLocales)")
                        // Try next locale in chain: auto-detect → manual picker → en-US
                        let manual = NotchSettings.shared.speechLocale
                        let hasFallback = !self.failedLocales.contains(manual) || !self.failedLocales.contains("en-US")
                        if hasFallback {
                            self.scheduleBeginRecognition(after: 0.3)
                        } else {
                            self.error = "Speech recognition unavailable. Download language models in System Settings → General → Keyboard → Dictation → Languages."
                            self.isListening = false
                        }
                        return
                    }

                    if self.isListening && !self.shouldDismiss && !self.sourceText.isEmpty && self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        // Preserve progress: start matching from current position after restart
                        self.matchStartOffset = self.recognizedCharCount
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.isListening = false
                    }
                }
            }
        }

        // Suppress config-change observer for 2s after engine start to avoid restart loops
        // (the speech recognition subsystem triggers config changes during setup)
        suppressConfigChange = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.suppressConfigChange = false
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            debugStatus += " | Listening"
            NSLog("[FlowCue] Audio engine started, listening=true")
        } catch {
            // Transient failure after a device switch — retry with longer delay
            debugStatus = "ERR: engine \(error.localizedDescription)"
            NSLog("[FlowCue] Audio engine FAILED: \(error.localizedDescription)")
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                self.error = "Audio engine failed: \(error.localizedDescription)"
                isListening = false
            }
        }
    }

    private func restartRecognition() {
        // Reset retries so the fresh engine gets a full set of attempts
        retryCount = 0
        isListening = true
        // Longer delay to let the audio system fully settle after a device change
        cleanupRecognition()
        scheduleBeginRecognition(after: 0.5)
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken: String) {
        // Strategy 1: character-level fuzzy match from the start offset
        let charResult = charLevelMatch(spoken: spoken)

        // Strategy 2: word-level match (handles STT word substitutions)
        let wordResult = wordLevelMatch(spoken: spoken)

        let best = max(charResult, wordResult)

        // Only move forward from the match start offset
        let newCount = matchStartOffset + best
        if newCount > recognizedCharCount {
            recognizedCharCount = min(newCount, sourceText.count)
        }
    }

    private func charLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let src = Array(remainingSource.lowercased().unicodeScalars).map { Character($0) }
        let spk = Array(Self.normalize(spoken).unicodeScalars).map { Character($0) }

        var si = 0
        var ri = 0
        var lastGoodOrigIndex = 0

        while si < src.count && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            // Skip non-alphanumeric in source
            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            // Skip non-alphanumeric in spoken
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                // Try to re-sync: look ahead in both strings
                var found = false

                // Skip up to 3 chars in spoken (STT inserted extra chars)
                let maxSkipR = min(3, spk.count - ri - 1)
                if maxSkipR >= 1 {
                    for skipR in 1...maxSkipR {
                        let nextRI = ri + skipR
                        if nextRI < spk.count && spk[nextRI] == sc {
                            ri = nextRI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip up to 3 chars in source (STT missed some chars)
                let maxSkipS = min(3, src.count - si - 1)
                if maxSkipS >= 1 {
                    for skipS in 1...maxSkipS {
                        let nextSI = si + skipS
                        if nextSI < src.count && src[nextSI] == rc {
                            si = nextSI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip both (substitution)
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            }
        }

        return lastGoodOrigIndex
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    private func wordLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let sourceWords = remainingSource.split(separator: " ").map { String($0) }
        let spokenWords = spoken.lowercased().split(separator: " ").map { String($0) }

        var si = 0 // source word index
        var ri = 0 // spoken word index
        var matchedCharCount = 0

        while si < sourceWords.count && ri < spokenWords.count {
            // Auto-skip annotation words in source (brackets, emoji)
            if Self.isAnnotationWord(sourceWords[si]) {
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 { matchedCharCount += 1 }
                si += 1
                continue
            }

            let srcWord = sourceWords[si].lowercased()
                .filter { $0.isLetter || $0.isNumber }
            let spkWord = spokenWords[ri]
                .filter { $0.isLetter || $0.isNumber }

            if srcWord == spkWord || isFuzzyMatch(srcWord, spkWord) {
                // Count original chars including trailing punctuation, plus space
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 {
                    matchedCharCount += 1 // space
                }
                si += 1
                ri += 1
            } else {
                // Try skipping up to 3 spoken words (STT hallucinated words)
                var foundSpk = false
                let maxSpkSkip = min(3, spokenWords.count - ri - 1)
                for skip in 1...max(1, maxSpkSkip) where skip <= maxSpkSkip {
                    let nextSpk = spokenWords[ri + skip].filter { $0.isLetter || $0.isNumber }
                    if srcWord == nextSpk || isFuzzyMatch(srcWord, nextSpk) {
                        ri += skip
                        foundSpk = true
                        break
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 3 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(3, sourceWords.count - si - 1)
                for skip in 1...max(1, maxSrcSkip) where skip <= maxSrcSkip {
                    let nextSrc = sourceWords[si + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if nextSrc == spkWord || isFuzzyMatch(nextSrc, spkWord) {
                        // Add all skipped source words' char counts
                        for s in 0..<skip {
                            matchedCharCount += sourceWords[si + s].count + 1
                        }
                        si += skip
                        foundSrc = true
                        break
                    }
                }
                if foundSrc { continue }

                // Try treating current source word as punctuation-only and skip it
                if srcWord.isEmpty {
                    matchedCharCount += sourceWords[si].count
                    if si < sourceWords.count - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                // No match, advance spoken
                ri += 1
            }
        }

        // Auto-skip trailing annotation words at end of source
        while si < sourceWords.count && Self.isAnnotationWord(sourceWords[si]) {
            matchedCharCount += sourceWords[si].count
            if si < sourceWords.count - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    private func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        // Exact match
        if a == b { return true }
        // One starts with the other (phonetic prefix: "not" ~ "notch")
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        // One contains the other
        if a.contains(b) || b.contains(a) { return true }
        // Shared prefix >= 60% of shorter word
        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        let shorter = min(a.count, b.count)
        if shorter >= 2 && shared >= max(2, shorter * 3 / 5) { return true }
        // Edit distance tolerance
        let dist = editDistance(a, b)
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, dp[j], dp[j-1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    // MARK: - Whisper backend

    private func beginWhisperRecognition() {
        stopWhisper()
        cleanupRecognition()

        let modelPath = NotchSettings.shared.whisperModelPath
        guard FileManager.default.fileExists(atPath: modelPath) else {
            error = "Whisper model not found at: \(modelPath)"
            debugStatus = "ERR: model not found"
            NSLog("[FlowCue] Whisper model not found: \(modelPath)")
            return
        }

        let whisperBin = "/opt/homebrew/bin/whisper-stream"
        guard FileManager.default.fileExists(atPath: whisperBin) else {
            error = "whisper-stream not found. Install: brew install whisper-cpp"
            debugStatus = "ERR: whisper-stream missing"
            return
        }

        // Start audio engine just for waveform visualization
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            error = "Audio input unavailable"
            return
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))
            DispatchQueue.main.async {
                self?.audioLevels.append(level)
                if (self?.audioLevels.count ?? 0) > 30 { self?.audioLevels.removeFirst() }
            }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            NSLog("[FlowCue] Waveform engine failed: \(error)")
        }

        // Launch whisper-stream
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBin)
        process.arguments = [
            "-m", modelPath,
            "-l", "auto",
            "--step", "3000",
            "--length", "5000",
            "--keep", "500",
            "-t", "4",
            "--vad-thold", "0.5",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr (model loading info)
        process.standardError = FileHandle.nullDevice

        whisperOutputBuffer = ""
        let currentGen = sessionGeneration

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == currentGen else { return }
                self.processWhisperOutput(chunk)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == currentGen else { return }
                NSLog("[FlowCue] whisper-stream exited with code \(proc.terminationStatus)")
                if self.isListening && !self.shouldDismiss {
                    self.debugStatus = "Whisper stopped, restarting..."
                    self.scheduleBeginRecognition(after: 1.0)
                }
            }
        }

        do {
            try process.run()
            whisperProcess = process
            isListening = true
            activeLocale = "auto (Whisper)"
            debugStatus = "Whisper listening..."
            NSLog("[FlowCue] whisper-stream started, PID=\(process.processIdentifier)")
        } catch {
            self.error = "Failed to start whisper-stream: \(error.localizedDescription)"
            debugStatus = "ERR: \(error.localizedDescription)"
            NSLog("[FlowCue] whisper-stream failed: \(error)")
        }
    }

    private func processWhisperOutput(_ chunk: String) {
        whisperOutputBuffer += chunk

        // Strip ANSI escape codes: ESC[...letter
        let stripped = whisperOutputBuffer.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[A-Za-z]|\\[2K",
            with: "",
            options: .regularExpression
        )

        // Extract meaningful text (skip blank audio markers and whitespace-only)
        let lines = stripped.components(separatedBy: .newlines)
        var recognizedText = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.contains("[BLANK_AUDIO]") { continue }
            if trimmed.hasPrefix("whisper_") { continue }
            if trimmed.hasPrefix("init:") { continue }
            if trimmed.hasPrefix("[Start") { continue }
            if trimmed.hasPrefix("main:") { continue }
            recognizedText += " " + trimmed
        }

        let cleaned = recognizedText.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }

        lastSpokenText = String(cleaned.suffix(60))
        debugStatus = "Whisper: \(cleaned.suffix(30))"
        NSLog("[FlowCue] Whisper heard: \(cleaned.suffix(80))")
        matchCharacters(spoken: cleaned)
        NSLog("[FlowCue] charCount=\(recognizedCharCount)/\(sourceText.count)")
    }

    private func stopWhisper() {
        if let process = whisperProcess, process.isRunning {
            process.terminate()
            NSLog("[FlowCue] whisper-stream terminated")
        }
        whisperProcess = nil
        whisperOutputBuffer = ""
    }

    // MARK: - OpenAI Whisper Cloud backend

    private func beginCloudWhisperRecognition() {
        stopCloudWhisper()

        let apiKey = NotchSettings.shared.openaiApiKey
        guard !apiKey.isEmpty else {
            error = "No OpenAI API key. Add it in Settings → Voice."
            debugStatus = "ERR: no API key"
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Apply mic selection
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            if let audioUnit = inputNode.audioUnit {
                var devID = deviceID
                AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &devID,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            self.error = "Audio input unavailable"
            return
        }
        cloudRecordingFormat = recordingFormat

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // Waveform visualization
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
                let rms = sqrt(sum / Float(max(frameLength, 1)))
                let level = CGFloat(min(rms * 5, 1.0))
                DispatchQueue.main.async {
                    self.audioLevels.append(level)
                    if self.audioLevels.count > 30 { self.audioLevels.removeFirst() }
                }
            }
            // Accumulate audio for transcription
            DispatchQueue.main.async {
                self.cloudChunkBuffers.append(buffer)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            cloudAudioEngine = engine
            isListening = true
            activeLocale = "auto (OpenAI)"
            debugStatus = "Cloud Whisper listening..."
            NSLog("[FlowCue] OpenAI Whisper engine started")

            cloudChunkTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
                self?.sendCloudChunk()
            }
        } catch {
            self.error = "Audio engine failed: \(error.localizedDescription)"
            debugStatus = "ERR: engine \(error.localizedDescription)"
        }
    }

    private func sendCloudChunk() {
        guard !cloudChunkBuffers.isEmpty, !isCloudTranscribing else { return }
        guard let format = cloudRecordingFormat else { return }

        let buffers = cloudChunkBuffers
        cloudChunkBuffers = []

        // Merge buffers
        let totalFrames = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard totalFrames > 0, let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return }

        var offset: AVAudioFrameCount = 0
        for buf in buffers {
            let count = buf.frameLength
            guard let src = buf.floatChannelData, let dst = merged.floatChannelData else { continue }
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch].advanced(by: Int(offset)), src[ch], Int(count) * MemoryLayout<Float>.size)
            }
            offset += count
        }
        merged.frameLength = totalFrames

        isCloudTranscribing = true
        let currentGen = sessionGeneration

        Task {
            do {
                let wavURL = try OpenAIWhisperClient.convertToWAV(buffer: merged, fromFormat: format)
                defer { try? FileManager.default.removeItem(at: wavURL) }

                let apiKey = NotchSettings.shared.openaiApiKey
                let text = try await whisperClient.transcribe(wavFileURL: wavURL, apiKey: apiKey)

                await MainActor.run {
                    guard self.sessionGeneration == currentGen else { return }
                    self.isCloudTranscribing = false
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }

                    self.cloudAccumulatedText += " " + trimmed
                    let cleaned = self.cloudAccumulatedText.trimmingCharacters(in: .whitespaces)
                    self.lastSpokenText = String(cleaned.suffix(60))
                    self.debugStatus = "Cloud: \(cleaned.suffix(30))"
                    NSLog("[FlowCue] Cloud Whisper: \(cleaned.suffix(80))")
                    self.matchCharacters(spoken: cleaned)
                    NSLog("[FlowCue] charCount=\(self.recognizedCharCount)/\(self.sourceText.count)")
                }
            } catch {
                await MainActor.run {
                    self.isCloudTranscribing = false
                    self.debugStatus = "Cloud ERR: \(error.localizedDescription.prefix(40))"
                    NSLog("[FlowCue] Cloud Whisper error: \(error)")
                }
            }
        }
    }

    private func stopCloudWhisper() {
        cloudChunkTimer?.invalidate()
        cloudChunkTimer = nil
        if let engine = cloudAudioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        cloudAudioEngine = nil
        cloudChunkBuffers = []
        cloudRecordingFormat = nil
        isCloudTranscribing = false
        cloudAccumulatedText = ""
    }
}
