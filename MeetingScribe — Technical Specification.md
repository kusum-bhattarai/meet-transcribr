# MeetingScribe — Technical Specification

Nov 4, 2026 · @Kusum

## Goal and non-negotiables

Build a macOS menu-bar app that transcribes a meeting live and writes structured notes when it ends, entirely on-device. It should sit with the user through the whole call and cost them nothing they can perceive.

Four constraints are not negotiable:

- **No keys, no accounts, no cloud.** There must be no network call anywhere in the transcription or summarization path.
- **Apple frameworks first.** Apple's speech and language models run on the Neural Engine, which is the most power-efficient silicon on the chip. A third-party runtime is justified only by a capability Apple does not offer, never by expected speed.
- **"Feels like nothing" is measured, not asserted.** The budgets in Efficiency requirements are acceptance criteria, not aspirations.
- **The transcript is the artifact of record.** Notes are a convenience. No failure in note generation may ever block, delay, or destroy a transcript.

## Platform requirements

Target macOS 26 or later and do not build a fallback path. `SpeechAnalyzer`, `SpeechTranscriber` and `FoundationModels` are all 26.0+ with no back-deployment, so an `SFSpeechRecognizer` path would double the surface area to serve machines this app is not for.

| Requirement | Detail |
| --- | --- |
| OS | macOS 26.0+ |
| Toolchain | Full Xcode 26+, not just Command Line Tools — the `@Generable` macro needs the macro toolchain and the 26 SDK |
| Apple Intelligence | Required for notes only; transcription works without it |
| Target machine | MacBook Pro M3 Pro, 36 GB unified memory, \~150 GB/s memory bandwidth, 16-core Neural Engine |
| Swift language mode | 5, set explicitly via `swiftLanguageMode(.v5)` |

Swift 6 strict concurrency checking is deliberately off. Core Audio's C callbacks and `AVAudioEngine` render taps hand around non-`Sendable` buffers by design, and satisfying the checker there produces ceremony without safety. Optimise for the machine above and assume no more than it.

## Architecture

Two capture streams run independently, each into its own transcription session, and the stream an utterance arrived on is what labels its speaker.

&#91;embedded content: pipeline · 2 capture streams, 2 transcribers, 1 post-meeting pass\]

The two highlighted gates are where silence is dropped before it ever reaches the Neural Engine; everything to the right of them runs only on audio that contains speech.

Apple's Speech framework has no speaker diarization — `SpeechDetector` detects voice activity, not identity. Rather than carry a diarization model in v1, the microphone becomes "Me" and the system output becomes "Them". That is the distinction that matters when the question is who committed to what, and it costs nothing.

| File | Responsibility |
| --- | --- |
| `SystemAudioTap.swift` | Core Audio process tap and private aggregate device; excludes this app and music players |
| `MicrophoneCapture.swift` | `AVAudioEngine` input tap; optional, user-toggleable |
| `LiveTranscriber.swift` | One `SpeechAnalyzer` session: asset install, format conversion, result handling |
| `TranscriptStore.swift` | Merged chronological record, coalescing, markdown rendering |
| `NoteMaker.swift` | Post-meeting map-reduce summarization |
| `RecorderController.swift` | Orchestration, permissions, saving to disk |
| `MeetingScribeApp.swift` | `MenuBarExtra` shell and live transcript view |

## Audio capture

Two capture paths, deliberately separate. Both deliver `AVAudioPCMBuffer` on a real-time audio thread: do not allocate heavily, lock, or touch UI inside the callbacks, and copy any buffer before it crosses a thread boundary.

### System audio — the other participants

A Core Audio process tap feeding a private aggregate device. No kernel extension, no virtual audio driver, no third-party software.

1. Build a `CATapDescription(stereoGlobalTapButExcludeProcesses:)`. The array takes Core Audio **process object IDs**, not PIDs — translate with `kAudioHardwarePropertyTranslatePIDToProcessObject` on the system object.
2. Always exclude this app's own process. Also exclude `com.spotify.client` and `com.apple.Music` by default, so background music never enters the transcript, and keep that list configurable.
3. Set `uuid` (this becomes the tap's UID, referenced later by the aggregate device), `name`, `isPrivate = true`, and `muteBehavior = .unmuted`. Unmuted is essential: the user has to keep hearing the call.
4. `AudioHardwareCreateProcessTap(description, &tapID)`.
5. Read the tap's format from `kAudioTapPropertyFormat` on the tap object and wrap it with `AVAudioFormat(streamDescription:)`.
6. A tap is only readable as an input of an aggregate device. Create one with `AudioHardwareCreateAggregateDevice` using the keys in the table below.
7. Set `kAudioDevicePropertyBufferFrameSize` to 4096 before starting. The device default of roughly 512 frames fires the render callback about 90 times a second; 4096 brings that to about 12. Treat failure as harmless and carry on.
8. `AudioDeviceCreateIOProcIDWithBlock`, then `AudioDeviceStart`.

Tear down in strict order: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`.

| Aggregate device key | Value |
| --- | --- |
| `kAudioAggregateDeviceNameKey` | Any display name |
| `kAudioAggregateDeviceUIDKey` | Unique per run — include the tap UUID |
| `kAudioAggregateDeviceMainSubDeviceKey` | Default output device UID |
| `kAudioAggregateDeviceIsPrivateKey` | `true` — visible only to this process |
| `kAudioAggregateDeviceIsStackedKey` | `false` |
| `kAudioAggregateDeviceTapAutoStartKey` | `true` |
| `kAudioAggregateDeviceSubDeviceListKey` | `[[kAudioSubDeviceUIDKey: output UID]]` |
| `kAudioAggregateDeviceTapListKey` | `[[kAudioSubTapUIDKey: tap uuid string, kAudioSubTapDriftCompensationKey: true]]` |

Get the default output UID from `kAudioHardwarePropertyDefaultOutputDevice`, then `kAudioDevicePropertyDeviceUID` on that device.

In the render callback, copy the incoming `AudioBufferList` into an `AVAudioPCMBuffer`: frame count is `mDataByteSize / mBytesPerFrame`, then `memcpy` per channel. Bail out early on zero-length buffers.

### Microphone — the user

`AVAudioEngine` with `inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNode.outputFormat(forBus: 0))`. Guard that the format's sample rate is above zero; zero means there is no usable input device, which is a clear error rather than a silent no-op. Request access with `AVCaptureDevice.requestAccess(for: .audio)` before starting.

Make microphone capture optional via a user-facing toggle. Running system-audio only halves the transcription load and is the right default for someone who mostly listens.

## Live transcription

One `SpeechAnalyzer` session per capture stream, each with its own `SpeechTranscriber` module. Both run on the Neural Engine and never touch the network.

### Setup, in order

1. **Check device support** with `SpeechTranscriber.isAvailable`.
2. **Resolve the locale** via `SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)`. A `nil` result means the language has no model — surface that as a clear error, not a crash. Roughly ten languages shipped.
3. **Manage asset reservations.** Read `AssetInventory.reservedLocales`; if the locale is not reserved and the count has reached `AssetInventory.maximumReservedLocales`, release the oldest with `AssetInventory.release(reservedLocale:)`.
4. **Install the model.** `AssetInventory.assetInstallationRequest(supporting: [transcriber])` returns `nil` when everything is already installed; otherwise call `downloadAndInstall()`. First run can take a minute, so the UI needs a "preparing" state.
5. **Build the transcriber with explicit options**, not a preset: `transcriptionOptions: []`, `reportingOptions: [.volatileResults, .fastResults]`, `attributeOptions: []`. Volatile results give live partial text; fast results trade a little accuracy for latency, which is the right call for text on screen. Build the probe transcriber used in step 4 with the *same* options so the requested asset set matches what you actually run.
6. **Create the analyzer** with `SpeechAnalyzer(modules: [transcriber])` and get its required format from `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`.
7. **Open the input stream** with `AsyncStream<AnalyzerInput>.makeStream()` and start it with `analyzer.start(inputSequence:)`.

### Feeding audio

Convert every buffer to the analyzer's format before yielding it. Use `AVAudioConverter` with `primeMethod = .none` and the block-based `convert(to:error:withInputFrom:)` form, since sample rates differ between the tap, the microphone and the analyzer. Cache the converter and rebuild it whenever the input format changes.

This is the single most common cause of live transcription silently producing nothing: an unconverted buffer is accepted and quietly ignored. Yield as `AnalyzerInput(buffer:)`.

### Reading results

Drain `transcriber.results` in a concurrent task. `result.text` is an `AttributedString`, so convert with `String(result.text.characters)`. `result.isFinal` separates finalized text from volatile guesses the model will revise — only finalized text may enter the transcript.

### Shutdown

Finish the stream continuation, then call `analyzer.finalizeAndFinishThroughEndOfInput()`, which flushes pending volatile text into final results. Await the results task before tearing anything down, or the last few seconds of the meeting are lost. On error, fall back to `cancelAndFinishNow()`.

### Concurrency limit

`SpeechAnalyzer` enforces a limit on concurrent sessions, so the second `start(inputSequence:)` may throw. Handle it at runtime, not at build time: either construct both analyzers with a `SpeechAnalyzer.Options` that ignores resource limits, or fall back to mixing the two streams into a single analyzer and dropping the speaker labels. Log loudly whichever path is taken.

## Efficiency requirements

What a user perceives on a laptop, in order: memory pressure causing swap, then fan, then battery, then latency. None of those are throughput problems, so none of them are solved by faster math. They are solved by not running, and by running on the right silicon when you do.

### Budgets

These are testable conditions, not goals.

| Condition | Budget | How to verify |
| --- | --- | --- |
| Idle, no meeting | 0% CPU, no periodic wakeups | Activity Monitor; `powermetrics` idle residency |
| Idle, no meeting | Under 50 MB resident | Activity Monitor memory column |
| Recording | Under 5% CPU, no sustained GPU power | `powermetrics --samplers cpu_power,gpu_power,ane_power` |
| Recording | No measurable battery delta versus the meeting app alone | Activity Monitor Energy Impact, A/B over 10 minutes |
| Between meetings | No model weights resident | Memory footprint before and after a recording |

`powermetrics` is the tool that makes this falsifiable — it reports Neural Engine power separately, which Activity Monitor will not show. Set the budgets before optimising anything, then check them, or "smooth" quietly erodes across a few months of features and nobody knows which one did it.

### Required behaviours

**Gate both feeds on actual speech.** Do not forward silent buffers to the analyzer. A meeting is mostly silence per stream: the user speaks maybe 20% of a call, and the system tap keeps delivering buffers through every pause. Compute RMS per buffer and skip anything below a threshold, with roughly 300 ms of hangover after speech stops so word tails are not clipped. This alone should cut Neural Engine work by more than half. Apple's `SpeechDetector` module is the higher-quality version of the same idea.

**No periodic timers.** An elapsed-time label driven by a 1 Hz timer wakes the CPU 3,600 times an hour to update text that is only visible while the popover is open, which is almost never. Start the timer when the panel appears, stop it when the panel disappears, and compute elapsed time from the stored start date on open. This is the most common power bug in menu-bar apps.

**Load on demand, release on finish.** Nothing loads until a recording starts. Analyzers, converters and model handles are released on stop. Never hold a summarization model resident between meetings — 36 GB of headroom is not a licence to squat on it, because free memory is not idle memory; macOS spends it on file cache.

**Coalesce UI updates.** Publish transcript changes at most about four times a second rather than once per result, so SwiftUI is not re-laying-out a growing list on every finalized fragment.

**Respect the machine before heavy work.** Check `ProcessInfo.processInfo.thermalState` and `isLowPowerModeEnabled` before the post-meeting pass. Defer when thermally constrained or on low battery, and say so in the UI rather than silently stalling.

**The live path transcribes and nothing else.** No summarization, no embedding, no indexing, no disk-heavy work while recording.

## Notes generation

Runs once, after the meeting ends, on `FoundationModels`. Free, offline, no marginal cost.

**Check availability first.** Read `SystemLanguageModel.default.availability` and translate each `unavailable` reason into plain language for the UI: `deviceNotEligible` means this Mac cannot do it, `appleIntelligenceNotEnabled` means it is switched off in System Settings, `modelNotReady` means it is still downloading and the user should retry shortly.

**Output schema.** Use `@Generable` with `@Guide` descriptions rather than parsing prose:

| Field | Type | Guide |
| --- | --- | --- |
| `summary` | `String` | Two or three sentences on what the meeting was about and what came of it, no preamble |
| `decisions` | `[String]` | Only what was actually settled; empty if nothing was |
| `actionItems` | `[String]` | Each as "Owner — the task"; "Me" for the local speaker, "Unassigned" when no owner was named |
| `openQuestions` | `[String]` | Raised but unresolved; empty if none |

**Map-reduce over the transcript.** The context window is small and shared between prompt and response, so an hour-long meeting does not fit in one pass. Split on line boundaries into roughly 3,000-character chunks so a speaker turn is never cut in half. Digest each chunk into at most four bullets using a *fresh* `LanguageModelSession` per chunk — carrying stale context across independent chunks only eats the token budget. Then reduce the digests into the final notes. Skip the digest pass entirely when there is only one chunk.

**Instructions must say what the tags mean** — that the transcript is speaker-tagged, "Me" is the local user and "Them" is everyone else — and must tell the model to leave a section empty rather than fill it with plausible-sounding items.

**Failure handling is a hard requirement.** A single failed chunk is logged and skipped; the remaining chunks still produce notes. A total failure still writes the transcript, with the reason recorded in `notes.md`. Losing a meeting because the summarizer was unavailable is the worst bug this app can have.

The model is around 3B parameters: good at condensing text placed in front of it, bad at anything needing world knowledge. Say so in the generated file. The transcript is the record; the notes are a convenience.

## Transcript model and output

`Speaker` is a two-case enum: `.me` ("Me") and `.others` ("Them"). A `TranscriptSegment` carries an id, a speaker, text, and a wall-clock timestamp taken when the segment finalized.

Finalized segments accumulate in order. Volatile text is held separately per speaker, shown greyed in the UI, and never written to disk — the model is still revising it.

**Coalescing rule.** Consecutive finalized fragments from the same speaker within 12 seconds merge into one paragraph, keeping the earlier timestamp. Without this the transcript reads as a list of disconnected fragments instead of speech.

**Timestamps are wall-clock**, not audio offsets. This is deliberate: "09:42" is more useful in meeting notes than an offset into a recording. To switch, add `.audioTimeRange` to `attributeOptions` and read `result.range` — but note that volatile results carry no time range, only finalized ones do.

**Output.** On stop, write to `~/Documents/MeetingScribe/<yyyy-MM-dd HHmm> <title>/` containing `transcript.md` and `notes.md`, then reveal the folder in Finder. Strip `/` and `:` from the title. When the user gave no title, default to "Meeting" plus the date and time.

The markdown transcript carries the title, the recording date, and one bolded `[HH:mm:ss] Speaker:` prefix per paragraph. The summarizer reads a plainer form — `Speaker: text` per line, no timestamps — which keeps tokens for content rather than formatting.

## User interface

A `MenuBarExtra` with `.menuBarExtraStyle(.window)` and `LSUIElement` set true: no Dock icon, no main window, nothing in the way. The menu bar icon is `waveform` when idle and `record.circle.fill` while recording.

The panel is about 408 pt wide and holds four things: a status row, idle-only controls, the live transcript at roughly 380 × 260, and an action row.

| State | Status shows | Actions |
| --- | --- | --- |
| Idle | "Ready" | Start recording |
| Preparing | "Preparing model…" | Start disabled |
| Recording | Elapsed time and word count | Stop & summarize, Discard |
| Finishing | "Finishing transcript…" | none |
| Summarizing | "Writing notes…" | none |
| Saved | "Saved" | Show in Finder, Start recording |
| Failed | The reason, in plain language | Start recording |

Idle-only controls: a meeting title field and a "capture my microphone too" toggle.

In the transcript view, finalized text renders solid and volatile text in a tertiary colour, so the user can see the model is still thinking rather than wondering why the words changed. Auto-scroll to the bottom on new segments, and make text selectable.

Error text must be actionable. When a permission is the cause, name the exact System Settings pane rather than reporting that something failed.

## Permissions and Info.plist

All three usage descriptions are mandatory. A missing key is not a prompt the user declines — it is an immediate crash or a silent failure with an unhelpful status code.

| Key | Needed for | Prompted | If missing |
| --- | --- | --- | --- |
| `NSMicrophoneUsageDescription` | Microphone capture | On Start | Crash or silent failure |
| `NSSpeechRecognitionUsageDescription` | The Speech framework gate, which applies even though recognition is on-device | On Start | Authorization denied |
| `NSAudioCaptureUsageDescription` | The Core Audio process tap | A beat after Start, when the tap first runs — there is no API to request it in advance | Tap creation fails with an opaque `OSStatus` |

Also required: `CFBundleIdentifier` of `app.meetingscribe`, `LSMinimumSystemVersion` of 26.0, and `LSUIElement` true.

Two things worth knowing. On macOS 26 an existing Screen Recording grant also covers system audio capture, so some users will not see the third prompt. And privacy grants attach to a *bundle*: a bare binary from `swift build` has no Info.plist identity and will fail in confusing ways, which is why the build script exists.

## Build and packaging

SwiftPM with a single executable target, `platforms: [.macOS("26.0")]`, and `swiftSettings: [.swiftLanguageMode(.v5)]`. Keep `Info.plist` in a `Resources/` directory outside `Sources/`.

A shell script assembles the bundle: `swift build -c release`, then create `build/MeetingScribe.app/Contents/{MacOS,Resources}`, copy the binary and the plist, write `PkgInfo`, and codesign.

**Do not pass `--options runtime`.** The hardened runtime blocks microphone and audio input unless matching entitlements are embedded, which requires a real provisioning profile. For a locally built tool it only gets in the way.

Ad-hoc signing with `-` works, but macOS ties privacy grants to the code signature and an ad-hoc signature changes on every rebuild. Accept a real signing identity as an optional first argument to the script, and print the recovery commands when ad-hoc is used:

```
tccutil reset Microphone app.meetingscribe
tccutil reset SpeechRecognition app.meetingscribe
tccutil reset ScreenCapture app.meetingscribe
```

While iterating on compile errors use `swift build -c release` directly — same compile, far less noise. Only assemble the bundle once it builds clean.

## Known pitfalls

**Echo between microphone and speakers.** Without headphones the microphone hears the far side through the speakers, so remote speech is transcribed twice — once correctly as "Them", once mislabelled as "Me". Warn about it in the UI. The real fix is acoustic echo cancellation on the microphone stream using the tap as the reference signal, which is out of scope for v1.

**Silent failure looks like a quiet meeting.** An empty transcript is almost always the audio-capture permission or a format mismatch, and neither announces itself. Every failure path must log to a single OSLog subsystem, `app.meetingscribe`, naming the Core Audio step and its `OSStatus`, so that one command diagnoses it:

```
log stream --predicate 'subsystem == "app.meetingscribe"' --level debug
```

**This spec was written against documentation, not a compiler.** Expect a signature or two to need correcting on first build. The likeliest spots: `result.isFinal` on transcription results, `CATapDescription.name`, and whether `cancelAndFinishNow()` is throwing. Where a method may or may not throw, `try?` compiles either way at the cost of a warning — a reasonable trade while the API surface is unverified.

**Buffer lifetime.** A buffer handed to a render callback may be reused by the caller as soon as the callback returns. Copy before passing it across any thread or actor boundary.

## Out of scope, and where this goes next

v1 ships on Apple frameworks only. Nothing below is built now, but the order matters because it explains why v1 is shaped this way.

**1. Speaker diarization, first.** The gap felt in every single meeting. Apple provides no API for it — `SpeechDetector` is voice-activity detection, not speaker identity — so the microphone/system split in v1 is a deliberate workaround, not a design preference. A ggml speaker-embedding model over the system-audio stream, run after the meeting, is the real fix.

**2. Long-context summarization.** Map-reduce mushes threads that run across chunk boundaries. A 32k-context model would summarize a whole hour in one pass. On this machine, a 7B at Q4 runs roughly 20–25 tokens/sec and a 14B at Q4 roughly 11–13 — fine for an asynchronous pass nobody is watching. With 36 GB, memory is not the constraint; the \~150 GB/s memory bandwidth is. Pick model size by acceptable wait, not by what fits.

**3. Cross-meeting retrieval.** A local embedding index answering "what did we decide about this last month". Apple offers nothing here, embedding models cost a few hundred MB, and this is the step where a meetings tool becomes a personal agent. It is also the part no cloud product can offer without being handed the data — the durable advantage is the private corpus, not the inference speed.

### On custom kernels

The instinct is right; decode is the wrong target. At batch size 1, token generation is memory-bandwidth-bound — every weight is streamed for every token, so faster arithmetic buys nothing while the ALUs wait on memory. The levers that move decode are quantization, speculative decoding, and not running at all.

The workloads on this chip that are genuinely compute-bound, and so worth hand-optimizing:

- A Whisper-style audio encoder: dense convolution and attention over each 30-second window.
- Prefill over a long transcript, which is one large matrix multiply rather than a bandwidth problem.
- The diarization embedding pass: many short windows, all compute.

One structural constraint to keep in view: **ggml cannot target the Neural Engine.** llama.cpp is Metal and CPU; whisper.cpp can route its encoder through Core ML to the ANE but decodes on GPU or CPU. Any move off Apple's frameworks shifts work onto less power-efficient silicon, so each migration has to be justified by a capability Apple does not offer — never by expected speed.

Also deferred: echo cancellation, pause and resume mid-meeting, auto-start on meeting detection (observe `kAudioHardwarePropertyProcessIsRunning` on the Zoom, Teams and Meet process objects), and an explicit locale picker instead of following `Locale.current`.

## Acceptance criteria

v1 is done when all of these hold.

- [ ] `swift build -c release` completes clean on macOS 26+ with Xcode 26+
- [ ] The build script produces a launchable `.app`; the menu bar icon appears and no Dock icon does
- [ ] Starting a recording prompts for all three permissions, each grantable, and downloads the speech model once
- [ ] Playing a video with speech produces live `Them:` lines; speaking produces live `Me:` lines
- [ ] Volatile text appears greyed and is replaced in place by finalized text
- [ ] Stopping writes `transcript.md` and `notes.md` to the dated folder and reveals it in Finder
- [ ] With Apple Intelligence disabled, the transcript is still saved and `notes.md` explains why notes are absent
- [ ] A forced failure in one summarization chunk still produces notes from the rest, and never loses the transcript
- [ ] Idle with no meeting: zero periodic CPU wakeups and under 50 MB resident
- [ ] While recording: `powermetrics` shows Neural Engine activity and no sustained GPU power
- [ ] Silence gating measurably reduces buffers fed to the analyzer versus ungated, verified by logged counts
- [ ] Closing the popover stops the elapsed-time timer
- [ ] Every failure path logs a diagnosable reason to subsystem `app.meetingscribe`
