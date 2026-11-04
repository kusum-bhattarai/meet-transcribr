import SwiftUI

@main
struct MeetingScribeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(recorder: delegate.recorder)
        } label: {
            Image(systemName: delegate.recorder.isRecording ? "record.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Guarantees a recording is never stranded: the menu-bar item can be hidden behind the notch,
/// so relaunching opens the panel in a window, and quitting (or SIGTERM) saves first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = RecorderController()
    private var window: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.app.notice("Signal \(sig) received; quitting via normal termination")
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// `open build/MeetingScribe.app` on a running instance lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isRecording else { return .terminateNow }
        Log.app.notice("Quit while recording; saving transcript first")
        Task {
            await recorder.finishRecording(reveal: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PanelView(recorder: recorder)))
            window.title = "MeetingScribe"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

struct PanelView: View {
    @Bindable var recorder: RecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusRow(recorder: recorder)
            if let warning = recorder.warning, recorder.isRecording {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if recorder.canStart {
                IdleControls(recorder: recorder)
            }
            TranscriptView(store: recorder.store)
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
                Text("· \(recorder.store.wordCount) words")
                    .foregroundStyle(.secondary)
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
    let store: TranscriptStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.segments.isEmpty && store.volatile.isEmpty {
                        Text("Transcript will appear here.")
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(store.segments) { segment in
                        line(segment.speaker, segment.text)
                    }
                    ForEach([Speaker.others, .me], id: \.self) { speaker in
                        if let text = store.volatile[speaker], !text.isEmpty {
                            line(speaker, text).foregroundStyle(.tertiary)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .onChange(of: store.segments.count) { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onChange(of: store.volatile) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private let bottomID = "bottom"

    private func line(_ speaker: Speaker, _ text: String) -> Text {
        Text("\(Text("\(speaker.label):").bold()) \(text)")
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
