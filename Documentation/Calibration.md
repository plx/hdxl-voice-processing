# Calibration records, listening labels, and file analysis

The Core product holds a versioned personal dataset, a blinded labeling workflow,
whole-recording/session split plans, explicit comparability findings, and numerical
cache records. The Audio product verifies and analyzes referenced files through the
same Levels/YIN/CPPS scheduler used by other sources. Neither product fits a target
or assigns a voice-quality score in this stage; target fitting is roadmap #53.

## Collection and labeling

`CalibrationDataset` contains immutable sessions and takes. A take keeps its task,
prompt/language metadata, repetition, production instruction, actual listening
label, confidence/notes, source interval, exclusions, acquisition conditions, and
full `AnalysisScheduleProfile` plus a checked fingerprint. The four task categories
are sustained vowel, mostly voiced sentence, repeated ordinary passage and novel
passage. Their names do not imply a measured voiced fraction or require a language.

Media references contain an opaque host identifier, complete file-byte SHA-256 and
length, and original recording UUID. They contain no path, embedded audio or network
location. The host resolves a reference for playback or file analysis. Excerpts and
transforms retain their original acquisition UUID even when file hashes differ.
Source coordinates refer to the referenced file, so a cropped file has its own local
sample positions. A hash does not establish recording ownership or consent.

Create `CalibrationLabelingSession(dataset:shuffleSeed:)` before displaying results.
Give its `items` to the presenter: each contains only a replay token and ordinal.
A separate controller uses `replayMedia(for:)` to play the clip without revealing its
filename, instructions or old labels. Submit an actual preference (`usual`,
`preferred`, `other`, or `uncertain`), or explicitly exclude unusable/missing media.
An intended preferred take can receive any listening label. Submissions can change
until every take has a disposition and `complete()` publishes a new dataset revision.
The original dataset remains unchanged, and the completed transaction rejects edits.

This supports an honest host workflow. It cannot prevent a host or listener from
seeing information elsewhere. Imported labels declare `blindedBeforeFeatures`,
`unblindedBeforeFeatures`, `afterFeatures`, or `unknown` exposure. Scripted example
labels demonstrate the API; they are not evidence that a human listened.

## Evaluation and comparability

`CalibrationSplitPlan` binds the complete dataset fingerprint, supplied seed,
explicit held-out sessions and within-session recording-evaluation fraction.
Connected takes sharing an original acquisition UUID **or identical content hash**
stay together, including transitive aliases. A group crossing held-out and fitting
session boundaries is rejected. No overlapping frames are assigned independently.
Use `partition(dataset:)` or `decode(_:for:)` to validate binding before consuming
assignments. Changing labels, conditions, membership, profiles or revision requires
a newly validated plan. A nonempty split is not proof of adequate statistical power.

`CalibrationTakeAssessment` reports missing/uncertain labels, label exposure,
excluded/empty/insufficient coverage, absent/incompatible analysis, and too few
available metric observations. Its policy specifies the minimum selected samples,
fraction and available-frame count. Defaults check basic nonempty availability;
they are not validated calibration thresholds.

Route, room, distance, gain and recording settings compare exactly when both are
known; unknown values are explicitly reported even when both are absent. An empty
settings dictionary means no extra settings were reported; nil means unknown.
Task/profile differences remain separate findings. A novel task or changed room may
be intentional evaluation, but must not silently be pooled with matching fitting
conditions. Distance, room, route, gain and settings are host declarations, not
measurements independently verified by the library.

## Bounded file analysis and cache reuse

Call `CalibrationFileAnalysis.run` on a serialized background worker with the take,
resolved local URL, `CalibrationFileLimits`, and an explicit private scratch directory.
The adapter opens only regular files (symbolic links are rejected), copies bounded
chunks into a newly created private directory/file, and hashes exactly those bytes.
Both length and SHA-256 must match the reference. It then decodes the verified copy,
so edits/replacement of the original cannot alter an in-progress numerical result.
The original may change after the snapshot; a later invocation must verify again.

Temporary directories have mode 0700 and files 0600. Normal success, cancellation
and failure remove the snapshot. A process crash can leave one behind; hosts should
clean abandoned `calibration-*` directories in their own scratch location on startup.
This is transient disk use explicitly requested by analysis, not automatic audio
embedding in a dataset, logging, or permanent audio storage.

The decoder checks actual sample rate, channel count, layout and file interval.
No resampling, channel conversion, amplitude normalization or detector is silently
added: numerical behavior comes from the full executable schedule profile.
Explicit calibration exclusions intersect the upstream selected mask while preserving
independent tags. Missing acquisition is skipped, never replaced by zero-valued PCM.

A numerical cache key contains the file hash/length, full profile fingerprint, exact
source interval/epoch, effective mask identity, decoder storage/PCM format, decoder
and OS identity, and versioned calibration implementation. The adapter snapshots and
checks the current file and decoder **even on a cache hit**. A matching valid record
returns without decoding PCM; mismatching metadata causes fresh analysis. Relabeling
or changing host conditions can reuse unchanged numerics, but later fitting must bind
the whole revised dataset. Cached scalar values are trusted host data, not signed
attestations. Import validation cannot prove that an untrusted author computed them.

`CalibrationFileAnalysisBatch.run` processes canonical session/take order, one file
and worker at a time, and delivers each outcome without retaining a batch history.
Excluded takes are reported without resolving their files. Missing/corrupt media,
wrong hashes/lengths, format/range failures, capacity failures, and cancellation have
typed outcomes without private paths. One failed or cancelled input does not poison
later inputs; `cancelBatch` cancels the remainder. A partial analysis never becomes
a cache record. Optional raw-frame callbacks run only during fresh analysis, so a
caller needing all frames must omit a cached record.

## Summaries and resource limits

Each enabled recipe produces raw RMS, dBFS, raw F0, optional tracked F0, CPP and CPPS
summaries as applicable. Available scalar estimates receive equal frame weight;
unavailable reasons and warning counts remain separate. Minimum, quartiles, median
and maximum use the inverse empirical CDF: rank `ceil(p*n)`, with a lower median for
even counts. There is no interpolation, imputation, gain normalization or confidence
weighting. These summaries do not replace the separately defined CPPS interval mean.
Frame counts do not denote independent observations. Coverage counts unique source
samples independently of overlapping windows; evidence tags can overlap.

| Resource | Version-1 bound |
| --- | --- |
| Dataset JSON via `decode` | 16 MiB before JSON decoding |
| Sessions / total takes | 32 / 512 |
| Per-take explicit exclusions | 64 |
| Upstream mask | 256 observations, 8 provenance sources, 64 KiB encoded |
| General text / host settings | 4096 UTF-8 bytes per text; 32 settings and 16 KiB encoded |
| Complete file snapshot | 256 MiB; 64 KiB read/write chunks; one file at a time |
| Declared source interval, before exclusions | At most 2,880,000 frames **and** 120 seconds |
| Decoder PCM chunk | Default 2048 frames; caller range 1...65,536 |
| Observations per metric | 30,000 including unavailable frames; at most 6 metrics |
| Available scalar element storage | At most 1,440,000 bytes; sorting adds at most 240,000 bytes |
| Imported numerical cache JSON | 128 KiB |

Callers can lower file-analysis limits. Hitting a limit fails explicitly; frames are
not silently dropped or sampled. Source extent is bounded separately from compressed
file size. Whole-interval regions also undergo native geometry preflight. Existing
profile bounds govern numerical scratch; AVFAudio codec buffers, FFT objects,
Foundation allocations and allocator overhead are outside scalar-buffer accounting.
These limits do not claim a hard resident-memory ceiling or capture-safe allocation.
Execution records report actual chunk counts, retained scalars and sampled prepared
buffer sizes. The example additionally records macOS process peak resident memory.

Use the bounded `decode(Data)` entry points for external input. Generic `Codable`
initialization validates fields but cannot inspect a caller's full input byte size.
The caller must also bound reading a JSON file before allocating its `Data` buffer.

## Reproducible example

The independent [CalibrationWorkflow example](../Examples/CalibrationWorkflow/README.md)
uses 16 original generated PCM files, all four task categories, contradictory and
uncertain labels, one explicit exclusion, a within-session recording holdout and a
separate novel-task session. It publishes the same dataset/split/cache contracts used
by library clients and compares raw summaries per take, with no fitted target.
The [evidence record](Evidence/calibration.md) reports local numerical checks,
repeated import/analysis measurements and their limits.

## Method context

Task and production differences motivate retaining actual labels and prompt context;
this is an engineering inference, not a universal preferred direction for CPP.
[Toles and Murton, 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC13252592/).
Intensity effects motivate preserving raw level/pitch context: file amplitude
normalization does not establish controlled vocal effort.
[Brockmann-Bauser et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC7295673/).
Task, voicing selection and algorithm conventions motivate exact profile and coverage
provenance; clinical cutoffs are not personal-preference targets.
[Murton, Hillman and Mehta](https://pmc.ncbi.nlm.nih.gov/articles/PMC7893528/).

Policy review is tracked in [#125](https://github.com/plx/hdxl-voice-processing/issues/125).
Physical-device measurements remain deferred under [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
