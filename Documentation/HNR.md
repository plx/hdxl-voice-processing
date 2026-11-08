# HNR implementation contract

Issue #39 is in progress. The frozen external/reference tooling is described in
[Tools/HNR](../Tools/HNR/README.md); it was committed before native implementation.
The package's AC and CC profiles have separate names, support and numerical output.
Neither requires external F0. Whole-interval and finite causal-window silence
normalization have separate identities; a causal result never claims access to an
unknown future whole-recording maximum.

The native configuration serializes rate, input precision, Double arithmetic,
floor, periods, hop, silence competitor, window/interpolation/overshoot conventions,
the numerical peak-resolution rule and reporting limits. Unknown fields and altered
derived conventions are rejected. Nominal centers, acquired sample support and the
silence reference's full dependency must remain separate in results. Complete
whole-interval grids use fused multiply-add for each center; no epsilon shifts a
frame into the input. Unsupported short inputs produce no complete grid frames.

Correlation arithmetic uses zero-padded FFTs, independently checked against direct
compensated Python sums. Preparation computes the Gaussian window correction once.
CC uses convolution and compensated rolling energies, with a directly recomputed
lag when a shifted window's energy is too small for reliable subtraction. Undefined
energy and the explicit uncomputed zero interpolation tail remain distinguishable.
Sinc uses an angle recurrence with a near-integer sine reduction, avoiding repeated
transcendental calls and division-amplified error near the right integer endpoint.

Native intermediate checks use absolute 2e-14 for normalized correlation and
interpolated peak strength, 2e-12 for unnormalized correlation sums, 4e-16 for window
coefficients and 2e-5 samples for refined peak position. The latter acknowledges
the shallow peak's sensitivity to last-bit objective differences; final HNR still
must meet the separately frozen, much more directly relevant HNR comparison policy.
These bounds are not clinical equivalence margins and do not authorize silent
reference regeneration. Every external timestamp is checked exactly.

`HNRPeriodicityEstimate` keeps the unreflected peak, reciprocal reflection,
periodicity, residual noise fraction, uncapped finite dB and reference presentation
separate. Numerical unity has no finite dB value. The reference's ±150 dB limits are
explicit states, not ordinary finite observations or proven physical noise absence.
Negative/zero candidate strengths are unavailable rather than 0 dB. An HNR of 0 dB
is a valid finite estimate at periodicity 0.5. Small positive periodicities use a
logarithmic difference to avoid ratio underflow.

`PreparedHNR` accepts exactly the acquired support described by its layout and a
separately prepared normalization record. It rejects precision, profile, interval,
rate, buffer and nonfinite-input mismatches, and synchronous reentrancy. Callback
buffers expire on return; candidate export is an explicit bounded allocation.
The strongest retained observation remains inspectable when the relative-silence
competitor prevents selection. Scalar export marks periodicity below 0.5 and
reporting-limit observations as low confidence; that display warning neither
rejects the value nor denotes a health or pleasantness boundary. Numerical unity
remains available in the typed result but has no finite scalar export.

`PreparedIntervalHNR` accepts contiguous chunks, waits for complete input, computes
the whole-interval reference once and reuses frame scratch. Repeated finish does
not repeat output. Incomplete finish is recoverable; invalid append is atomic.
Cancellation during a callback preserves the borrow and stops before the next
frame. Same-capacity reset declares a new independent interval. Empty and short
intervals emit an explicit insufficient-data slot, never a fabricated complete
frame. Acquired support union, available/unavailable slots, finite estimates,
reporting limits and numerical unity have separate counts.

The completion exposes reference presentation mean (including explicit caps) and
uncapped finite-only mean with their respective denominators. Its ordinary mean
is unavailable after cancellation or when any selected frame has numerical zero
noise; finite-only diagnostics do not silently become a full-population mean.
Missing frames remain in coverage. The source/host clocks, local support and full
normalization dependency are retained separately.

`PreparedHNRStream` uses only each complete acquired window for normalization,
including mean/lag support. Its ring and emission buffers are bounded by
`ceil(nominalSupportSeconds * sampleRate)` and reuse the prepared frame kernel.
Input chunks affect delivery only. Window `k` starts at `floor(k * step)`, where
`step` is the exact rational value of the binary64 product `hopSeconds * sampleRate`
(canonicalized to at least one sample). An integer phase accumulator implements
that rule without accumulating a floating clock. At 44.1 kHz and 5 ms, starts are
0, 220, 441, 661, 882, ...; a value just below a decimal step stays below it rather
than acquiring an undeclared epsilon. This grid has a separate profile identity
from the whole-interval centered grid.

Streaming results retain both a stream-relative center and the frame center
relative to its normalization dependency. Source indices are subtracted before
conversion to seconds. Normalization scale, mean and peak remain inspectable
alongside local amplitudes. Source and host anchors are optional, with checked
integer host-time advancement; neither reset nor finish guesses missing clocks.
Whole chunks are validated before consumption. A gap requires an explicit epoch
reset; a long requested hop skips unanalyzed samples without stitching windows.
Preparation and processing belong on a worker, not an audio capture callback.

Streaming finish emits at most the earliest nonempty incomplete window as an
insufficient-data result, with actual acquired support and no padding. This policy
is serialized. Empty streams emit no frames and have explicit empty completion.
Ordinary finish is idempotent; callback cancellation preserves the borrow, releases
storage ownership, returns the exact consumed prefix and requires reset before
further use. Reset discards buffered history and reuses capacity when available;
reconfiguration prepares a complete replacement before changing the current state.
Reentrant processing, reset, finish and reconfiguration are rejected.

The 12 independent causal fixtures contain 312 complete windows and 12 partial
tails across both methods, three rates and two precisions. They retain an amplitude
step and recovery, exact rational positions and independent direct-sum window
results. Native batch and irregular-chunk output agree exactly; numerical outputs
meet the same frozen periodicity/dB tolerances. Four million phase advances are
also checked at independently computed rational checkpoints. These checks establish
causal behavior, not equivalence to unknown whole-file normalization.

Mask/coverage selection, processing-path integration, performance registration,
all remaining software gates and both reviews remain required before this leaf
is complete.
