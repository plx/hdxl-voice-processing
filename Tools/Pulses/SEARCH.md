# Pulse-search mathematics and independent stages

This document pins the mathematical conventions used to develop #42. It is not
evidence that a native tracker is complete. The executable/revision identity is
in [the reference lock](../Reference/toolchain.json); the
[published method](https://www.fon.hum.uva.nl/praat/manual/Sound___Pitch__To_PointProcess__cc_.html)
and retained pinned-executable probes establish the reference route. Original
equations in `stages.py` use 80-digit Decimal arithmetic and complete lag tables,
independently of the future native worker. No upstream source is incorporated.

## Coordinates and F0 support

PCM sample `i`, numbered from zero, has center `(i + 1/2) / sampleRate`.
The observed acquisition is half-open `[0, sampleCount / sampleRate)`.
The sampled reference grid uses the binary64 operation order
`q = (time - firstCenter) / step + 1`, a one-based real coordinate.
The zero-based low/high indices are `floor(q)-1` and `ceil(q)-1`.
Nearest-sample rounding is `floor(q+1/2)-1`, with exact half ties toward
positive infinity, including negative coordinates. Algebraically simplifying
the coordinate expression can change an index next to a representable boundary.

Interpolated F0 first selects its nearest frame by comparing the fractional
part of `q` with `1/2`. A nearest frame outside the supplied grid, unvoiced, or
outside the declared domain gives an undefined result. If both neighboring
frames are voiced, frequency is their linear interpolation in hertz. If only
the nearest frame is defined, that value is retained for its half-frame support;
there is no interpolation through a voiced/unvoiced boundary. A contour whose
centers cover only the domain interior does not acquire artificial edge frames.

`f0_probe.praat` queries the pinned Pitch object directly. Its transcript retains
every requested binary64 time, including immediate neighbors of half-frame
boundaries. Decimal-looking times are not automatically exact boundaries of a
binary64 sampled grid. The strict parser rejects missing, reordered, extra,
nonfinite, zero-frequency and mismatched query rows.

## Whole-interval seed

Each maximal sequence of voiced F0 frames defines a voiced interval extending
half a frame step beyond its endpoint centers, clipped to the declared domain.
The reference does not begin an interval whose left edge is at or after
`domainEnd - step/2`. At the interval midpoint, its F0 gives the initial period.
The seed search spans half that period on each side. PCM support includes the
low index at the left bound and the high index at the right bound, clipped to
observed samples.

For three or more supported samples, choose the largest absolute waveform
extremum. Equal absolute positive/negative extrema favor the positive one;
equal extrema of the same sign favor the earliest. A constant window uses its
midpoint. An extremum with two supported neighbors receives a three-point
quadratic refinement; an endpoint does not. One observed sample supplies its
center; two equal absolute samples supply their midpoint. Empty support falls
back to the search midpoint. These are raw anchoring conventions, not evidence
that the waveform contains a defensible vocal cycle.

Whole-interval anchoring and the global waveform peak depend on future input.
Any live block implementation must declare a finite block's complete support,
latency and reset behavior, with a separate profile identity; it cannot promise
prefix stability or period continuity across independently anchored blocks.

## Matching a neighboring cycle

At current landmark `t` with defined frequency `f`, let `P=1/f`. The reference
window's inclusive PCM indices are the nearest indices to `t-P/2` and `t+P/2`.
For forward tracking, the candidate landmark range is `[t+0.8P, t+1.25P]`;
for backward tracking it is `[t-1.25P, t-0.8P]`. Candidate window starts range
from the low index of `searchLeft-P/2` through the high index of
`searchRight-P/2`, inclusive. The pinned upper bound is 1.25, not the abbreviated
1.2 in the manual.

For anchor window `[a,b]` and candidate start `k`, define
`J = { j : a ≤ j ≤ b, 0 ≤ j < N, 0 ≤ j+k-a < N }`. The correlation is

`C(k) = sum(x[j] x[j+k-a]) / sqrt(sum(x[j]²) sum(x[j+k-a]²))`, for `j` in `J`.

No mean removal or zero padding occurs. If either energy is zero, the raw
coefficient is zero. Missing support and silent support have distinct diagnostics.
The candidate amplitude is `max(abs(x[j+k-a]))` over those same observed pairs.
An exact constant waveform can have coefficient one while supplying no varying
timing information. The independent oracle retains that distinction and preserves
very small nonzero energies with Decimal arithmetic.

The finite candidate table has two preceding zero correlation sentinels.
Potential peak centers range from one position before the first evaluated lag
through one position before the last evaluated lag; the last lag supplies only
a right neighbor. Among local maxima at least as high as both neighbors and
strictly greater than -1, choose the greatest value, breaking ties toward the
earliest lag. The raw amplitude gate uses the **right neighbor's** candidate
amplitude. These explicit release conventions are tested separately from the
correlation equation. They are not fabricated PCM observations.

For neighboring values `(L,M,R)` at `(-1,0,1)`, the independent quadratic is
`y(z)=A z²+B z+M`, where `A=(L+R)/2-M` and `B=(R-L)/2`.
The vertex is `z=-B/(2A)` with height `M-B²/(4A)`. Flat curvature supplies no
fractional refinement. The raw interpolated height can exceed one; it is not
a calibrated confidence probability and must not silently be serialized as one.

The proposed time is `t + (fractionalCandidateStart-anchorStart)/sampleRate`.
If it falls outside the candidate landmark range, the pinned fallback uses the
signed geometric mean of the two distances from `t` (one nominal period for the
0.8–1.25 range), and retains the larger of the selected sampled coefficient and
the final evaluated coefficient. If no local maximum is selected, raw progression
advances one nominal period and marks that matching step unsuccessful.

Internal acceptance requires correlation greater than 0.3 and candidate peak
either exactly zero or greater than 0.01 of the global absolute PCM peak.
An extra point beyond the voiced interval requires correlation greater than 0.7
and peak greater than 0.023333 of that global peak. The backward path additionally
suppresses points within 0.8 current periods of the previously retained rightmost
point from an earlier voiced interval. The tracker continues from each proposed
time even if its acceptance gate fails; that failure history must remain explicit
so downstream periods never bridge it.

## Conditioning and known-source timing

Reference pulse-location agreement and known generated-source timing are different
claims. A three-point fit to a sampled smooth peak can have systematic bias, and
following cycles from a midpoint seed can accumulate it. For an isolated Gaussian
with standard deviation `σ` samples and fractional offset `d`, peak samples are
`exp(-(j-d)²/(2σ²))`. Continuous normalized autocorrelation has samples
`exp(-(j-d)²/(4σ²))`. Substitution into the quadratic above gives an independent
closed-form per-step bias; sign reversal of `d` reverses that bias.

This explains the approximately 0.009086-sample per-period bias of the narrow
16 kHz / 600 Hz catalog train and its accumulated approximately 1.38-sample
endpoint error. Finite/discrete support and input rounding still require their
own evidence. Do not widen native/reference tolerance to absorb source-model
bias, or claim the continuous-Gaussian formula bounds every noisy/filtered input.

Current isolated-stage comparison budgets are `2e-12` for normalized correlation
and `2e-10` samples for a well-conditioned interpolated peak. The 80-digit oracle,
closed-form examples, and external stage probes validate these independently of
native results. Flat/ambiguous peak selection needs explicit diagnostics and
cannot be made trustworthy by a larger position tolerance. Complete native
location, run/eligibility and known-source timing budgets remain to be frozen
with their final support/conditioning scope before native conformance validation.
