import Foundation
import FoundationModels

@Generable
struct MeetingNotes {
    @Guide(description: "Two or three sentences on what the meeting was about and what came of it, no preamble")
    var summary: String

    @Guide(description: "Only what was actually settled; empty if nothing was")
    var decisions: [String]

    @Guide(description: "Each as \"Owner — the task\"; \"Me\" for the local speaker, \"Unassigned\" when no owner was named")
    var actionItems: [String]

    @Guide(description: "Questions raised but left unresolved; empty if none")
    var openQuestions: [String]
}

@Generable
struct ChunkDigest {
    @Guide(description: """
        The most important points of this excerpt. Start each with its kind: \
        "Decision:", "Action (Owner):" naming who committed, "Question:" for something left unresolved, \
        or "Topic:" for what was discussed.
        """, .maximumCount(4))
    var bullets: [String]
}

struct NotesOutcome {
    let notes: MeetingNotes?
    /// Plain-language reason notes are missing or partial.
    let problem: String?
    let failedChunks: Int
    let totalChunks: Int
}

/// Post-meeting map-reduce summarization on the on-device model. Never throws: every failure
/// becomes a reason in the outcome, because notes must never cost the transcript.
enum NoteMaker {
    static let chunkSize = 3_000
    /// Above this, digests are themselves digested again before the final reduce.
    static let reduceLimit = 6_000

    static let instructions = """
        You turn meeting transcripts into concise notes. The transcript is speaker-tagged: \
        "Me" is the local user, "Them" is everyone else on the call. Use only what the transcript says. \
        A decision is something the group settled; an action item is a task someone took on, \
        written as "Owner — the task", for example "Priya — send the announcement email". \
        Include every task someone took on, including ones "Me" took on. \
        Never add details that aren't in the transcript, such as months, names or numbers. \
        Leave a section empty rather than filling it with plausible-sounding items.
        """

    /// Debug hook for the failure-path acceptance test: MEETINGSCRIBE_FAIL_CHUNK=<index>.
    private static let forcedFailureChunk = ProcessInfo.processInfo.environment["MEETINGSCRIBE_FAIL_CHUNK"].flatMap(Int.init)

    /// Why the model can't run at all, in plain language; nil when available.
    static func availabilityProblem() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence, so notes aren't available."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading. Try again shortly."
        case .unavailable(let other):
            return "Apple Intelligence is unavailable (\(other))."
        }
    }

    /// Why heavy work should wait right now; nil when the machine is fine.
    static func resourceProblem() -> String? {
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical {
            return "Your Mac is running hot, so notes were postponed. Use Retry notes to write them anyway."
        }
        if info.isLowPowerModeEnabled {
            return "Low Power Mode is on, so notes were postponed. Use Retry notes to write them anyway."
        }
        return nil
    }

    /// `deferIfConstrained == false` is an explicit user request that overrides thermal/low-power deferral.
    static func makeNotes(from transcript: String, deferIfConstrained: Bool = true) async -> NotesOutcome {
        if let problem = availabilityProblem() ?? (deferIfConstrained ? resourceProblem() : nil) {
            Log.notes.notice("Notes skipped: \(problem, privacy: .public)")
            return NotesOutcome(notes: nil, problem: problem, failedChunks: 0, totalChunks: 0)
        }

        let chunks = chunk(transcript, size: chunkSize)
        guard !chunks.isEmpty else {
            return NotesOutcome(notes: nil, problem: "No speech was transcribed, so there was nothing to summarize.",
                                failedChunks: 0, totalChunks: 0)
        }

        var material = transcript
        var failed = 0
        if chunks.count > 1 {
            let (digest, failures) = await digestAll(chunks, label: "chunk")
            failed = failures
            guard failed < chunks.count else {
                return NotesOutcome(notes: nil, problem: "Every part of the transcript failed to summarize.",
                                    failedChunks: failed, totalChunks: chunks.count)
            }
            material = digest
            // Very long meetings: digest the digests until they fit the final pass.
            while material.count > reduceLimit {
                let groups = chunk(material, size: chunkSize)
                guard groups.count > 1 else { break }
                material = await digestAll(groups, label: "digest group").text
            }
        }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = chunks.count > 1
                ? "These are notes on consecutive parts of one meeting, in order. Write the meeting notes.\n\n\(material)"
                : "Write the meeting notes for this transcript.\n\n\(material)"
            let notes = try await session.respond(to: prompt, generating: MeetingNotes.self).content
            Log.notes.info("Notes written from \(chunks.count - failed) of \(chunks.count) chunks")
            return NotesOutcome(notes: notes, problem: nil, failedChunks: failed, totalChunks: chunks.count)
        } catch {
            Log.notes.error("Final notes pass failed: \(String(describing: error), privacy: .public)")
            return NotesOutcome(notes: nil, problem: "The notes model failed: \(error.localizedDescription)",
                                failedChunks: failed, totalChunks: chunks.count)
        }
    }

    /// One fresh session per chunk: the chunks are independent, and carried context only eats tokens.
    private static func digestAll(_ chunks: [String], label: String) async -> (text: String, failures: Int) {
        var lines: [String] = []
        var failures = 0
        for (index, chunk) in chunks.enumerated() {
            do {
                if index == forcedFailureChunk {
                    throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "forced failure"])
                }
                let session = LanguageModelSession(instructions: instructions)
                let digest = try await session.respond(to: "Summarize this excerpt.\n\n\(chunk)", generating: ChunkDigest.self)
                lines += digest.content.bullets.map { "- \($0)" }
            } catch {
                failures += 1
                Log.notes.error("\(label, privacy: .public) \(index + 1)/\(chunks.count) failed, skipping: \(String(describing: error), privacy: .public)")
            }
        }
        return (lines.joined(separator: "\n"), failures)
    }

    /// Splits on line boundaries so a speaker turn is never cut, except a single turn longer
    /// than `size`, which is split at sentence ends and re-tagged with its speaker.
    static func chunk(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        func push(_ line: String) {
            if !current.isEmpty, current.count + line.count + 1 > size {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        for line in text.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.count <= size {
                push(line)
            } else {
                splitLongLine(line, size: size).forEach(push)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func splitLongLine(_ line: String, size: Int) -> [String] {
        let prefix = line.firstRange(of: ": ").map { String(line[..<$0.upperBound]) } ?? ""
        let body = String(line.dropFirst(prefix.count))
        var pieces: [String] = []
        var current = ""
        body.enumerateSubstrings(in: body.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if !current.isEmpty, prefix.count + current.count + sentence.count > size {
                pieces.append(prefix + current)
                current = ""
            }
            current += sentence
        }
        if !current.isEmpty { pieces.append(prefix + current) }
        return pieces
    }

    static func markdown(_ outcome: NotesOutcome, title: String) -> String {
        var out = "# \(title) — Notes\n\n"
        out += "_Written on-device by a small (~3B) language model. It condenses what was said and has no outside knowledge. "
        out += "The transcript is the record; check it before relying on anything here._\n\n"

        guard let notes = outcome.notes else {
            out += "**Notes are not available.** \(outcome.problem ?? "Unknown reason.")\n\n"
            out += "The full transcript was saved in `transcript.md`.\n"
            return out
        }
        if outcome.failedChunks > 0 {
            out += "> \(outcome.failedChunks) of \(outcome.totalChunks) parts of the transcript couldn't be summarized; "
            out += "these notes may miss what was said there.\n\n"
        }
        out += "## Summary\n\n\(notes.summary)\n\n"
        out += section("Decisions", notes.decisions)
        out += section("Action items", notes.actionItems)
        out += section("Open questions", notes.openQuestions)
        return out
    }

    private static func section(_ heading: String, _ items: [String]) -> String {
        // The model sometimes emits a placeholder instead of an empty list.
        let placeholders: Set<String> = ["none", "n/a", "na", "nothing", "-", "none."]
        let items = items
            .filter { !placeholders.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
            .map { $0.replacingOccurrences(of: " -- ", with: " — ") }
        let body = items.isEmpty ? "None.\n" : items.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return "## \(heading)\n\n\(body)\n"
    }
}
