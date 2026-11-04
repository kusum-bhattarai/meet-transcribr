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
        if case .saved(let folder) = state {
            NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: "transcript.md")])
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
        Log.app.info("Transcript finished: \(self.store.segments.count) segments, \(self.store.wordCount) words")

        let start = startDate ?? Date()
        startDate = nil
        do {
            let folder = try saveTranscript(start: start, end: Date())
            state = .saved(folder)
            revealSaved()
        } catch {
            Log.app.error("Saving transcript failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Couldn't save the transcript: \(error.localizedDescription)")
        }
    }

    // MARK: - Saving

    /// Writes `~/Documents/MeetingScribe/<yyyy-MM-dd HHmm> <title>/transcript.md`.
    private func saveTranscript(start: Date, end: Date) throws -> URL {
        let entered = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = entered.isEmpty ? "Meeting \(TranscriptStore.format(start, "yyyy-MM-dd HH:mm"))" : entered
        let folderTitle = sanitized(entered.isEmpty ? "Meeting" : entered)

        let root = URL.documentsDirectory.appending(path: "MeetingScribe", directoryHint: .isDirectory)
        let base = "\(TranscriptStore.format(start, "yyyy-MM-dd HHmm")) \(folderTitle)"
        var folder = root.appending(path: base, directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appending(path: "\(base) \(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transcript = folder.appending(path: "transcript.md")
        try store.markdown(title: displayTitle, start: start, end: end)
            .write(to: transcript, atomically: true, encoding: .utf8)
        Log.app.info("Saved transcript to \(transcript.path, privacy: .public)")
        return folder
    }

    private func sanitized(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Meeting" : cleaned
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
