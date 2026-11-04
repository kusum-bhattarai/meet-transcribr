import Foundation
import Observation

enum Speaker: String {
    case me, others

    var label: String {
        switch self {
        case .me: "Me"
        case .others: "Them"
        }
    }
}

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let speaker: Speaker
    var text: String
    /// Wall-clock time the first fragment finalized.
    let timestamp: Date
    /// Wall-clock time of the most recent merged fragment, for coalescing.
    var lastUpdated: Date
}

/// Merged chronological record. Only finalized text enters `segments`;
/// volatile text is held per speaker for display and never persisted.
@MainActor
@Observable
final class TranscriptStore {
    /// Consecutive same-speaker fragments within this window merge into one paragraph.
    static let coalesceWindow: TimeInterval = 12

    private(set) var segments: [TranscriptSegment] = []
    private(set) var volatile: [Speaker: String] = [:]

    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    func apply(_ text: String, from speaker: Speaker, isFinal: Bool, at date: Date = Date()) {
        guard isFinal else {
            volatile[speaker] = text
            return
        }
        volatile[speaker] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let last = segments.indices.last,
           segments[last].speaker == speaker,
           date.timeIntervalSince(segments[last].lastUpdated) <= Self.coalesceWindow {
            segments[last].text += " " + trimmed
            segments[last].lastUpdated = date
        } else {
            segments.append(TranscriptSegment(speaker: speaker, text: trimmed, timestamp: date, lastUpdated: date))
        }
    }

    /// The artifact of record: title, recording date, one bolded `[HH:mm:ss] Speaker:` per paragraph.
    func markdown(title: String, start: Date, end: Date) -> String {
        var out = "# \(title)\n\n"
        out += "Recorded \(Self.format(start, "yyyy-MM-dd HH:mm"))–\(Self.format(end, "HH:mm"))\n\n"
        if segments.isEmpty {
            out += "_No speech was transcribed._\n"
        }
        for segment in segments {
            out += "**[\(Self.format(segment.timestamp, "HH:mm:ss"))] \(segment.speaker.label):** \(segment.text)\n\n"
        }
        return out
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    func reset() {
        segments = []
        volatile = [:]
    }
}
