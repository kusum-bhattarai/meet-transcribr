import Accelerate
import AVFoundation

extension AVAudioPCMBuffer {
    /// Deep-copies a render-callback buffer list. The caller may reuse its memory as soon
    /// as the callback returns, so this must happen before crossing any thread boundary.
    static func copying(_ source: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard let first = src.first, bytesPerFrame > 0, first.mDataByteSize > 0 else { return nil }

        let frames = first.mDataByteSize / bytesPerFrame
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames

        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }

    func deepCopy() -> AVAudioPCMBuffer? {
        .copying(audioBufferList, format: format)
    }

    /// Root-mean-square level across all channels (Float32 only; other formats report 0).
    var rms: Float {
        guard format.commonFormat == .pcmFormatFloat32, frameLength > 0 else { return 0 }
        var sumSquares: Float = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(mutableAudioBufferList) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            var ss: Float = 0
            vDSP_svesq(data, 1, &ss, vDSP_Length(n))
            sumSquares += ss
            count += n
        }
        return count > 0 ? (sumSquares / Float(count)).squareRoot() : 0
    }
}
