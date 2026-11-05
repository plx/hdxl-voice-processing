# A05 power-cepstrum evidence

Implementation based on main `92e4eeea1f982580283aaa7ecbd86df45b48dc4c`, measured
2026-11-05 UTC on the development Mac13,1 (arm64), macOS 27.0.1, Xcode 27.0
(27A266a), Swift 6.4 and Python 3.14.8. This is numerical and host evidence.
Physical-device/capture/thermal measurements remain #74. Numerical choices and
limitations are recorded in #104 and #105; actual CPP consumption belongs to #35.

## Independent references

The pinned external Praat 7.0.02 executable produces 41 cases, 197 selected frames
and all bins at every stage. Eight cases are licensed speech, including low-periodicity
material and noisy/dropout variants. The remainder cover original synthetic signals,
floors, gains, equivalent source rates and floating-point frame-grid boundaries.
The reference fixture family comprises 41 case files plus its manifest; all are
registered in the 152-fixture provenance manifest with speech-specific attribution.

Generator SHA-256: `8353a2bd78034bab107380437dc6ee6acf46c763e64235c5fd05c78038f369a0`.
The [tooling note](../../Tools/Cepstrum/README.md) records tool identity, exact routes
and frozen conditioning-aware budgets. Generation does not use native output.

Independent full-Praat and decomposed-Praat routes agree with no availability
disagreements; their largest power-cepstral discrepancy consumes approximately
3.3e-6 of the predeclared `1e-5 + 2e-5*abs(reference)` route budget. Sixty selected
frames have at least 32 natural-log units of spectral power range and are explicitly
classified as deep-minimum cases. The verifier preserves 7,182 undefined cepstral
bins from numerical singularities instead of substituting zero-valued results.

The native stage comparison checks 2,898 rows across isolated-frame and whole-input
routes, Double source cases and explicit Float-rounded source cases. It passed with
zero availability disagreements. Maximum consumed budget fraction was **0.521791**.
Whole-input maximum absolute log error was 0.0104358, signed-cepstral error 0.250650,
and squared-cepstral error 196,604 (the large value occurs against zero-quefrency
power of order 1e11). Squared error is checked using propagation from the signed
budget, rather than an unrelated fixed power threshold. Ordinary licensed speech
was substantially tighter: maximum log error 4.19e-9, signed error 2.82e-7, and
power error 0.0795. These are observations on this matrix, not universal guarantees.

Fused frame-center arithmetic and fused raw pre-emphasis are necessary for the
pinned route. A regression at frame 19 explicitly distinguishes nearest index 380
from 379. Float arithmetic experiments produced large deep-null log/cepstral errors
and availability changes; both source precisions therefore use Double arithmetic.
The source precision remains in identity and explicit conversion costs are measured.

Additional tests compare every stage against an independent small cosine-sum DFT,
check harmonic/missing-fundamental period peaks and gain behavior, reject invalid
bandwidth and PCM, preserve finite prefixes and zero-Nyquist unavailability, and
exercise strict decoding and bounded retention. Chunk changes preserve output;
gaps/reset cannot stitch separated PCM. Cancellation preserves the active borrow,
large source origins retain integer identity, and arithmetic failure can recover
through explicit reset. Diagnostic tests verify sampled balanced frame/cepstrum/FFT
spans ending before consumer callbacks.

## Host performance

The [38-case matrix](../../Tools/Cepstrum/README.md#host-performance-matrix) separates
preparation/destruction, borrowed processing, input conversion and owned exports.
All **76 timing rows / 152 metric distributions** passed with 30 samples each after
three warmups. Allocator interposition is disabled in the inspected timing binary.

Selected Float64 source rows at 48 kHz (analysis 10 kHz, M=1000, N=1024) follow.
Each p99 is milliseconds for **one entire declared Run**, including reset/finalization
for pipelines. Preview uses 16 FIR lobes and cutoff fraction 0.9. These are pre-CPP
checksum consumers. The isolated frame is already conditioned and has a different
denominator from source-input batches.

| Operation | Input duration | Hop ms | Run p99 ms | Prepared scalar bytes |
| --- | ---: | ---: | ---: | ---: |
| Isolated 10 kHz frame | 0.1 s | — | 0.012458 | 73,600 |
| Double conversion/checksum baseline | 1 s | — | 0.048292 | 0 |
| Whole-interval checksum | 1 s | 2 | 7.561250 | 2,647,568 |
| Preview checksum | 1 s | 5 | 3.981208 | 110,376 |
| Preview checksum | 1 s | 10 | 2.926875 | 110,376 |
| Whole-interval checksum | 60 s | 2 | 489.594833 | 162,144,144 |
| Preview checksum | 60 s | 5 | 244.726375 | 110,376 |
| Preview checksum | 60 s | 10 | 172.676917 | 110,376 |
| Whole-interval owned matrix | 1 s | 2 | 9.075375 | 2,647,568 |
| Preview owned matrix | 1 s | 5 | 4.597542 | 110,376 |
| Preview owned matrix | 1 s | 10 | 3.091000 | 110,376 |

Float input pipeline workspaces add 32,768 bytes of prepared widening scratch;
source PCM bytes are reported separately. Owned matrix storage, object overhead and
opaque Accelerate tables are excluded from prepared scalar bytes. Export rows measure
their allocations explicitly. The collector reuses its prepared profile identity instead
of hashing each retained row. The full artifact includes both input precisions,
16 kHz sources, preparation, all stages and conversion rows omitted from this table.

Timing raw-distribution SHA-256:
`bc53bbb2a0546dd0d966cf1689140dbaa7b150f273cc91af9ac86a9259af0e5a`.

Input duration divided by full-batch duration gives processing throughput. The
whole-interval path must still wait for the complete declared input before emitting.
Batch distributions do not measure individual preview frame latency, capture callback
deadlines, sustained device behavior, process RSS, or clinical applicability. No
performance regression threshold or physical-device suitability is asserted.

## Allocation evidence and verification

All **77 allocation rows / 539 metric distributions** passed with 30 samples each.
All **90 prepared heap histograms** (malloc count, bytes and object allocations across
30 checksum/conversion runs) have maximum zero. Eight owned-export runs explicitly
permit allocations. The positive-control maxima are malloc count 2, bytes 4,120,
frees 2, object allocations 1, retains 2 and releases 3. ARC activity in prepared
processing is reported, not asserted absent. Instrumented timing is diagnostic.

Allocation raw-distribution SHA-256:
`45b0dbb36f79aaaaf899643370fd2fa5b2704d18e50b5bfa2ad37cea60c21afb`.

The allocation gate initially found captured mutable-state boxes in whole-interval
finalization and a named consumer closure in the harness. Prepared callback state
and explicitly nonescaping callbacks remove them; the full final matrix confirms
zero maxima across both precisions, both input rates and both durations. The collector
also reuses its validated profile identity, avoiding a hash/serialization for each
owned row. Public construction and decoding still recompute and validate that identity.

The initial complete local run passed 124 xUnit cases in each macOS debug, release,
Address Sanitizer and Thread Sanitizer lane; 128 Python tests; provenance for 152
fixtures; consumer/dependency/offline checks; and unsigned iOS 27 Simulator/device
builds. Both lifecycle regressions for reset/cancellation and arithmetic-failure
recovery passed. Final-code local gates and hosted checks/artifact audits are recorded
in the issue's PR and must pass before merge. Workflow lint and formatting pass.
The fresh independent reference candidate reproduced the complete committed manifest
exactly. None of these checks substitutes for the physical evidence deferred in #74.
