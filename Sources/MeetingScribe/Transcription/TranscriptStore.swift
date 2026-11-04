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
///
/// Results land in unobserved working state; the observed copies are published at most
/// every `publishInterval`, so SwiftUI isn't re-laying-out on every fragment.
@MainActor
@Observable
final class TranscriptStore {
    /// Consecutive same-speaker fragments within this window merge into one paragraph.
    static let coalesceWindow: TimeInterval = 12
    static let publishInterval: Duration = .milliseconds(250)

    private(set) var segments: [TranscriptSegment] = []
    private(set) var volatile: [Speaker: String] = [:]
    private(set) var wordCount = 0

    @ObservationIgnored private var working: [TranscriptSegment] = []
    @ObservationIgnored private var workingVolatile: [Speaker: String] = [:]
    @ObservationIgnored private var workingWords = 0
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    func apply(_ text: String, from speaker: Speaker, isFinal: Bool, at date: Date = Date()) {
        defer { schedulePublish() }
        guard isFinal else {
            workingVolatile[speaker] = text
            return
        }
        workingVolatile[speaker] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workingWords += trimmed.split(whereSeparator: \.isWhitespace).count

        if let last = working.indices.last,
           working[last].speaker == speaker,
           date.timeIntervalSince(working[last].lastUpdated) <= Self.coalesceWindow {
            working[last].text += " " + trimmed
            working[last].lastUpdated = date
        } else {
            working.append(TranscriptSegment(speaker: speaker, text: trimmed, timestamp: date, lastUpdated: date))
        }
    }

    /// One-shot deferred publish; no timer runs while nothing is arriving.
    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            self?.publishNow()
        }
    }

    func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        segments = working
        volatile = workingVolatile
        wordCount = workingWords
    }

    /// The artifact of record: title, recording date, one bolded `[HH:mm:ss] Speaker:` per paragraph.
    func markdown(title: String, start: Date, end: Date) -> String {
        var out = "# \(title)\n\n"
        out += "Recorded \(Self.format(start, "yyyy-MM-dd HH:mm"))–\(Self.format(end, "HH:mm"))\n\n"
        if working.isEmpty {
            out += "_No speech was transcribed._\n"
        }
        for segment in working {
            out += "**[\(Self.format(segment.timestamp, "HH:mm:ss"))] \(segment.speaker.label):** \(segment.text)\n\n"
        }
        return out
    }

    private static var formatters: [String: DateFormatter] = [:]

    static func format(_ date: Date, _ pattern: String) -> String {
        if let formatter = formatters[pattern] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        formatters[pattern] = formatter
        return formatter.string(from: date)
    }

    func reset() {
        working = []
        workingVolatile = [:]
        workingWords = 0
        publishNow()
    }
}
