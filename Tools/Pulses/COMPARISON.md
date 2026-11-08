# Native pulse comparison policy

Frozen before the first complete native/reference catalog comparison. The inputs
and expected outputs already exist in the independently generated 110-case
catalog, 255 external F0 queries, and 96 high-precision matching-stage fixtures.
Native output never supplies an expected pulse position.

* Full raw landmark counts and ordering: exact, with the constant-waveform
  exception below. Each position must be within **1e-6 samples** of its pinned
  reference position. This is a catalog acceptance budget, not a universal error
  bound: it reserves cumulative arithmetic error for up to 4,096 tracking steps
  at the isolated 2e-10-sample allowance. A changed search window, peak selection,
  or acceptance decision must be investigated; the budget cannot excuse it.
* F0 availability is exact; available frequency differs by at most **1e-10 Hz**.
  All boundary queries, including adjacent representable times, are retained.
* Isolated normalized correlations differ from the 80-digit observed-pair
  equations by at most **2e-12**. Observed-pair counts are exact. Selected
  well-conditioned Gaussian steps differ by at most **2e-10 samples**.
* Every available native cycle amplitude has a corresponding external
  amplitude at the same raw point index and satisfies **2e-12 + 1e-10 |RMS|**.
  This additional tight gate can fail even when location parity passes. Native
  eligibility may reject extra support/run/selection failures; it cannot invent
  an external amplitude or silently replace unavailability with zero.

For an exactly constant nonzero waveform, normalized observed-pair correlation
is exactly one at every nonempty lag. Its true curvature is zero. Finite-precision
summation can create small spurious local maxima and change the raw trajectory.
Thus raw constant-waveform counts/positions are retained as diagnostics, with
no location-parity claim. The required analytic invariant is **zero eligible
periods and amplitudes**, and a degenerate-support rejection on every raw point.
This exception requires checking every actual input sample for exact equality;
it is not a case-name exemption for arbitrary disagreement. Silence remains in
the exact-count/position comparison. Decision record: issue #151.

Known-source timing is a separate comparison against the original generator's
landmarks. A sampled quadratic interpolation has systematic bias that may
accumulate along a track. Native/reference tolerance never absorbs that bias.
The finite Gaussian source-timing bound remains pending; passing this catalog
alone does not close #42 or establish glottal-closure accuracy.

## Independent histories and exact-template timing

The separate 50-case history catalog freezes its policy in
`trace_oracle.COMPARISON` before any native history comparison. Its original
80-digit observed-pair equations retain every proposed step, including failures.
A graph of actual successful tracking edges supplies connected components for
run membership. It never infers a missed step from a flat external point list.
Counts, indices, eligibility, and all rejection reasons must match exactly.
Positions, period durations, and amplitude support endpoints use **2e-10 samples**;
correlations, curvature, and adjacent-period ratios use **2e-12**. F0 uses
**1e-10 Hz**. Cycle RMS uses the same amplitude budget as the full catalog.

Exact binary sample templates supply separate closed-form timing anchors,
including fractional seeds and 80/150/300/600 Hz trains. Interior extrema permit
quadratic refinement. An extremum at the seed-search endpoint does not; the
declared `endpoint-seed` case retains a **-0.25-sample phase bias** through its
integer-period track. Its source landmarks remain the original fractional
coordinates. Both absolute source error and residual after that analytically
known bias are recorded. No tolerance is widened to hide the bias. These anchors
do not establish a Gaussian, arbitrary-waveform, or physiological timing bound.

Direct complete-interval and irregularly chunked complete-block processing must
both satisfy every history record. Native output is never an oracle input. The
external raw trajectory supplies an additional independent cross-check; its
available amplitudes do not replace native support and run qualification.
