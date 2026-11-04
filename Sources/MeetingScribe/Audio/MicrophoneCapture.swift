import AVFoundation

enum MicrophoneError: LocalizedError {
    case accessDenied
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Microphone access is off. Enable MeetingScribe in System Settings → Privacy & Security → Microphone."
        case .noInputDevice:
            "No usable microphone was found. Check System Settings → Sound → Input."
        }
    }
}

/// The user's side of the call, via an AVAudioEngine input tap.
final class MicrophoneCapture {
    private var engine: AVAudioEngine?

    static func requestAccess() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            Log.audio.error("Microphone access denied")
            throw MicrophoneError.accessDenied
        }
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            Log.audio.error("Microphone input format has sample rate 0: no input device")
            throw MicrophoneError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // The engine may reuse this buffer after the block returns.
            guard let copy = buffer.deepCopy() else { return }
            onBuffer(copy)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.audio.error("AVAudioEngine start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        self.engine = engine
        Log.audio.info("Microphone started, format: \(format.description, privacy: .public)")
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        Log.audio.info("Microphone stopped")
    }
}
