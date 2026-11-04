import AVFoundation
import Speech

enum TranscriptionError: LocalizedError {
    case deviceNotSupported
    case unsupportedLocale(String)
    case speechRecognitionDenied
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .deviceNotSupported:
            "On-device transcription isn't supported on this Mac."
        case .unsupportedLocale(let id):
            "No on-device speech model exists for your language (\(id))."
        case .speechRecognitionDenied:
            "Speech recognition is off. Enable MeetingScribe in System Settings → Privacy & Security → Speech Recognition."
        case .noCompatibleAudioFormat:
            "The speech model reported no compatible audio format."
        }
    }
}

/// One SpeechAnalyzer session for one capture stream.
/// `append` is called from the capture queue; everything else from the main actor.
final class LiveTranscriber {
    let speaker: Speaker
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?

    // Touched only on the capture queue.
    private var converter: AVAudioConverter?

    init(speaker: Speaker, locale: Locale) {
        self.speaker = speaker
        self.locale = locale
    }

    /// Same options for the asset probe and the live session, so the installed assets match.
    static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    // MARK: - Preparation (once per recording)

    /// Checks authorization, device support and locale, then makes sure the model is installed.
    static func prepare() async throws -> Locale {
        try await requestAuthorization()

        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.deviceNotSupported }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw TranscriptionError.unsupportedLocale(Locale.current.identifier)
        }

        let reserved = await AssetInventory.reservedLocales
        let isReserved = reserved.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if !isReserved, reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            Log.speech.notice("Releasing reserved locale \(oldest.identifier, privacy: .public) to make room")
            await AssetInventory.release(reservedLocale: oldest)
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule(locale: locale)]) {
            Log.speech.info("Downloading speech model for \(locale.identifier, privacy: .public)")
            try await request.downloadAndInstall()
            Log.speech.info("Speech model installed")
        }
        return locale
    }

    private static func requestAuthorization() async throws {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            Log.speech.error("Speech recognition authorization: \(status.rawValue)")
            throw TranscriptionError.speechRecognitionDenied
        }
    }

    // MARK: - Session

    func start(onResult: @escaping @MainActor (_ text: String, _ isFinal: Bool) -> Void) async throws {
        let module = Self.makeModule(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.noCompatibleAudioFormat
        }
        analyzerFormat = format

        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.continuation = continuation

        let speaker = speaker
        resultsTask = Task {
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await onResult(text, isFinal)
                }
            } catch {
                Log.speech.error("\(speaker.label, privacy: .public) results failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await analyzer.start(inputSequence: stream)
        Log.speech.info("\(speaker.label, privacy: .public) analyzer started, format: \(format.description, privacy: .public)")
    }

    /// Converts to the analyzer's format and yields. An unconverted buffer is silently ignored
    /// by the analyzer, so conversion is mandatory.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation, let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Flushes volatile text into final results and waits for the last of them.
    func finish() async {
        continuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.speech.error("finalize failed: \(error.localizedDescription, privacy: .public); cancelling")
            await analyzer?.cancelAndFinishNow()
        }
        await resultsTask?.value
        release()
    }

    func cancel() async {
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        release()
    }

    private func release() {
        analyzer = nil
        continuation = nil
        resultsTask = nil
        converter = nil
        Log.speech.info("\(self.speaker.label, privacy: .public) analyzer released")
    }

    // MARK: - Conversion

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = analyzerFormat else { return nil }
        if buffer.format == target { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
            converter?.downmix = true
            if converter == nil {
                Log.speech.error("No converter from \(buffer.format.description, privacy: .public) to \(target.description, privacy: .public)")
            }
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.speech.error("Conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
