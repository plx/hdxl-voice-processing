# A12 pulse correctness evidence

The tracker accepts PCM and an explicit supplied F0 contour. Reference parity,
known-source timing, native eligibility and estimated-F0 integration are separate
gates. None supplies physiological ground truth. Numerical policies and source
identities are retained in the [pulse tools](../../Tools/Pulses/README.md).

## Pinned reference and sequence qualification

The 110-case raw catalog covers both precisions, three rates, steady/varying F0,
known jitter and amplitude modulation, polarity, harmonic/filter changes, missing
cycles, wrong F0, noise, splices, short inputs and licensed speech. Native comparison
checks 8,521 positions within the fixed 1e-6-sample budget and 8,142 available
amplitudes within 2e-12 + 1e-10 |RMS|. Maximum observed position error is
2.7755575615628914e-14 samples. Two exactly constant waveforms have no meaningful
timing curvature: their required invariant is zero eligible periods/amplitudes,
with every raw point explicitly rejected. This exception checks actual PCM equality.

The isolated references retain 255 F0 queries and 96 complete matching tables.
The separate 50-case history oracle uses 80-digit equations and connected components
of successful tracking edges. It preserves 1,586 attempts, 1,434 raw points,
1,386 adjacent intervals and 1,342 adjacent-period pairs, including every failure.
Native direct and chunked processing agree on all reasons, run IDs and eligibility:
1,088 eligible periods, 958 eligible pairs and 890 available amplitudes. Failed
steps, exclusions, gaps and boundary fragments never disappear by joining survivors.

Exact binary templates supply additional closed-form fractional timing anchors.
They expose an endpoint seed that retains a declared -0.25-sample phase bias and
a seed in a silent gap that can reacquire another phase without usable amplitudes.
Those findings remain explicit; they are not generalized into arbitrary-waveform
timing accuracy.

## Finite generated-source timing

The [source policy](../../Tools/Pulses/SOURCE_TIMING.md) was recorded before the
finite-input certificates were generated. Its original SHA-256 is
`86f94d3a78eb249e3979668e2ed2834c470fe36dc61eb4b37be7f4f5ba30d776`.
The budget is derived from source geometry, Gaussian interpolation bias and input
precision. Actual tracker results are never inputs to the certificate or budget.
The earlier proposed universal finite-Gaussian tail argument was not adopted as
an unproved theorem: the implemented certificate encloses the actual finite PCM
calculation, including alternate rounded windows and possible winning peaks.

All 36 cases passed: 24 steady rate/frequency/precision combinations plus both
precisions of inverted, quiet, 1%/12% jitter, modulated and alternating-strength
sources. The 38 promoted files retain 4,290 source points. Native Release tests
exercise both support profiles, including 137-sample chunk delivery, for 8,580
point comparisons. Counts/order match exactly and every native time belongs to
its independently certified algorithm interval. The widest interval is
8.556862250014285e-8 samples; this uncertainty surrounds the biased algorithm
position, not the original source center.

Representative Float64 source errors (samples) are:

| Generated input | Maximum observed source error | Fixed source radius |
| --- | ---: | ---: |
| 16 kHz / 80 Hz | 5.56e-14 | 0.0117455 |
| 16 kHz / 150 Hz | 0.0219530 | 0.0613400 |
| 16 kHz / 300 Hz | 0.1719453 | 0.3830125 |
| 16 kHz / 600 Hz | 1.3797372 | 2.8698102 |
| 1% jitter, 16 kHz / 150 Hz | 0.0054663 | 0.0626922 |
| 12% jitter, 16 kHz / 150 Hz | 0.0020385 | 0.0626922 |

Every certified source-error bound is below 0.481 of its fixed radius. Original
source coordinates remain unchanged; the approximately 1.38-sample accumulated
bias is reported as such. Polarity inversion preserves the trajectory; modulation,
alternating strength and quiet input remain separately evaluated at actual input
precision. Filtered/harmonic/noisy inputs retain their reference and applicability
tests and do not inherit this pure-Gaussian source claim.

The enclosure uses exact integer sums after expressing binary64 PCM over a common
power-of-two denominator. For at most 4,096 observed pairs, positive fused sums
have relative error at most gamma(n)=nu/(1-nu), u=2^-53. Input guards ensure all
nonzero products and normalization products are normal, and bounds preclude
overflow. A conservative upper normalization factor is
`(1+gamma)^2/(1-gamma)^3`; for this bounded gamma it differs from one by less than
8 gamma. The corresponding lower factor is also within 8 gamma. Since the exact
normalized coefficient is in [0,1], this is an absolute coefficient enclosure.
Four additional ulps at one exceed the 80-digit normalization and binary64
conversion error. Cancellation and subnormal normalization are deliberately outside
this certificate domain; their runtime behavior has separate native/reference tests.

Outward arithmetic encloses subsequent interpolation and time operations. The
verifier considers every rounded-window possibility and every potential winning
peak, checks curvature and acceptance, and rejects possible range fallback.
It also rejects rehashed corruption of source coordinates, intervals, radii,
identities, coverage and execution scope. Rational-arithmetic and closed-form
correlation controls validate the enclosing primitives independently.

Source manifest SHA-256:
`603be83f5a8d7ad772d1ef7694a0e42d52a59e71a4523d959722c22437e39974`.
Initial native candidate audit SHA-256:
`abf9ed3cf0749eacc212fcb8f24925a5464c0dbac4226b7ef7a12d592190b9e3`.

## Estimated F0, contracts and performance

Sixteen cases separately compare scalar/FFT YIN followed by pulses with independent
YIN equations followed by the pinned external pulse route. All 152 complete YIN
frames and 175 raw pulses per backend remain visible; no complete frame or no
usable cycle is an explicit unavailable outcome. Whole and irregularly chunked
YIN delivery yield identical pulse snapshots. Upstream F0 and downstream pulse
errors use separate declared budgets, with no forced voicing for difficult speech
or noise.

Configuration/F0 Codable validation, stable identities, units, unavailable reasons,
large integer source positions, source/host/completion anchors, bounded ownership,
reset/cancellation and cross-task owned snapshots are tested. The public result
does not claim a versioned archive format. Complete-interval and independent-block
support have distinct profile identities and documented complete-input delay.

The [88-case performance matrix](pulses-performance.md) has separate preparation,
borrowed processing, owned copies and accepted/rejected stage costs. Physical
capture, sustained-device and thermal evidence remains owner-authorized follow-up
[#74](https://github.com/plx/hdxl-voice-processing/issues/74). Final full-suite,
platform, hosted CI and review receipts belong to the implementing PR; the focused
evidence above does not claim those remaining gates have passed.
