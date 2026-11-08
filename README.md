# MeetingScribe

A macOS menu-bar app that transcribes your meetings live and writes structured notes when they end, **entirely on your Mac**. No accounts, no API keys, no cloud, and no network calls anywhere in the transcription or summarization path.

It works with any meeting app (Zoom, Meet, Teams, a browser tab, a phone call through your Mac) because it listens to the Mac's audio output, not to a particular app. It doesn't join the call as a bot, and nobody else on the call sees anything.

The full design is in [`MeetingScribe — Technical Specification.md`](MeetingScribe%20—%20Technical%20Specification.md).

## Why use it

- **Private by construction.** Audio, transcripts and notes never leave the machine. Speech recognition runs on Apple's on-device `SpeechAnalyzer`, and summarization runs on Apple's on-device `FoundationModels` language model. The binary contains no networking code at all, so the privacy claim can be checked rather than taken on trust.
- **Free to run.** There are no per-minute transcription fees and no subscription. The models ship with macOS.
- **Built not to be noticed.** It sits in the menu bar, uses about 11 MB and 0% CPU when idle, and runs speech recognition on the Neural Engine, the most power-efficient part of Apple silicon. See [Efficiency](#efficiency).
- **The transcript is always kept.** Notes are a convenience, so no failure in note generation can block, delay or delete a transcript. The transcript is written to disk before the summarizer runs.
- **Plain files you own.** Each meeting is saved as two Markdown files in `~/Documents/MeetingScribe/`, ready for any notes app, editor or search tool.

## What you get

```
~/Documents/MeetingScribe/2026-11-04 1322 Weekly sync/
├── transcript.md   # timestamped, speaker-labelled record
└── notes.md        # summary, decisions, action items, open questions
```

```markdown
**[09:42:13] Them:** Design says Friday is fine. So we're agreed, launch on the 18th.

**[09:42:21] Me:** Great. I'll update the release checklist today.
```

```markdown
## Decisions
- Launch on the 18th

## Action items
- Me — update the release checklist
- Priya — send the announcement email
```

## Requirements

- macOS 26 or later, on Apple silicon
- Full Xcode 26+ to build (the Command Line Tools alone can't expand the `@Generable` macro used for notes)
- Apple Intelligence turned on, for notes only. Transcription works without it.

## Build and run

```sh
scripts/build.sh <signing-identity-hash>   # assembles and signs build/MeetingScribe.app
open build/MeetingScribe.app               # a waveform icon appears in the menu bar
```

Find your identity with `security find-identity -v -p codesigning`. Pass the 40-character hash rather than the name, because two certificates can share the same name. That command doesn't check whether a certificate has been revoked, and macOS flags an app signed with a revoked certificate as malware.

With no argument the script signs ad hoc (`-`). That works, but macOS ties privacy permissions to the signature, and an ad-hoc signature changes on every rebuild. If permissions start misbehaving:

```sh
tccutil reset Microphone app.meetingscribe
tccutil reset SpeechRecognition app.meetingscribe
tccutil reset ScreenCapture app.meetingscribe
```

While fixing compile errors, `swift build -c release` is faster and quieter. Only assemble the bundle once it builds clean. Always run the app from the bundle: permissions attach to a bundle identity, and a bare binary fails in confusing ways.

**If the menu-bar icon is hidden** (on notched MacBooks macOS hides overflow icons behind the notch, and the orange mic indicator takes up room), run `open build/MeetingScribe.app` again to open the panel as a normal window. Quitting while recording, including `pkill`, saves the transcript first.

## Diagnostics

Everything logs to one subsystem:

```sh
/usr/bin/log stream --predicate 'subsystem == "app.meetingscribe"' --level debug
```

Use `/usr/bin/log`, because in zsh a bare `log` can be shadowed. The log includes:

- Every ~4 s while recording, the buffer count and peak RMS level per stream. An all-zero level almost always means a permission was denied or the input is muted.
- On stop, per stream: `gate forwarded X of Y buffers (Z%), fed N, M final results`.
- Every Core Audio failure, with the step name and its `OSStatus`.

| What you see | Likely cause |
|---|---|
| `peak RMS 0.0000` on system audio | Screen & System Audio Recording permission denied |
| `peak RMS 0.0000` on the microphone | Microphone permission denied, or the input is muted |
| RMS shows signal but `0 final results` | Format conversion problem; send the log |

To check the build against the spec's budgets: run `sudo powermetrics --samplers cpu_power,gpu_power,ane_power -i 2000` while recording, and `footprint $(pgrep -f MeetingScribe.app/Contents/MacOS)` for memory.

For testing only: launching with `MEETINGSCRIBE_FAIL_CHUNK=<index>` forces one summarization chunk to fail, to exercise the partial-notes path.

## Architecture

```
 System output ──► Process tap ──► Speech gate ──► SpeechAnalyzer ("Them") ─┐
 (every app but this one,          (RMS + hangover)  Neural Engine           │
  Spotify, Music)                                                            ├─► TranscriptStore ──► transcript.md
 Microphone ────► AVAudioEngine ─► Speech gate ──► SpeechAnalyzer ("Me")  ──┘   (merge, coalesce,       │
 (optional)                                          Neural Engine               publish ≤ 4 Hz)        │
                                                                                                        ▼
                                                                  after the meeting:  NoteMaker (FoundationModels)
                                                                                      map-reduce ──► notes.md
```

**Two streams, two sessions, free speaker labels.** Apple's Speech framework has no speaker diarization. Instead of shipping a diarization model, the microphone is "Me" and the system output is "Them". Each runs its own `SpeechAnalyzer` session, and the stream an utterance arrived on is its label. For "who committed to what", that's the distinction that matters, and it costs nothing.

**System audio without drivers.** A Core Audio process tap (`CATapDescription`) read through a private aggregate device captures what the Mac plays, before it reaches any output device. Speakers, AirPods and HDMI all work, with no kernel extension or virtual audio driver. The tap is unmuted, so you keep hearing the call. It excludes this app, and Spotify and Music by default, so background music never enters the transcript.

| Source | Responsibility |
|---|---|
| `App/MeetingScribeApp.swift` | `MenuBarExtra` shell, panel UI, quit and relaunch safety net |
| `App/RecorderController.swift` | State machine, orchestration, permissions, saving |
| `Audio/SystemAudioTap.swift` | Process tap and aggregate device, strict teardown order |
| `Audio/MicrophoneCapture.swift` | `AVAudioEngine` input tap |
| `Audio/SpeechGate.swift` | Silence gate with hangover and pre-roll |
| `Audio/LevelMeter.swift`, `PCMBuffer+Utils.swift` | Level diagnostics, real-time-safe buffer copy, RMS |
| `Transcription/LiveTranscriber.swift` | One `SpeechAnalyzer` session: model install, format conversion, results |
| `Transcription/TranscriptStore.swift` | Final and in-progress text, coalescing, Markdown rendering |
| `Notes/NoteMaker.swift` | Availability checks, chunking, map-reduce, `notes.md` |
| `Support/Log.swift` | The `app.meetingscribe` log subsystem |

**Transcript model.** Only finalized text enters the record. The model's in-progress guesses are shown greyed out, replaced in place when final, and never written to disk. Consecutive fragments from the same speaker within 12 s merge into one paragraph, so the transcript reads as speech rather than fragments. Timestamps are wall-clock ("09:42"), which is more useful in notes than an offset into a recording.

**Notes.** These are written once, after the meeting, by Apple's ~3B on-device model. Its context window is small, so long meetings go through map-reduce:

1. The transcript is split on line boundaries into ~3,000-character chunks, so a speaker turn is never cut.
2. Each chunk gets a fresh session and is condensed to at most four tagged bullets (`Decision:`, `Action (Owner):`, `Question:`, `Topic:`).
3. A final pass turns those bullets into the notes.

Output is typed with `@Generable` (summary, decisions, action items, open questions) instead of parsed from prose. A failed chunk is logged and skipped, and the notes say they may be incomplete. A total failure still leaves the transcript, with the reason written into `notes.md`.

## Efficiency

On a laptop, users notice memory pressure, fan noise, battery drain and latency, roughly in that order. None of those improve with faster arithmetic. They improve by not running at all, and by running on the right silicon when you do run. The spec's budgets are acceptance criteria, not goals.

| Budget | Measured |
|---|---|
| Idle: under 50 MB resident | **~11 MB** |
| Idle: 0% CPU, no periodic wakeups | **0.0% CPU, 0 idle wakeups** (60 s sample) |
| Recording: under 5% CPU, no sustained GPU | Speech runs on the Neural Engine; check with `powermetrics` |
| Between meetings: no model weights resident | Models unload at the end of each session |

How it stays that light:

- **Silence never reaches the Neural Engine.** Each stream is gated on RMS level with a 300 ms hangover, so word endings aren't cut off, and one buffer of pre-roll, so word beginnings aren't either. You talk for a fraction of any call, and the system tap keeps delivering buffers through every pause.
- **Larger audio buffers.** The tap's buffer is 4096 frames, so the audio callback fires about 12 times a second instead of about 90.
- **No timers while hidden.** The elapsed-time label ticks only while the panel is open and stops when it closes. A 1 Hz timer in a menu-bar app wakes the CPU 3,600 times an hour to update text nobody sees.
- **Batched UI updates.** Transcript changes reach SwiftUI at most four times a second, and only when results arrive.
- **Loaded on demand, released on stop.** Analyzers, converters and model sessions exist only during a meeting.
- **One job while recording.** No summarizing, indexing or heavy disk work runs during a call.
- **The machine comes first.** Notes are postponed when the Mac is hot or in Low Power Mode, and the panel says so. **Retry notes** runs them anyway.

## Design decisions

- **Apple frameworks only.** The Neural Engine is the most power-efficient silicon on the chip, and only Apple's frameworks can target it; ggml/llama.cpp run on the GPU and CPU. A third-party runtime would have to justify itself with a capability Apple lacks, never with speed.
- **macOS 26 only, no fallback.** `SpeechAnalyzer`, `SpeechTranscriber` and `FoundationModels` don't exist on earlier releases, and an `SFSpeechRecognizer` path would double the surface area.
- **Swift 5 language mode.** Core Audio callbacks pass non-`Sendable` buffers by design. Strict concurrency checking there adds ceremony without adding safety.
- **No hardened runtime.** For a locally built tool, it blocks audio input unless provisioned entitlements are embedded.
- **Copy before crossing threads.** Render callbacks may reuse their buffers as soon as they return, so every buffer is deep-copied on the audio thread.

## Findings from building it

These came up during implementation and aren't in Apple's documentation:

- **Gating silence stops sentences from finalizing.** The analyzer ends an utterance when it hears a pause, and the gate removes pauses. Without a fix, text stayed grey until the next sentence. Calling `finalize(through: nil)` mid-stream garbled the output. Injecting 1.5 s of synthetic silence when the gate closes finalizes promptly; 1.0 s was unreliable. In a test clip of mostly speech, the gate forwarded 51% of buffers, and real meetings have far more silence.
- **Unconverted audio fails silently.** The analyzer accepts a buffer in the wrong format and ignores it. Every buffer is converted to `bestAvailableAudioFormat` (16 kHz mono Int16 here) with a cached `AVAudioConverter`.
- **`SpeechAnalyzer.Options` has no resource-limit override**, only `priority` and `modelRetention`. On an M3 Pro, two concurrent sessions start fine. If a second session is ever refused, the app logs a fault, warns you and keeps transcribing system audio.
- **The small model needs explicit instructions.** Without being told, it invented details (a month that was never mentioned), merged decisions with action items, and returned "None" as a list item. Telling it what the "Me" and "Them" tags mean, giving it the "Owner — task" format with an example, forbidding details that aren't in the transcript, and tagging digest bullets by kind all improved the notes. Placeholder items are filtered out afterwards. Results still vary from run to run, and `notes.md` says so.

## Known limitations

- **Echo without headphones.** The mic hears the call through the speakers, so remote speech can also appear as "Me". Use headphones. The real fix, echo cancellation using the tap as the reference signal, is planned.
- **Switching output devices mid-recording.** If AirPods connect or disconnect during a recording, the tap may stop. Recovery isn't implemented yet.
- **The notes model is small.** It condenses what's in front of it well but has no outside knowledge. The transcript is the record.
- **Language follows `Locale.current`.** There's no language picker yet, and around ten languages have on-device models.

## Where this goes next

The order matters and explains why v1 is shaped the way it is:

1. **Speaker diarization.** This is the gap felt in every meeting. Apple has no API for it, so a ggml speaker-embedding model run over the system stream after the meeting is the real fix.
2. **Long-context summarization.** Map-reduce blurs threads that cross chunk boundaries, and a 32k-context local model could take a whole hour in one pass. On an M3 Pro, memory bandwidth (~150 GB/s) is the limit, not capacity. Pick the model size by acceptable wait time.
3. **Cross-meeting retrieval.** A local embedding index could answer "what did we decide about this last month?" This is where a meetings tool becomes a personal agent, and it's the part no cloud product can offer without being handed the data. The lasting advantage is the private archive, not inference speed.

Also deferred: echo cancellation, pause and resume, auto-start when a meeting app begins using audio, and a language picker.
