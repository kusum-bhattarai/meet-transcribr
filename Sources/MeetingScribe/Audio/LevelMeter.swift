import AVFoundation

/// Per-stream buffer count and peak level, logged every 50 buffers so an all-silent
/// stream (usually a denied permission or muted device) is visible in the log.
/// Not thread-safe: use from the stream's own capture thread.
final class LevelMeter {
    private let name: String
    private(set) var bufferCount = 0
    private var peakRMS: Float = 0

    init(name: String) { self.name = name }

    func record(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1
        peakRMS = max(peakRMS, buffer.rms)
        if bufferCount % 50 == 0 {
            Log.audio.debug("\(self.name, privacy: .public): \(self.bufferCount) buffers, peak RMS \(self.peakRMS, format: .fixed(precision: 4))")
            peakRMS = 0
        }
    }
}
