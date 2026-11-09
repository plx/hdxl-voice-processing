# A12 host pulse performance evidence

The [88-case workload matrix](../../Tools/Pulses/README.md#host-performance-matrix)
passed all six timing/allocation shards and five stage-probe shards on
2026-11-08 UTC. Measurements used Mac13,1 arm64, macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a), Swift 6.4 and Python 3.14.8, with release optimization.
The worktree was based on `e684b17e7ae4edf7965a5fe5bd48c712a5495d97` with the
performance implementation uncommitted. Every receipt retains the measured
source hashes; all were checked against the files before this report was written.
The timing receipt's sorted, compact JSON source-hash map has SHA-256
`242ca863ebb7ab4340d2e3796e2f1681ee5ba75c9c23cff20f86d40ad83d5614`.

These are bounded developer-host observations. Physical-device, thermal,
microphone and sustained-session evidence remains
[#74](https://github.com/plx/hdxl-voice-processing/issues/74).

## Complete analyzer and allocation observations

All inputs last 0.5 seconds. Each shard covers Float32 and Float64 input,
complete-interval and independently anchored block support. The latter receives
256-sample chunks and finishes only when its complete interval is available.
Arithmetic is Float64. Receipts include the entire profile, supplied F0 grid and
identity, PCM and fixture hashes, output denominators, capacity and prepared
storage. Setup excludes input loading, decoding and F0 identity construction.
Run includes reset, processing and consumption of all output arrays.
Matching spans one current F0 period and progresses by attempted cycles; it has
no fixed frame/hop. The supplied F0 grid and delivery chunks are separate inputs.

| Shard | Cases | Run p99 range, ms | Input seconds per wall second |
| --- | ---: | ---: | ---: |
| 16 kHz, 80/150/300/600 Hz | 16 | 0.353–2.017 | 247.9–1415.9 |
| 44.1 kHz, 80/150/300/600 Hz | 16 | 1.598–8.941 | 55.9–312.8 |
| 48 kHz, 80/150/300/600 Hz | 16 | 1.743–10.324 | 48.4–286.8 |
| Changing F0, jitter, noise, gaps and splices | 32 | 0.496–3.959 | 126.3–1007.5 |
| Licensed sustained vowel, 44.1 kHz | 4 | 5.205–5.929 | 84.3–96.1 |
| Owned snapshot, 48 kHz / 150 Hz | 4 | 5.224–7.265 | 68.8–95.7 |

Run has ten measured observations after one warmup; p99 is effectively the sample
maximum, not a stable population-tail estimate. Prepare has thirty observations
after three warmups. Raw histograms, counts and p99 exports are retained, along
with derived whole-operation throughput. Amortizing Run time by attempted match
count does not isolate matching/interpolation cost. The complete-block support
delay is separate from these processing times: its center delay is 0.25 seconds,
and early points may wait the full block.

All 252 prepared borrowed-run heap histograms (84 cases × malloc count, malloc
bytes and object count) have maximum zero. Every shard's capability control
observed two mallocs, 4,120 bytes, one object, two frees, two retains and three
releases. All four owned-output cases observed five mallocs for the five copied
arrays. ARC activity is retained; zero heap allocation does not mean zero ARC
traffic. Timing binaries exclude the allocator interposer, and allocation binaries
include the pinned interposer. The runners verify both linkage and lockfile identity.

Prepared worker/collector buffers occupy 1,507,168–1,850,208 bytes in this matrix,
with capacity for 4,096 attempted matches. Caller PCM, F0 storage and object
bookkeeping are reported separately. These are declared buffer sizes, not RSS or
physical peak-memory measurements.

## Matching and interpolation observations

The stage probe uses 42 distinct PCM/F0 inputs; support variants and owned-output
copies do not duplicate the same kernel case. Its native prepass retains all
5,170 attempted matches: 4,738 accepted and 432 rejected by the reference gates.
Native timing eligibility is a separate classification, with 4,698 eligible
attempts. Each replay result must equal the prepass before a receipt can pass.

Five paired disabled/detailed trials alternate ordering. Every detailed trial
measures every matching call, without the production 64-record prefix limit or
diagnostic suppression. This yields 25,850 matching and 25,850 interpolation
samples. Per-case distributions retain accepted/rejected and eligible/ineligible
groups separately, including empty groups. The sustained-vowel cases have no
reference-gate rejections, so their rejected-cost summaries are unavailable.

There are 1,356 measured interpolation samples of zero nanoseconds: the operation
can complete within one clock tick. These are distinct from null, which means a
stage was not entered or not measured. Matching/interpolation durations include
sink clock/lock overhead. Paired replay medians vary with host scheduling; no
constant overhead correction is inferred. Replay totals include diagnostic
framing and validation, and do not replace the full-analyzer measurements above.

## Retained raw-evidence identities

Timing/allocation hashes identify `raw-baseline.json.gz`; stage hashes identify
`trials.json`. Each fresh artifact directory also contains environment, input
receipts, validated distributions, command log and pass/fail result. CI uploads
these artifacts with a 14-day retention period; this table preserves the identity
of the initial local evidence without checking generated build artifacts into Git.

| Shard | Timing SHA-256 | Allocation SHA-256 | Stage SHA-256 |
| --- | --- | --- | --- |
| steady16000 | `c8fb3436950bd443f42906a41f076263df9c319f9cec7e02d3a38c2d58ef9cb3` | `2253ec4ac320e9bdce8c38d4d81a111c5d091a69813c26c942877aca2aa67114` | `12eb897fb70436384b1cedeeb8a1c6e1dbb0ecff80e58d670e667f69721a492e` |
| steady44100 | `0e044116325c23ab4668c5e4e755e89b70cec31f7d17dc972b2274efb60ed782` | `8b534f72f1e7e9daec46de14acea6ae83ada43847ca6444e3252c6dbe4d06f95` | `681e350ff7cf9a9398f04905b9fe0a903ad1d3741addc2d37cd1c9ea8e040207` |
| steady48000 | `b7a9a1b575bffb188cd0d17c34e8570e43248e73ab7b07f3345124f6e8e4303b` | `d99895ab67d8a8f7fac293ae376c76e71fe0c48bae834425042710b8a2115ede` | `95016f7e2d74069121d283b9f5dfe87be0ec0cc68d3123f327718785ec4744ab` |
| stress | `44d4728683d92ecaabebe433daffc6498eb194b66fee2014d6855ffed60ee767` | `737659b8a4ffb7fa1a93c66d4a0e626df096bd252b20c77254b8928dd79c9306` | `2655bc5d68b451f3763cb316a2886433553b2b5b0bb069149d64747feee9a326` |
| vowel | `424463f951f13b402677ef62a6c0a586de765ea72ea187c37ae775a02efd0fa8` | `db51fae3ac13872cc524b99bef47dc4dfce65aa8c0854776bd36f64a4543a786` | `b8bb42673099790ff57dc14c2791e463ccc217d6bc96b35e4a8bac8aa3155dcf` |
| export | `2404ecb6aa41d322706dee421d13a83e3244af06945145ff9d82236ceecbc7ab` | `48205ec940a48ca2008211aa8b79691a7f31f9137a03788910e2abe514992695` | Not applicable: repeated input |
