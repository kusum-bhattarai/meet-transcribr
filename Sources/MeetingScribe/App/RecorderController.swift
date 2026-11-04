import AppKit
import Foundation
import Observation

enum RecorderState: Equatable {
    case idle
    case preparing
    case recording
    case finishing
    case summarizing
    case saved(URL)
    case failed(String)
}

/// Orchestrates capture, transcription and saving. Owns all per-meeting resources,
/// which are created on start and released on stop.
@MainActor
@Observable
final class RecorderController {
    private(set) var state: RecorderState = .idle
    private(set) var startDate: Date?
    let store = TranscriptStore()

    var title = ""
    var captureMicrophone = false

    private var systemTap: SystemAudioTap?
    private var themTranscriber: LiveTranscriber?

    var isRecording: Bool { state == .recording }
    var canStart: Bool {
        switch state {
        case .idle, .saved, .failed: true
        default: false
        }
    }

    func start() {
        guard canStart else { return }
        Task { await startRecording() }
    }

    func stop() {
        guard isRecording else { return }
        Task { await stopRecording() }
    }

    func discard() {
        guard isRecording else { return }
        Task { await discardRecording() }
    }

    func revealSaved() {
        if case .saved(let url) = state {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Lifecycle

    private func startRecording() async {
        Log.app.info("Start requested (mic: \(self.captureMicrophone))")
        state = .preparing
        store.reset()
        do {
            let locale = try await LiveTranscriber.prepare()

            let them = LiveTranscriber(speaker: .others, locale: locale)
            try await them.start { [store] text, isFinal in
                store.apply(text, from: .others, isFinal: isFinal)
            }
            themTranscriber = them

            let tap = SystemAudioTap()
            try tap.start { buffer in them.append(buffer) }
            systemTap = tap

            startDate = Date()
            state = .recording
        } catch {
            await fail(error)
        }
    }

    private func stopRecording() async {
        Log.app.info("Stop requested")
        state = .finishing
        // Stop capture first so nothing is appended after the stream finishes.
        systemTap?.stop()
        systemTap = nil
        await themTranscriber?.finish()
        themTranscriber = nil
        startDate = nil
        Log.app.info("Transcript finished: \(self.store.segments.count) segments, \(self.store.wordCount) words")
        state = .idle
    }

    private func discardRecording() async {
        Log.app.info("Recording discarded")
        await releaseResources()
        store.reset()
        state = .idle
    }

    private func releaseResources() async {
        systemTap?.stop()
        systemTap = nil
        await themTranscriber?.cancel()
        themTranscriber = nil
        startDate = nil
    }

    private func fail(_ error: Error) async {
        Log.app.error("Failed: \(error.localizedDescription, privacy: .public)")
        await releaseResources()
        state = .failed(error.localizedDescription)
    }
}
