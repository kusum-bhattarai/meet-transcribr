import SwiftUI

@main
struct MeetingScribeApp: App {
    @State private var recorder = RecorderController()

    var body: some Scene {
        MenuBarExtra {
            PanelView(recorder: recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @Bindable var recorder: RecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusRow(recorder: recorder)
            if recorder.canStart {
                IdleControls(recorder: recorder)
            }
            TranscriptView()
                .frame(width: 380, height: 260)
            ActionRow(recorder: recorder)
        }
        .padding(14)
        .frame(width: 408)
    }
}

private struct StatusRow: View {
    let recorder: RecorderController

    var body: some View {
        HStack {
            switch recorder.state {
            case .idle: Text("Ready")
            case .preparing: Text("Preparing model…")
            case .recording:
                if let start = recorder.startDate {
                    ElapsedLabel(start: start)
                }
            case .finishing: Text("Finishing transcript…")
            case .summarizing: Text("Writing notes…")
            case .saved: Text("Saved")
            case .failed(let reason):
                Text(reason).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer()
        }
        .font(.headline)
    }
}

/// Ticks only while visible: `.task` is cancelled when the panel closes,
/// so there are no periodic wakeups while the popover is hidden.
private struct ElapsedLabel: View {
    let start: Date
    @State private var now = Date()

    var body: some View {
        Text(Duration.seconds(max(0, now.timeIntervalSince(start))).formatted(.time(pattern: .hourMinuteSecond)))
            .monospacedDigit()
            .task {
                Log.ui.debug("Elapsed timer started")
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
                Log.ui.debug("Elapsed timer stopped")
            }
    }
}

private struct IdleControls: View {
    @Bindable var recorder: RecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Meeting title", text: $recorder.title)
                .textFieldStyle(.roundedBorder)
            Toggle("Capture my microphone too", isOn: $recorder.captureMicrophone)
            if recorder.captureMicrophone {
                Text("Use headphones — without them your mic hears the call and transcribes it twice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TranscriptView: View {
    var body: some View {
        ScrollView {
            Text("Transcript will appear here.")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ActionRow: View {
    let recorder: RecorderController

    var body: some View {
        HStack {
            switch recorder.state {
            case .recording:
                Button("Stop & summarize") { recorder.stop() }
                    .keyboardShortcut(.defaultAction)
                Button("Discard", role: .destructive) { recorder.discard() }
            case .saved:
                Button("Show in Finder") { recorder.revealSaved() }
                Button("Start recording") { recorder.start() }
            case .preparing:
                Button("Start recording") {}.disabled(true)
            case .finishing, .summarizing:
                EmptyView()
            case .idle, .failed:
                Button("Start recording") { recorder.start() }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
