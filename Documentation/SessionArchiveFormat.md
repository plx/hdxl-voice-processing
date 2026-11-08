# Session archive wire format, version 1.0

This is the format implemented by `SessionArchiveReader` and `SessionArchiveWriter`.
The [interchange guide](SessionInterchange.md) describes host ownership, trust,
activation and replay. All multibyte binary integers are unsigned little-endian.
Binary real numbers are IEEE-754 binary64 in little-endian order. They must be
finite; writers normalize negative zero and readers reject its binary encoding.
Integer source positions/counts must also fit nonnegative Int64. There is no padding.

## Envelope

The 16-byte file prefix is hexadecimal:

```text
48 44 58 4c 56 4f 49 43 45 00 01 00 00 00 00 00
```

That is `HDXLVOICE`, NUL, UInt16 major=1, UInt16 minor=0, UInt16 reserved=0.
Every record begins with this 48-byte header, followed by exactly payloadLength bytes:

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 0 | 1 | Record kind |
| 1 | 3 | Reserved, all zero |
| 4 | 4 | Payload length, UInt32 |
| 8 | 8 | Ordinal, UInt64, starts at zero and increments by one |
| 16 | 32 | Raw SHA-256 of header bytes 0–15 followed by the payload |

Limits are checked before allocating a declared payload. Unknown kinds/reserved
bits/versions, invalid ordinals, checksum failures and surplus payload bytes fail.
The first record is exactly one header record. The last is exactly one footer,
followed immediately by EOF. There is no ZIP/compression layer or encryption.

| Kind | Payload | Retained catalog entry |
| --- | --- | --- |
| 1 | `SessionArchiveHeader` JSON | Yes |
| 2 | `SessionArchiveProfile` JSON | Yes |
| 3 | `SessionArchiveSource` JSON | Yes |
| 4 | `SessionArchiveSeries` JSON | Yes |
| 5 | Scalar binary payload below | No |
| 6 | `SessionArchiveGap` JSON | No |
| 7 | `CalibrationDataset` JSON | Yes |
| 8 | `SessionArchiveCalibrationSplit` JSON | Yes |
| 9 | `SessionArchiveCalibrationAnalysis` JSON | Yes |
| 10 | `SessionArchiveTarget` JSON | Yes |
| 11 | `SessionArchiveMediaReference` JSON | Yes |
| 12 | Media binary payload below | No |
| 13 | `SessionArchiveReplayPlan` JSON | Yes |
| 255 | `SessionArchiveSeal` JSON | No |

Metadata indices are dense zero-based append order *within each kind*, independent
of the frame ordinal. Header counts as one global catalog entry but has no reference
index. Each retained metadata payload charges its encoded byte count to the global
catalog budget. Profile/source/series/media/dataset/split references must already
exist; forward references are forbidden. Record order otherwise permits interleaved
timeline and media output. Only bounded catalog/state is retained.

## Canonical JSON records

UTF-8 metadata uses the package's `canonicalContractJSON`: Foundation sorted keys,
unescaped slashes, strict typed values and contract-defined NFC text normalization.
There is no trailing LF. It is not a claim of RFC 8785 compliance. Decoding and
re-encoding must reproduce the exact payload bytes; duplicate/unknown keys,
whitespace variations and normalized-away representations are refused. Null versus
omitted fields follow each typed schema; explicit null is required for series mask,
replay-plan mask and gap missingSource. Schema changes require a deliberate version.

`SessionArchiveHeader` fields are `format` (`hdxl-voice-session`), `schemaVersion`
(1), `id`, `producer`, optional `createdAtUnixSeconds`, `audioPolicy` (`omit` or
`explicitlyInclude`), and `notes`. The native Codable schemas of the named types
define their complete JSON fields. Profile records use `kind` and `recipe`; kinds
are `analysis`, `schedule`, `levels`, `yin`, `trackedYIN`, `cpp`, `cpps`. Every recipe
retains its full parameter and reference semantics, not just a display identifier.

Sources retain `AnalysisScheduleOrigin` and explicit `SessionAcquisitionMetadata`.
Series fields are `profileIndex`, `sourceIndex`, `measurement`, `clock`, `isScheduled`
and `mask`. A scheduled series uses `secondsFromOrigin`; a native series may instead
use `sourceSamples`. Full population tuples are unique even if a duplicate changes
clock. A standalone CPP frame recipe cannot establish an original PCM source rate;
the source retains it without pretending the cepstral analysis rate is that rate.

Gap fields retain previous/next source indices, observed source, dispatched samples,
discarded pending samples, nullable missing source and reset reason. The discarded
count equals observed minus dispatched. Known missing input immediately follows
observed input. Boundaries follow the native discontinuity/origin contracts.

Calibration split and analysis records explicitly reference their dataset index.
Targets retain the complete candidate, fitting policy/rule, distributions, scope,
source/reference identities, claimed validation receipt and optional claimed
evaluation identity. These are inspection documents, never serialized authority
to activate a target. See the activation rules in the interchange guide.

## Scalar payload

Fields appear in exactly this order:

1. UInt32 series index.
2. Placement: UInt64 source sample or Double seconds from origin, according to the
   series clock. Scheduled placement is the original frame center.
3. Native timing block (below).
4. Outcome (below).
5. For a scheduled series only: dependency timing block, coverage block and Double
   worker batching upper-bound seconds.
6. UInt32 intermediate-policy scalar budget, then UInt32 snapshot count.
7. That many intermediate snapshot blocks (below).

Epoch, sample rate, profile identity, measurement descriptor, continuity origin and
mask provenance come from validated catalog references. They are not repeated in
every scalar. Timing support may overlap previous records; placement must advance
strictly within a series. Values are not globally deduplicated across different metrics.

A timing block contains UInt64 source start, UInt64 source count, UInt64 included
sample count, Double effective delay, then one flag byte. Bit 0 adds Double source
start seconds; bit 1 adds UInt64 host-start nanoseconds; bit 2 adds UInt64 completed
host nanoseconds. Present optional fields follow in bit order; other bits are invalid.

Outcome byte 0 means available: Double value, one confidence-present byte (0 or 1),
optional Double confidence, then one warning-bit byte. Outcome byte 1 means
unavailable: one reason-code byte, with no value/confidence/warnings. Warning bits
0–3 mean clipping, lowConfidence, partialCoverage and exploratoryApplicability.
Other bits are invalid. Reason codes are:

| Code | Reason | Code | Reason |
| --- | --- | --- | --- |
| 0 | insufficientData | 7 | discontinuity |
| 1 | silence | 8 | analysisFailure |
| 2 | clipping | 9 | cancelled |
| 3 | unsupportedRange | 10 | missingAcquisition |
| 4 | inapplicableTask | 11 | excluded |
| 5 | lowConfidence | 12 | stale |
| 6 | invalidInput | | |

Coverage is thirteen UInt64 values: source, eligible, selected, then tag counts in
this fixed order: missingAcquisition, silence, suspectedExternalNoise, clipping,
speechDetected, nonSpeechDetected, lowPeriodicityConfidence, algorithmInsufficiency,
energyEligible, energyIneligible. Tags overlap; do not sum them as disjoint populations.
Selected <= eligible <= source; missingAcquisition equals source minus eligible.

Each intermediate snapshot contains UInt16 stage-name UTF-8 byte length, name bytes,
UInt32 stage version, UInt64 source start, UInt64 source count, UInt8 x-unit,
UInt8 y-unit, Double x-origin, Double x-step, UInt32 value count, then that many
Doubles. Its epoch/rate derive from the source. The shared declared scalar budget,
host scalar ceiling and remaining payload bytes are checked before value allocation.
Unit codes are fixed:

| Code | Unit | Code | Unit |
| --- | --- | --- | --- |
| 0 | hertz | 9 | decibelsRatio |
| 1 | seconds | 10 | decibelsFullScale |
| 2 | samples | 11 | decibelsSPL |
| 3 | normalizedAmplitude | 12 | decibelsPerOctave |
| 4 | normalizedSquaredAmplitude | 13 | decibelsPerHertz |
| 5 | normalizedAmplitudeSeconds | 14 | fraction |
| 6 | normalizedSquaredAmplitudeSecondsSquared | 15 | percent |
| 7 | inverseSeconds | 16 | dimensionless |
| 8 | inverseSecondsSquared | | |

## Media and replay records

A media reference contains original `CalibrationMediaReference` (opaque identifier,
recording ID, SHA-256 and full-file byte count), `CalibrationDecoderProvenance`,
inclusion (`omitted` or `embedded`), versioned provenance, source/file mappings and
notes. A mapping contains source index, exact `SourceInterval`, and file start frame.
Mappings are sorted by source index/start, nonoverlapping per source and within the
declared decoder frame count. At most 4096 mappings belong to one reference.

The media chunk payload is UInt32 reference index, UInt64 byte offset, then 1–65,536
original bytes. The total payload must also fit the host record ceiling. Offsets
start at zero and are contiguous per reference; references may be interleaved.
The final chunk must match the declared full-file digest. No empty, surplus,
duplicate, post-completion or omitted-reference chunks are accepted. Declared
embedded bytes across all references are bounded before output is accepted.

A replay plan contains series index, media-reference index, mapping index and
nullable full `MaskPlan` (at most 4096 observations). It requires a scheduled series
with a complete schedule recipe and exact decoded PCM agreement. Its mapping starts
at the series' continuity origin and must stay inside one prepared-mask region.
An archived gap also bounds the mapping by the old source's observed end, whether
the gap precedes or follows the plan. Acquired but undispatched pending samples
remain inside that bound; missing samples never do. Replay metadata for the next
source may precede its incoming gap because it does not publish measurements.
The full mask's identity/provenance must equal that retained by the series. There
is at most one plan per series. Omitted audio can still retain a valid plan.

## Footer and refusal policy

The footer fields are `completion`, `precedingRecordCount`, `precedingByteCount`,
`precedingSHA256`, `measurementCount`, `gapCount`, `catalogEntryCount`,
`mediaReferenceCount`, and `embeddedMediaBytes`. Prefix counts/hash include the
16-byte magic and every complete preceding frame, excluding the footer itself.
`precedingRecordCount` equals the footer ordinal. SHA-256 is represented by the
native `CalibrationDigest` JSON object containing lowercase hexadecimal `sha256`.
All counters are checked against reader state, and every embedded medium must be
complete. EOF must follow the footer without a single trailing byte.

Version 1.0 readers refuse all other wire versions and unknown fields/records.
There is no implicit forward compatibility, lossy fallback or automatic migration.
A known target document can be displayed while its implementation is unsuitable
for activation; an unknown schema/rule meaning cannot. Any future migration must
preserve original provenance and explicitly revalidate threshold/scale compatibility.
