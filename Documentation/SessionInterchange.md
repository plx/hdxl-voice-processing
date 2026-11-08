# Analysis sessions and personal-target interchange

Issue [#58](https://github.com/plx/hdxl-voice-processing/issues/58) defines a versioned
local archive for results, calibration records and optional original media.
`HDXLVoiceProcessing` supplies streaming reader/writer APIs; the optional Audio
product supplies private file storage and verified PCM replay. Neither starts
capture, activates a target, logs personal values, nor uploads data.

The format uses canonical JSON for metadata and compact binary records for the
timeline and media. See the [version 1 wire specification](SessionArchiveFormat.md).
The suggested extension is `.hvps`; decoding uses the content, not the extension.

## Preserving measurement meaning

Register a complete `SessionArchiveProfile`, a `SessionArchiveSource` containing
its acquisition and continuity origins, and a `SessionArchiveSeries`. Each table
has its own zero-based indices. References must follow their definitions. A series
binds the full profile, source, measurement descriptor, placement clock and mask
provenance. Distinct metrics may share a timestamp; one series must advance strictly.

For scheduler results, call `writer.append(export, to: seriesIndex)` with
`ScheduledFrame.export(metric)`. This preserves the native result, source timing,
dependency timing/coverage, complete mask provenance, placement and worker batching
bound. Coverage tags can overlap. Acquired dependency samples need not equal a
kernel's included count, especially during K-weighted warmup or causal history.
Exporting only `measurementResult(metric)` loses that additional context.

For native kernel results, construct `SessionArchiveMeasurement` with an explicit
placement timestamp. Integer source coordinates remain exact above 2^53; optional
host nanosecond clocks remain UInt64. Relative seconds and dependency intervals
have separate roles. Availability, unavailable reasons, confidence, warnings,
units and optional bounded intermediate snapshots all survive persistence.

`SessionArchiveGap` retains old/new source indices, observed and dispatched input,
discarded pending work, reset reason and an optional known missing interval. An
unknown loss extent stays unknown. A boundary closes the old source to subsequent
measurements; it does not insert zero-valued samples or join separated regions.
Device/route/settings descriptions are explicit host reports, not proof of
equivalent acquisition conditions.

## Streaming and bounds

`SessionArchiveWriter` accepts a throwing `Data` sink; `SessionArchiveReader`
accepts a source that returns at most the requested byte count, with empty data
meaning final EOF. These are synchronous, single-owner worker/control-path objects,
not capture-callback or UI operations. Calls and callbacks must not reenter an
operation. A growing file/network source needs a host adapter that distinguishes
temporary starvation from EOF.

Supply `SessionArchiveLimits` from trusted host policy. Defaults are 4 GiB total
archive, 16 MiB per record, 16 MiB total encoded catalog, 4096 catalog entries,
10 million records, 256 MiB embedded original media, 65,536 intermediate scalars
per measurement and 64 KiB IO chunks. Hosts can lower these independently; a
smaller total archive ceiling also requires smaller catalog/record/media ceilings.
Hard maxima are validated by the initializer. Calibration records have additional
native limits, including 128 KiB per imported target document.

The catalog retains bounded metadata and last timestamps, never timeline history.
One framed record is buffered for checksum/semantic validation. Media chunks have
a separate 64 KiB maximum regardless of the requested IO chunk size. An importer
with 256-byte reads can therefore read a valid archive exported with larger chunks.
`SessionArchiveIOStatistics` reports byte/count limits and owned payload high-water
marks. These are not process RSS: Foundation, hashing, decoded objects, allocator
overhead and system decoders have additional storage. Host callbacks must also
avoid accumulating an unbounded array of events.

Validation failures before output are recoverable on a writer. Sink failures are
terminal because a partial frame may already exist. Reader failures are terminal.
Do not continue writing to the same destination after a terminal IO failure.

## Completion and recovery

Call `finish(.completed)`, `.partial`, or `.cancelled` exactly once. All three
produce complete containers with a seal and explicit acquisition status. Every
declared embedded media reference must be complete even in a partial session.

The reader verifies per-record hashes, semantics, aggregate prefix hash and counts,
then requires EOF after the seal. Earlier events are provisional. A SHA-256 match
detects corruption and binds identity; it does not authenticate a recording,
personal label, numerical claim or target's usefulness.

Strict import rejects an unsealed EOF. Explicit `.inspectCompletePrefix` recovery
returns only complete, already verified records preceding truncation, followed by
`.incomplete`; `reader.seal` remains nil. It does not recover corruption, unknown
records, incompatible schemas, limit violations or trailing garbage after a seal.
Such recovered data cannot activate a target or enter the verified-media replay API.

## Calibration inspection and activation

Dataset, split, analysis and target records preserve labels, whole-recording/session
assignments, profiles, fitted rules/policies, coverage, provenance and validation
claims. Cross-references must match the exact preceding dataset revision and split.
`SessionArchiveTarget` is an inspection document. Imported analysis values and
validation claims remain claims even when every structural/hash check succeeds.

`target.compatibility(with: currentProfile)` distinguishes an exact recipe requiring
verified evaluation from a different profile or unsupported fitting/analysis
implementation. A matching profile alone is insufficient for activation.

`reader.activateTarget(at:currentProfile:verifiedEvaluation:)` requires a completely
read `.completed` container, the current exact recipe/implementations, and a separate
passing `PersonalTargetEvaluation` built from freshly verified inputs and reference
artifacts. Its activated candidate and evaluation identity must match the imported
document. The method returns that evaluation's existing activated model; it never
constructs an activated target from serialized data. Partial, cancelled and recovered
archives remain inspectable but cannot activate targets through this boundary.
Native activation/evaluation/validation types have no permissive import decoder.

## Original audio and replay

The default header policy is `.omit`. An audio-free archive can preserve media
references with `.omitted` inclusion, hashes, format and provenance without bytes.
`.explicitlyInclude` is permission to embed original media, not a claim that every
reference has bytes. Embedded references declare full-file digest/length, decoder
receipt and exact source-to-file-frame mappings. Chunks must be contiguous per
reference; all declared lengths and digests must pass before the final seal.

Reader default `.verifyOnly` verifies embedded audio but does not expose its bytes.
`.deliverBytes` is explicit and delivers provisional chunks. The file API's
`withVerifiedMedia` extracts only the selected reference into a private temporary
file, verifies the whole archive, then calls the body. The URL is valid only for
that call. Normal return, error and cancellation remove the copy. The caller must
not mutate or retain it. Missing/omitted audio produces `missingMedia`.

`SessionArchiveReplayPlan` binds one scheduled series to one source/file mapping,
plus the full original mask plan if present. The mapping starts at that series'
continuity origin and lies within one acquired/selected region. A mask fingerprint
alone cannot reconstruct selection. Separated regions require separate origins and
plans; replay never concatenates across a gap or trims away required causal history.

`SessionArchiveAudioReplay.run` discovers the selected reference in one bounded
pass and verifies/extracts it in a second pass. All executable inputs come from the
verified second pass. It checks actual container fields, file frame count, requested
PCM format and decoder identifier before preparing numerical processors. It then
uses the exact stored schedule, source clocks, mapping and mask with Float32 or
Float64 as declared. Decoder runtime may differ across devices; the result retains
both original and actual receipts. Identical metadata does not guarantee bitwise
codec behavior across every OS/device, and replay does not reinterpret an old scale.

Replay emits only the chosen metric's complete `ScheduledMeasurementExport`, with
no retained result history. Its separate limits bound decoded source samples/time
and worker chunks/tiles; native whole-interval layout limits still apply. Defaults
allow 172.8 million source frames and 3600 seconds, with 2048-frame decoder chunks
and 256-frame source tiles. These are engineering ceilings, not measured physical
device budgets. The batching bound reflects the chosen replay tile capacity.

For calibration, a host may use `withVerifiedMedia` and `CalibrationFileAnalysis.run`
with the exact imported take, retaining its full profile, labels and selected source.
That analyzer independently verifies a private media snapshot and produces a new
analysis receipt. Preserve changed runtime/analysis identities and re-fit/evaluate
when needed; importing an old numerical summary is not fresh validation.

## Local files, deletion and sharing

`SessionArchiveFiles.write` accepts a host-chosen destination and populate closure.
It creates a private 0700 sibling staging directory with a 0600 file, appends the
records, seals, flushes/closes, checks cancellation and atomically renames into place.
The closure must not call `finish`; the wrapper owns the final completion status.
`.create` refuses an existing destination atomically. `.replace` accepts a regular
file or absence. Any failure before successful rename preserves the old destination.
No throwing operation follows that commit; cancellation after commit does not
retroactively undo a successful publication.

The same-filesystem rename supplies atomic visibility. This is not a universal
power-loss durability promise for directory entries or storage hardware. Apple's
[rename manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/rename.2.html)
describes the underlying namespace operation; the implementation uses `renameatx_np`
with `RENAME_EXCL` for create-only publication.

Inputs must be regular local files; final-component symlinks, pipes and directories
are refused. Directory operations use open directory descriptors. The host supplies
trusted parent paths, owns ancestor-directory policy and serializes concurrent
export, deletion and sharing. This is not an adversarial same-user filesystem sandbox.

`SessionArchiveFiles.delete(at:)` removes an explicitly chosen regular archive.
It never recursively deletes directories or follows a symlink target. After a crash,
the host may inspect an abandoned `.hdxl-session-<UUID>/archive.part` with explicit
prefix recovery, then call `removeAbandonedStage(at:)` once no operation owns it.
Cleanup only accepts package stage names and known regular files, not arbitrary
recursive content. Unlinking is deletion, not a promise of secure erasure from SSDs,
backups, snapshots or cloud-synced directories.

Keep personal archives in host-controlled private storage. Only a user action
should select a share destination or invoke the system share sheet. State whether
the chosen archive includes audio. `SessionArchiveFiles.copyVerified` creates an
exact copy, including any embedded audio, through private staging and full-container
verification before atomic publication. It preserves the original bytes and refuses
corrupt/truncated input; it does not silently strip media or change completion status.
The default `audioPolicy: .omit` refuses a header that permits audio. A host must
explicitly pass `.explicitlyInclude` when the chosen operation permits embedded
audio. This policy is checked on the same pinned input descriptor used for copying;
a separate earlier inspection is not used as authorization.
Sharing does not require a backend; ordinary
file export or a system file representation suffices. An exported copy has its own
retention lifecycle and cannot be recalled by deleting the application's original.

## Compatibility and diagnostics

Version 1 has no automatic migration. Unknown wire/schema versions, record kinds,
unknown fields, noncanonical metadata, invalid/nonfinite numbers, incompatible
units/profiles and unsupported recipe forms are refused. A future migration must
be explicit, preserve original identities, and produce a new archive with documented
conversion provenance and fresh target evaluation. Never relabel older CPPS values
with a current threshold/profile or turn unavailable values into numeric zeros.

Public boundaries expose stable `SessionArchiveError` codes without private paths,
decoder messages, scalar values or audio. Hosts may display those codes and safe
operation/count metadata; do not forward arbitrary underlying errors to unified
logs. Archive text, UUIDs, route information, calibration labels and targets can all
be personal data even when no audio is embedded. CI evidence must use named synthetic
inputs and exclude host archives, extracted media and arbitrary user paths.

## Canonical interchange checks

`Tests/HDXLVoiceProcessingTests/Fixtures/Sessions` contains five original archives
generated independently with Python JSON, explicit binary packing and SHA-256.
They cover scalar clocks/statuses/intermediates/gaps, sealed partial sessions,
truncated containers, embedded PCM with an exact known RMS, and explicit omission.
Their manifest and the repository provenance inventory pin the exact bytes.
Native Swift tests check meaning and complete byte-for-byte re-export; Python
controls independently check frame/seal corruption and the integer PCM container.

A separate public Swift API generator produces a calibration archive with 64
labelled takes, masks/exclusions, splits, fabricated analysis/validation contract
data and two inspection-only targets. Its own manifest pins the input reference
and exported identities. The probe checks the current and unsupported fitter
versions, exact CPPS scale, and retained labels/rules without activation. Native
tests additionally refuse an unrelated passing evaluation and unknown CPPS scale.
These explicitly fabricated claims are software contract inputs, not DSP or
perceptual validation evidence.

The [public fixture probe](../Examples/SessionWorkflow/README.md) runs on macOS and
from the iOS host's test bundle on an isolated iOS 27 Simulator. The iOS evidence
driver requires that exact named test to execute successfully; the package's two
ordinary iOS correctness lanes remain compile/link checks. Simulator interchange
evidence does not establish physical microphone, performance or voice-quality claims.

## Long-session serialization evidence

`python3 Tools/Sessions/benchmark.py --output NEW_DIRECTORY` builds the public
macOS example in release mode and measures five short/long trials in separate
processes for export and import. The fixed scalar recipe represents 6,000 and
720,000 results at 100 Hz, including unavailable statuses and exact source clocks
above 2^54. No DSP, capture, target fitting or media decoding runs. Write timing
includes constructing each scalar contract, encoding, hashing, file IO and final
publication; read timing includes decoding, hash/semantic checks and file IO.
Profile preparation and JSON report writing are outside the timed interval.
Filesystem reads may benefit from the preceding write's page cache.

Each process retains one record and a fixed four-entry catalog. An independent
Python streaming audit verifies the resulting framing and seal. RSS is Darwin's
whole-process high-water value, including runtime and allocator overhead, and is
reported separately from owned payload/chunk/catalog byte statistics. The 32 MiB
short-to-long median growth allowance is a host smoke gate, not a universal memory
bound. This case tests long scalar timelines with a small catalog; configured
catalog, individual record and media-decoder limits need their separate tests.
The evidence driver rejects incomplete or inconsistent reports and exercises ten
negative validation controls. Generated archives are deleted; CI retains only
synthetic timing/count/identity reports and redacted logs.
