import AVFoundation

/// Drops silent buffers before they reach the Neural Engine. A buffer passes when its RMS
/// clears `threshold`, and for `hangover` seconds afterwards so word tails aren't clipped.
/// The last dropped buffer is kept as pre-roll so word onsets aren't clipped either.
/// Not thread-safe: use from the stream's own capture thread.
final class SpeechGate {
    static let threshold: Float = 0.004
    static let hangover: TimeInterval = 0.3

    private var hangoverRemaining: TimeInterval = 0
    private var preroll: AVAudioPCMBuffer?
    private var isOpen = false
    private(set) var received = 0
    private(set) var forwarded = 0

    /// Buffers to forward, in order (empty while silent). `closed` is true on the first
    /// dropped buffer after speech: the moment to ask the analyzer to finalize, since it
    /// never sees the silence that would otherwise end the utterance.
    func process(_ buffer: AVAudioPCMBuffer) -> (buffers: [AVAudioPCMBuffer], closed: Bool) {
        received += 1
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        var out: [AVAudioPCMBuffer] = []
        var closed = false
        if buffer.rms >= Self.threshold {
            if let preroll {
                out.append(preroll)
                self.preroll = nil
            }
            hangoverRemaining = Self.hangover
            out.append(buffer)
        } else if hangoverRemaining > 0 {
            hangoverRemaining -= duration
            out.append(buffer)
        } else {
            preroll = buffer
            closed = isOpen
        }
        isOpen = !out.isEmpty
        forwarded += out.count
        return (out, closed)
    }

    var summary: String {
        let pct = received > 0 ? Double(forwarded) / Double(received) * 100 : 0
        return "gate forwarded \(forwarded) of \(received) buffers (\(String(format: "%.0f", pct))%)"
    }
}
