import AVFoundation
import Foundation
import Speech
import UIKit

/// Text-to-speech via AVSpeechSynthesizer (PRD F2). Speaks only when the
/// user chose spoken responses AND VoiceOver is off — when VoiceOver is on,
/// it reads the transcript itself and we must not double-speak.
///
/// v1.1 §3.5: streaming-aware. TTS starts on the first completed sentence of
/// a streamed reply rather than waiting for the whole message — no dead air
/// for voice-first users. §1 bug 4: speech is scoped to the visible chat;
/// ChatView calls `stop()` on disappear.
@MainActor
final class SpeechService {
    static let shared = SpeechService()
    private let synthesizer = AVSpeechSynthesizer()

    // Streaming state for the in-flight assistant message.
    private var streamingEnabled = false
    private var spokenPrefixLength = 0

    /// Call at the start of an agent turn.
    func beginStreamingTurn(spokenResponsesEnabled: Bool) {
        streamingEnabled = spokenResponsesEnabled && !UIAccessibility.isVoiceOverRunning
        spokenPrefixLength = 0
    }

    /// Feed the accumulated text of the in-flight message; any newly
    /// completed sentences are spoken immediately (utterances queue).
    func ingestStreaming(fullText: String) {
        guard streamingEnabled else { return }
        speakNewSentences(in: fullText, flush: false)
    }

    /// The in-flight message finished — speak whatever remains, then reset
    /// for the next message in the same turn.
    func finishStreamingMessage(finalText: String) {
        guard streamingEnabled else { return }
        // Note: the final text may be a shaped (trimmed) version of the
        // streamed text; anything already spoken stays spoken — we only ever
        // speak forward from the unspoken remainder.
        speakNewSentences(in: finalText, flush: true)
        spokenPrefixLength = 0
    }

    /// Speaks complete sentences beyond what's been spoken already.
    private func speakNewSentences(in text: String, flush: Bool) {
        guard spokenPrefixLength <= text.count else {
            if flush { spokenPrefixLength = 0 }
            return
        }
        let unspoken = String(text.dropFirst(spokenPrefixLength))
        let chunk: String
        if flush {
            chunk = unspoken
        } else {
            guard let boundary = lastSentenceBoundary(in: unspoken) else { return }
            chunk = String(unspoken[..<boundary])
        }
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        spokenPrefixLength += chunk.count
        speak(trimmed)
    }

    /// Index just past the last sentence terminator (. ! ? … or newline).
    private func lastSentenceBoundary(in text: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?", "…", "\n"]
        var boundary: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if terminators.contains(text[index]) {
                boundary = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return boundary
    }

    /// One-shot speech for non-streamed text (kept for notices/tests).
    func speakIfAppropriate(_ text: String, spokenResponsesEnabled: Bool) {
        guard spokenResponsesEnabled, !UIAccessibility.isVoiceOverRunning, !text.isEmpty else { return }
        speak(text)
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// Stops and flushes everything queued (used on chat disappear — §1 bug 4).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        streamingEnabled = false
        spokenPrefixLength = 0
    }
}

/// Dictation for the mic button using SFSpeechRecognizer (first-party).
/// Streams partial transcriptions into `transcript`.
@MainActor
@Observable
final class DictationService {
    var transcript: String = ""
    var isRecording: Bool = false
    var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        errorMessage = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Speech recognition permission is off. You can type instead, or enable it in Settings."
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Dictation isn't available right now. You can type instead."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't start the microphone. You can type instead."
            stop()
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
