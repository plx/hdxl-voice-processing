# Session workflow

This separate SwiftPM package uses only public library APIs on macOS 27. Its
storage worker is also compiled into the iOS capture host. The same lifecycle
tests and canonical fixture probe run on macOS and iOS 27 Simulator.

## Store and share

Create private directories first; commands never implicitly replace an existing
destination. From the repository root:

```sh
mkdir -m 700 .build/session-example
swift run --package-path Examples/SessionWorkflow SessionWorkflow \
  create-synthetic .build/session-example/session.hvps --scratch .build/session-example
swift run --package-path Examples/SessionWorkflow SessionWorkflow \
  inspect .build/session-example/session.hvps
swift run --package-path Examples/SessionWorkflow SessionWorkflow \
  share-copy .build/session-example/session.hvps .build/session-example/share.hvps
swift run --package-path Examples/SessionWorkflow SessionWorkflow \
  delete .build/session-example/share.hvps
```

`create-synthetic` analyzes one second of generated PCM16 with the real RMS
scheduler. It retains the recipe, complete result/timing/coverage metadata and an
original-media reference. The default omits audio. Add `--include-audio` to embed
the original WAVE, and `--replace` to atomically replace the selected archive.
The temporary source is removed on success or error. This is demonstration data,
not a voice-quality or calibration validation claim.

`replay ARCHIVE --scratch DIRECTORY` explicitly reanalyzes the first plan under
its stored profile; omitted audio returns `missingMedia`. `share-copy` creates a
verified exact file copy for a user-selected destination. An archive permitting
audio requires its own `--include-audio` flag; that decision is checked against
the input being copied. No command uploads or contacts a service. `delete` removes
only the chosen local regular file and cannot recall previously shared copies.
Host paths must be trusted and access serialized. Failures print stable codes;
inspection prints only completion/policy/counts, never values, labels or paths.

The iOS host's **Session storage and sharing** screen uses this same worker off
the main actor. It saves one archive in private Application Support storage,
excluded from backups. Files import verifies a chosen archive before replacing
it; imports can contain audio. The screen shows embedded byte counts and targets
for inspection, never automatically activating them. An explicit preparation
button creates a private sharing copy; **Share prepared archive** opens the system
share sheet. Local sharing copies persist until the explicit delete action.
Microphone buffers are never passed to this feature. Sharing and storage use the
standard [ShareLink](https://developer.apple.com/documentation/swiftui/sharelink)
and [file importer](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:)) APIs.

The example host limits input to 64 MiB, records to 1 MiB, catalog metadata to
8 MiB, 100,000 records and 32 MiB embedded media; replay is capped at 60 seconds.
These are example policies, separate from the configurable library limits.

```sh
swift test --package-path Examples/SessionWorkflow
```

The two shared lifecycle tests verify audio-free/raw storage, real PCM replay
equality, exact sharing copies and opt-in enforcement, deletion, cancellation,
and corrupt import refusal preserving an existing session.

## Canonical fixtures

From the repository root, with an existing private scratch directory:

```sh
swift run --package-path Examples/SessionWorkflow SessionWorkflow \
  --fixture-probe \
  --fixtures Tests/HDXLVoiceProcessingTests/Fixtures/Sessions \
  --scratch /absolute/private/scratch \
  --output /absolute/path/session-fixture-report.json
python3 Tools/Capture/ios_host.py
```

The probe verifies committed fixture hashes and lengths, re-exports every complete
archive byte for byte, inspects scalar/status/clock/intermediate/gap meaning,
distinguishes a sealed partial acquisition from an interrupted container, and
replays the original PCM under the pinned profile. An omitted-audio counterpart
must refuse replay. Private extracted copies are removed after both paths.
The separate calibration fixture retains 64 labelled takes and two target
documents. Inspection checks splits, masks, analysis summaries and the exact CPPS
rule scale; an unsupported fitter remains display-only. Fabricated validation
claims are explicitly contract data and do not authorize activation.

The small fixed fixtures are allowed to use arrays/Data in the probe for exact
comparisons; this is not the general streaming-memory benchmark. All inputs and
reported counts are synthetic. No microphone, audio-session activation, personal
target activation, private recording, upload or external reference tool is used.
The iOS resources belong only to the test bundle; runtime package products acquire
no fixture resources or test dependencies.

See the [interchange guide](../../Documentation/SessionInterchange.md) for production
streaming/storage/sharing ownership, recovery, target activation and the distinction
between original and actual decoder provenance.

## Serialization timing and memory

```sh
python3 Tools/Sessions/benchmark.py --output .build/session-serialization-evidence
```

This separate release benchmark constructs scalar contracts without DSP or
capture. It measures serialization/storage plus record construction or semantic
validation in fresh processes for one-minute and two-hour synthetic timelines,
checks exact clocks/statuses and archive integrity, and compares process RSS with
reported payload/catalog/IO bounds. The script owns and deletes its generated
archives. See the interchange guide for scope, page-cache effects, limits and the
32 MiB median RSS growth smoke allowance; these are not microphone latency results.
