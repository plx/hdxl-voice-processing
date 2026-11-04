# Fourier transforms and spectra

`PreparedFourierTransform<Float>` and `PreparedFourierTransform<Double>` implement
`fourier-negative-forward-inverse-over-n/v1`. The configuration explicitly records
precision, sample rate, and transform length. The version supports **exactly powers
of two from 2 through 4,194,304**, inclusive, using Accelerate's radix-2 FFT setup.
It does not implicitly round lengths or switch precision. `lengthPadding(_:)` is
an explicit helper when a caller chooses to pad an observed interval. The separate
`WindowSpecification` limit remains 65,536 observed samples. The larger transform
capacity supports whole-interval conditioning: 60 seconds at 48 kHz plus two
1,000-sample reference padding margins needs N=4,194,304. This capacity does not
establish a real-time device budget or make the transform causal.

The core target imports Accelerate, without audio capture or playback frameworks.
The package minimum remains macOS 27 / iOS 27.

## Mathematical convention

For N samples and integer bin k:

```
X[k] = sum(n=0..<N, x[n] * exp(-i*2*pi*n*k/N))
x[n] = (1/N) * sum(k=0..<N, X[k] * exp(+i*2*pi*n*k/N))
sum(abs(x)^2) = sum(abs(X)^2) / N
```

The forward transform is unnormalized. The inverse divides by N. The input is
already conditioned and windowed; these primitives do not subtract a mean, apply
a window, resample, or select an algorithm's logarithmic floor.

Real forward output is an ordinary `FourierBin<Sample>` buffer of **N/2+1** values:
DC at zero, interior positive-frequency bins, and Nyquist at N/2. Both endpoint
imaginary components are exactly zero. Negative frequencies reconstruct as
`X[N-k] = conjugate(X[k])`, for `1 <= k < N/2`. Real inverse requires exactly this
one-sided buffer and rejects nonzero endpoint imaginary values, however small.
It emits N real samples. No packed storage escapes the API.

Complex forward/inverse use N ordinary complex values. The frequency order is
`0,1,...,N/2-1,-N/2,...,-1` times fs/N. Real frequency order includes positive
Nyquist, `0,...,N/2` times fs/N. `realFrequencyHz(at:)` and
`complexFrequencyHz(at:)` validate their indices. Frequency spacing is fs/N;
zero padding interpolates this grid without adding observed information.

### Accelerate calibration

Internally, real time samples are packed even/odd into split-complex storage.
After forward transformation, vDSP packs DC in `real[0]` and Nyquist in `imag[0]`.
Its real forward values are **2X**: this wrapper multiplies them by 1/2 before
unpacking. Inverse real input is repacked from canonical X, and raw output is
multiplied by 1/N. Complex forward needs no factor; complex inverse uses 1/N.

These factors were checked on Xcode 27's installed Accelerate runtime using an
impulse at N=2,4,8,16,256,65536, then against independent direct DFT and inverse
oracles. Apple’s [packing and scaling documentation](https://developer.apple.com/documentation/accelerate/understanding-data-packing-for-fourier-transforms)
provides the packed layout and normalization table. The installed SDK's real FFT
inverse pseudocode differs from that table; runtime and mathematical-oracle tests
are the calibration authority here. Mixed-radix DFT setup APIs have different
length constraints and are not this version's backend.

## Ownership, buffers, and applicability

A plan owns two N-element scalar buffers plus one precision-specific vDSP setup.
`scalarWorkspaceBytes` reports only those two buffers, excluding opaque setup
tables and object overhead. At N=4,194,304 these scalar buffers alone are 32 MiB
for Float or 64 MiB for Double. Out-of-place complex input and output add another
64 MiB or 128 MiB respectively; vDSP setup tables, allocator retention, and the
surrounding application are additional costs. The plan is intentionally **not
Sendable**. Each actor or
worker prepares its own instance, uses it synchronously, and retains it between
frames. No mutable workspace or setup is shared globally. These are worker-side
numerical primitives, not audio-callback APIs. Dropping the owner releases its
setup and buffers; there is no streaming history to reset.

Output buffers must have exact required counts. Forward input may contain 1...N
samples; the remainder is zero-filled. Empty input is rejected. The returned
`FourierApplication` records supplied count and numerical padding count. Supplied
samples can already include padding from `PreparedWindow`: neither count certifies
observed support. Keep the original `PCMFrameSupport`, `WindowApplication`, and
upstream availability alongside the result. A numerical spectrum of a partial
frame must not become a valid measurement by losing that status.

All inputs are staged before caller output is written, so complex transforms
support exact in-place and overlapping input/output buffers. Nonfinite inputs,
wrong counts, nonreal real-spectrum endpoints, and nonfinite computed results
throw. Caller output is unchanged on failure; the plan remains reusable. Finite
inputs may exceed ±1, but vDSP intermediate overflow is rejected even when a
mathematically rearranged calculation could have a finite result. Ordinary
floating-point underflow is retained; the API applies no floor or clipping.

## Spectrum conversions

`SpectrumConfiguration` combines a transform with a `WindowSpecification` of M
samples, where `M <= N`, with matching precision and rate. It serializes strictly
and has a versioned identity. `PreparedSpectrum<Sample>` prepares the actual
precision's window coefficients and records the window identity, coherent gain
CG = sum(w)/M, and energy gain EG = sum(w²)/M. It owns a reusable N/2+1 scalar
staging buffer and is also single-owner and non-Sendable.

The supplied bins must come from a complete M-sample observed window, multiplied
by that window and padded to N. This correspondence is the caller's responsibility;
a bare numeric buffer cannot prove its provenance or availability.

Let c=1 for DC and Nyquist and c=2 for all interior positive-frequency bins:

| Operation | Definition | Units and interpretation |
| --- | --- | --- |
| `writeMagnitude` | abs(X[k]) | Raw DFT magnitude, input amplitude times samples |
| `writeAmplitude` | c abs(X[k]) / (M CG) | Bin-centered sinusoidal peak amplitude convention |
| `writePower` | c abs(X[k])² / (N M EG) | Each bin's contribution to corrected mean square |
| `writePowerDensity` | c abs(X[k])² / (fs M EG) | Periodogram density, input amplitude² per Hz |

The power sum equals `sum((x*w)^2)/sum(w²)`; the density sum times fs/N equals the
same value. It is not generally the unwindowed signal's mean square. Coherent
amplitude correction does not fix off-bin leakage or overlapping window lobes.
The peak-amplitude convention likewise requires the sinusoid's positive and
negative window lobes not to overlap appreciably. Endpoint weights stay one.

Scaling is applied before squaring, reducing avoidable intermediate overflow and
underflow. Results use the selected Sample precision. A zero-gain window (such as
symmetric Hann with M=2) permits raw magnitude but rejects normalized operations.
A normalization factor that is nonfinite or underflows to zero at the selected
precision is rejected. Nonfinite bins or results and nonreal endpoints fail before
any output is changed. A caller choosing logarithms must supply its own explicit
floor, units, and applicability rules.

## Independent accuracy contract

`Tools/Fourier/oracle.py` evaluates the direct complex exponential sum with Python
binary64 `sin`/`cos` and `math.fsum`, without importing Accelerate, an FFT library,
or this package. Full scalar transforms are bounded to N<=128. The committed 192
cases contain full small vectors and selected bins at **every supported length**,
with precision-rounded input hashes. They include DC, impulses, Nyquist, positive
and negative complex tones, off-bin tones, seeded noise, silence, very small
signals, arbitrary complex inverse spectra, and Hermitian inverse spectra.

The committed absolute component error budgets are `C*u*log2(N)*||input||2` for
forward and that value divided by N for inverse, with `(C,u)=(8,2^-24)` for Float
and `(64,2^-53)` for Double. These are acceptance bounds for the tested input
families, not a proof for arbitrary dynamic range. See the fixture's per-case
limits, [original evidence](Evidence/fourier.md), and the
[large-transform extension](Evidence/large-fourier.md). Scalar oracle rounding is
included in the comparison. Separate tests cover all-length round trips, Parseval
energy, padding, axes, window gains, failure atomicity, and concurrent independent
workspaces. Large cases run sequentially within one test, with compensated
Double accumulation for energy references; their transform tolerances are unchanged.
Unsupported sizes and precision mismatches fail explicitly.

## Diagnostics and performance

A package-scoped initializer accepts the owning worker's `WorkerDiagnostics`.
The `.fft` interval surrounds only the vDSP kernel, excluding packing, validation,
normalization, copying, and spectrum conversions. A consumer supplies its existing
`withFrame` scope and profile/frame metadata. Public initializers disable recording;
no PCM or per-sample diagnostics are emitted. Instrumented worker timings are not
audio-callback measurements.

The [benchmark tool](../Tools/Fourier/README.md) records setup, individual real and
complex transforms, spectrum and explicitly floored inverse-cepstrum workloads,
bounded scalar comparisons, and four-actor sequential/concurrent timing. Allocation
claims cover prepared core operations separately from setup and task scheduling.
The separate large-transform matrix uses one operation per sample, retains only
the selected operation's buffers, and records sampled whole-process resident
memory alongside explicit owned-buffer counts. See the extension evidence for
its limitations. Physical-device latency and thermal evidence remain deferred
under issue #74.
