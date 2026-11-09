# Finite generated-source timing policy

This policy is declared before the new finite-input certificate is generated or
compared with native output. It does not change the 1e-6-sample native/reference
budget. The certificate uses generated PCM, F0 and source coordinates only;
external and native tracker results are not inputs.

The catalog to certify consists of the 24 steady Gaussian rate/frequency/precision
cases, plus both precisions of inverted, quiet, 1%/12% jitter, modulated and
alternating-strength Gaussian trains. Missing cycles, filtered/harmonic/noisy
inputs, gaps and seed-window endpoint conventions retain their separate reference
and history tests; they do not acquire a pure-Gaussian source-error claim.

## A priori source-error budget

Let P be the nominal period in samples, sigma=0.06P, a=1/(4 sigma²), and d the
fractional offset of an actual generated source spacing from its nearest integer.
The ideal Gaussian correlation's three-point vertex is

    r(a,d) = sinh(2ad) / (2 (exp(a) - cosh(2ad))).

The period-bias allowance is max |r(a,d)-d| over the source spacings, plus 3e-8
samples. Let epsilon be 1e-7 for Float32 input or 1e-11 for Float64 input;
u=2^-53, gamma(n)=nu/(1-nu), n=ceil(P)+7. At h=0.500001, define

    D(a) = 2 exp(-a h²) (1 - exp(-a) cosh(2ah))
    q = exp(-pi² sigma²), theta = 2q/(1-q³)
    E = 4 epsilon/(1-epsilon) + 2 theta/(1-theta) + 8 gamma(n)
    seed = 1/(8 sigma²) + 3e-6 + 3 epsilon/(D(2a)-4 epsilon) + 1e-8
    steps = ceil(sourcePulseCount/2) + 2
    radius = 2 (seed + steps (periodBias + 3E/(D(a)-4E) + 1e-8)) + 0.01

This input-derived radius is a fixed acceptance policy, not a theorem that an
infinite Gaussian bounds finite PCM. It reserves ideal interpolation bias and
input/arithmetic error. The certificate below must establish that the actual
finite-input calculation fits inside it. A failing certificate is not permission
to enlarge the radius from observed tracker output.

## Independent finite-input enclosure

Every input sample is a binary rational. Scaling all samples by a common power of
two permits exact integer energy and dot-product sums. The common scale cancels
from normalized correlation. Evaluate the final square root/division at 80 decimal
digits; retain a conservative absolute enclosure of 8 gamma(observedPairCount)
plus four binary64 ulps at one. Positive products, finite normalized PCM, bounded
windows and normal nonzero products/energy products are checked assumptions.
Thus the enclosure covers the native fused positive sums, product, square root
and division, as well as the much smaller oracle conversion error. It makes no
claim for cancellation, subnormal normalization, or arbitrary waveforms.

Outward-rounded binary64 intervals then propagate all seed and tracking arithmetic.
Every possible rounded anchor/candidate window is enumerated. All peak centers
that can win under the coefficient enclosures are included; unresolved selection
is not silently resolved by a nominal oracle value. Fractional interpolation and
time propagation enclose those alternatives. Search-range fallback, zero/ambiguous
curvature, failed acceptance or unbounded branching fail this certificate.

Starting at the independently selected seed, both paths must enclose one position
per generated source landmark, stay inside acquired/voiced support, and remain
within the fixed source-error radius. The retained intervals characterize the
algorithm's finite-input interpolation bias; the source coordinates are unchanged.
Native comparison must independently require exact source count/order and membership
in these intervals, as well as the source-error radius. Additional raw points are
not excused. Period/run eligibility still comes from the separate history contract.

This is a finite-catalog numerical claim. It is neither a universal Gaussian-error
theorem nor glottal-closure/physiological accuracy evidence.
