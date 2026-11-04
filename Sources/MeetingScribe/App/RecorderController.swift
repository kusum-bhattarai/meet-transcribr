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

    var title = ""
    var captureMicrophone = false

    var isRecording: Bool { state == .recording }
    var canStart: Bool {
        switch state {
        case .idle, .saved, .failed: true
        default: false
        }
    }

    func start() {
        guard canStart else { return }
        Log.app.info("Start requested (mic: \(self.captureMicrophone))")
        startDate = Date()
        state = .recording
    }

    func stop() {
        guard isRecording else { return }
        Log.app.info("Stop requested")
        state = .finishing
        startDate = nil
        state = .idle
    }

    func discard() {
        guard isRecording else { return }
        Log.app.info("Recording discarded")
        startDate = nil
        state = .idle
    }

    func revealSaved() {
        if case .saved(let url) = state {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
