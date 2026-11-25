import PinCore
import Foundation
import AVFoundation
import Speech

@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var phase: VoiceCaptureSession.Phase = .idle
    var active: Bool { phase != .idle }
    var recording: Bool { phase == .recording }
    private var capture = VoiceCaptureSession()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishDeadline: Task<Void, Never>?
    private var onComplete: ((String) -> Void)?
    private var onFailure: ((VoiceError) -> Void)?
    private var installedTap = false
    private var activatedSession = false

    func start(onPartial: @escaping (String) -> Void,
               onComplete: @escaping (String) -> Void,
               onFailure: @escaping (VoiceError) -> Void) async throws {
        guard let id = capture.begin() else { return }
        phase = capture.phase
        self.onComplete = onComplete; self.onFailure = onFailure
        do {
            let permission = await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            try requireCurrent(id)
            guard permission == .authorized else { throw VoiceError.permission }
            let microphone = await AVAudioApplication.requestRecordPermission()
            try requireCurrent(id)
            guard microphone else { throw VoiceError.permission }
            guard let recognizer = SFSpeechRecognizer(locale: .current),
                  recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw VoiceError.unavailable }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            activatedSession = true
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            let node = engine.inputNode, format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw VoiceError.unavailable }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            installedTap = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.capture.owns(id) else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if self.capture.partial(text, from: id) { onPartial(text) }
                        if result.isFinal { self.complete(text, id: id); return }
                    }
                    if error != nil { self.fail(.interrupted, id: id) }
                }
            }
            engine.prepare(); try engine.start()
            guard capture.startRecording(id) else { throw CancellationError() }
            phase = capture.phase
        } catch {
            // An older permission callback must never tear down a newer recording.
            if capture.owns(id) { cancel() }
            throw error
        }
    }

    /// A deliberate Stop finishes recognition; it does not cancel the final audio.
    func stop() {
        guard let id = capture.requestFinish() else { cancel(); return }
        phase = capture.phase
        stopAudioInput()
        request?.endAudio()
        task?.finish()
        finishDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard !Task.isCancelled, let self, self.capture.owns(id) else { return }
            self.fail(.unfinished, id: id)
        }
    }

    /// Home, a typed submission or backgrounding discards the capture, never dispatching it.
    func cancel() {
        capture.cancel(); phase = capture.phase
        onComplete = nil; onFailure = nil
        tearDown()
    }

    private func requireCurrent(_ id: UUID) throws {
        guard capture.owns(id), !Task.isCancelled else { throw CancellationError() }
    }
    private func complete(_ text: String, id: UUID) {
        guard let result = capture.final(text, from: id) else { return }
        let completed = onComplete, failed = onFailure
        phase = capture.phase; onComplete = nil; onFailure = nil
        tearDown()
        switch result {
        case .question(let question): completed?(question)
        case .empty: failed?(.empty)
        }
    }
    private func fail(_ error: VoiceError, id: UUID) {
        guard capture.owns(id) else { return }
        let failed = onFailure
        cancel()
        failed?(error)
    }
    private func stopAudioInput() {
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
    }
    private func tearDown() {
        finishDeadline?.cancel(); finishDeadline = nil
        stopAudioInput()
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        if activatedSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedSession = false
        }
    }
    enum VoiceError: LocalizedError {
        case permission, unavailable, empty, unfinished, interrupted
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow microphone and speech access in Settings, or type your question."
            case .unavailable: return "On-device speech isn't available here yet. You can type your question."
            case .empty: return "I didn’t catch a question. Try speaking again, or type it."
            case .unfinished, .interrupted: return "Listening stopped before your question was finished. Review the draft and tap Search, or try again."
            }
        }
    }
}
