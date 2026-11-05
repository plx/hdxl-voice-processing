# Masks and transparent interval selection

Masks preserve the original sample timeline and the evidence used to select it.
They do not turn a rejected region into missing audio, join separate regions, or
automatically reject low-periodicity material. No built-in mask depends on F0
tracking, CPP, or HNR. Speech activity is an operational detector label; it does
not identify phoneme-level voicing or diagnose voice health.

## Sources and coverage

`MaskPlan` is a strictly decoded, versioned input contract. Each observation names
an original `SourceInterval`, a provenance-table index, an optional selection vote,
and independent diagnostic tags. `MaskProvenance` distinguishes external annotation,
energy eligibility, spectral-flatness activity, consumer-provided learned activity,
acquisition diagnostics, and algorithm diagnostics. Learned activity must preserve
the model name and version. Configuration parameters participate in the provenance
fingerprint; no model is provided or downloaded by the package.

`MaskSelectionPolicy` explicitly chooses sources and combines them with `all` or
`any`. Within one source, a rejected vote wins overlapping positive votes; missing
votes do not select. An empty source list selects all acquired samples, subject to
explicit rejected tags. Missing acquisition is always ineligible. Clipping,
suspected external noise, low periodicity confidence, silence, energy decisions,
speech activity, and algorithm insufficiency remain distinct inspectable tags.

`MaskTimeline` resolves overlapping, unordered observations into a half-open
partition, contiguous eligible/selected regions, and an owned export. Coverage obeys:

```
source samples = missing samples + eligible samples
eligible samples = selected samples + excluded eligible samples
```

Both counts and durations are exported, together with selected/source and
selected/eligible fractions. Empty denominators produce zero coverage. Per-tag
durations are unions within a category; different categories can overlap and must
not be summed. The report includes original observations, provenance, policy,
effective delay, and exclusion reasons. An empty selection has no selected regions
or numeric result; it does not acquire a favorable score of zero.

## Separate regions and raw diagnostics

`selectedRegion(containing:)` requires the complete dependency support of a
measurement to fit within one selected region. Pass conditioning, windowing, and
smoothing support, not just the displayed center. `eligibleRegion(containing:)`
provides the equivalent raw/all-acquired check and still refuses acquisition gaps.

`PreparedMaskCursor` borrows slices of the original PCM, preserving epoch and sample
positions. Choose `.selected` or `.allEligible` explicitly. Every delivery identifies
its entire region and whether it starts or ends that region. Consumers reset their
kernel on `startsRegion` and finalize it on `endsRegion`; separate regions must not
share filter, smoothing, pitch, or frame-assembly state. `skipMissingAcquisition`
advances only through intervals declared missing, without placeholder PCM.

The cursor retains no PCM. Emission is synchronous and borrowed; copy only through
an explicit bounded ownership decision. Invalid input is rejected before mutation.
Cancellation stops after the current delivery. Reset-to-start replays the same
immutable timeline; a new timeline uses a new cursor.

## Absolute-energy eligibility

`PreparedEnergyEligibility` is a causal worker with constant-size state. It computes
scaled Double RMS energy over disjoint rectangular windows, referenced to unit-peak
PCM dBFS. Input may be Float32 or Float64. It applies no de-meaning, frequency filter,
speech classifier, or periodicity criterion.

The initial state is ineligible. Consecutive windows at or above `activationDBFS`
activate eligibility; consecutive windows strictly below `deactivationDBFS`
deactivate it. The off threshold cannot exceed the on threshold. A window that does
not meet the pending transition criterion clears its confirmation count. The state
changes on the confirming window, with no retroactive relabeling of earlier output.
Confirmation counts, window/hop lengths, thresholds, comparisons, bandwidth,
precision, and state convention are explicit in provenance.

Labels are available after their complete window, so declared decision delay is one
window. Confirmation duration describes additional response time separately. After
activation, at least the deactivation-confirmation count of complete windows remains
selected, and conversely after deactivation. The initial prefix and a truncated final
region are not extended. A partial final window is unavailable/insufficient, with no
state transition. Exact zero energy is tagged `zeroEnergy`, never a finite made-up
dB floor. An acquisition discontinuity clears partial energy and all hysteresis state.

## Pinned temporal-flatness profile

`PreparedLTSFDetector` implements the supported-domain fixed-threshold behavior of
Praat 7.0.02. It accepts finite mono PCM with explicit rate, precision, bandwidth,
and a declared complete source interval. It processes arbitrary contiguous chunks
while retaining bounded spectral/history rings and compact final features. It does
not retain full PCM or a full time-by-frequency spectrogram. Final labels require
`finish`: the centered frame grid, optional input-wide intensity maximum, and interval
cleanup depend on the declared source. Maximum source-relative finalization delay
is exported as the source duration. This profile is not an immediately final causal VAD.

The numerical definition includes:

- A physical Hann width `max(20 ms, 2 × hop)`, the pinned observed-sample/window
  convention, explicit FFT grouping, and an exactly reproduced centered grid.
- Centered piecewise-linear short-time power averaging with constant half-cell
  endpoint caps, followed by trailing temporal geometric/arithmetic means per
  frequency. Only positive powers participate. Flatness sums `log10(GM/AM)` across
  the resolved frequency bins; it is not single-frame flatness across frequency.
- Strict `flatness < threshold` activity decisions, transitions at frame centers,
  short speech removal before short non-speech removal, and explicit minimum lengths.
- Optional relative intensity from the reference 80–8000 Hz bin rule, ±32 ms power
  averaging, a `4e-10` numerical power reference, and a parabolically interpolated
  global maximum. These dB values are not calibrated SPL. Its fixed 20 ms combination
  end margin is preserved; the combination is not a plain set intersection.
- Nearest source-sample-boundary quantization, with ties away from zero. Requested
  and effective frequency bounds are both exported: the requested 70 Hz default
  resolves to a 46.875 Hz first included bin center at 16 kHz.

Float32 PCM is promoted to Double; this is explicit in profile identity. The MVP
supports 8–96 kHz input, 2–50 ms hops, bounded short/long histories, and intervals up
to ten minutes. Declared input bandwidth must cover the effective requested band.
The preparation budget bounds spectral/history storage; `scalarWorkspaceBytes`
reports owned scalar and interval storage, excluding opaque FFT tables/object headers.

Including reference frequency row 1 is rejected because the pinned command mutates
that row while calculating the feature. Intervals shorter than the analysis window
or either minimum interval duration report insufficient data. This avoids a pinned
nontermination case and an early all-speech return. These decisions are tracked in
[#109](https://github.com/plx/hdxl-voice-processing/issues/109).

Raw spectra and final features are borrowed only during their callbacks. Owned
feature export has an explicit shared scalar budget. `exportMaskPlan` is a separate
allocation-bearing metadata operation. Reset can reuse allocations for an equally
sized independent source region; it clears history and adopts that region's epoch
and positions. Cancellation retains an active borrowed view until callback return.

## Reference identity and applicability

[Reference tooling](../Tools/Masks/README.md) records executable/source hashes,
inputs, numerical budgets, external output digests, independent checks, and explicit
negative cases. The primary method sources are the
[Praat LTSF manual](https://www.fon.hum.uva.nl/praat/manual/Sound__To_TextGrid__speech_activity__LTSF____.html),
[Ma and Nishihara (2013)](https://link.springer.com/article/10.1186/1687-4722-2013-21),
its [2015 correction](https://link.springer.com/article/10.1186/s13636-015-0071-8), and
the [voice-only CPP study](https://www.isca-archive.org/interspeech_2023/murton23_interspeech.pdf).

The paper's adaptive threshold, initialization, and voting stage are a different
detector. The published voice-only CPP recipe also includes filtering, separate-region
CPP calculation, and duration weighting; selecting its mask settings alone does not
implement that entire pipeline or establish historical Praat 6 parity.

Synthetic fricative, quiet-vowel, breathy, and irregular surrogates test algorithms;
they are not human phonation annotations. Licensed speech excerpts also do not supply
independent phoneme labels. Human-label validation remains in
[#102](https://github.com/plx/hdxl-voice-processing/issues/102), and physical measurements
remain in [#74](https://github.com/plx/hdxl-voice-processing/issues/74).

## Selection changes the population being measured

`MaskCPPIntegrationTests` supplies an original four-second 16 kHz signal: two
one-second 125 Hz harmonic regions alternating with deterministic broadband noise,
plus a declared 100 ms acquisition gap. It computes actual PCM-to-CPP through the
pinned robust fit, retaining original integer positions above 2^54. Each contiguous
analysis region is conditioned independently; equal-sized selected regions also
exercise reset and match independently prepared workers exactly.

The all-eligible path emits 372 available frames with mean CPP **19.24665 dB**.
Selecting the two harmonic regions emits 182 frames with mean **25.34936 dB**,
while retaining **50% of source duration** and **51.28205% of acquired duration**.
This constructed example illustrates selection bias, not a clinically preferred
value or a ground-truth speech/phonation classification. The different contiguous
regions also have different whole-interval conditioning contexts. No F0, CPP or
HNR value determines the mask. Low-periodicity input remains in the raw diagnostic
path; no output is silently discarded because pitch tracking failed.

The same integration suite verifies that two separated 80 ms regions produce two
insufficient results for a 100 ms cepstral frame, and that empty selection emits no
CPP rows. They cannot be concatenated into a synthetic valid frame. Set
`HDXL_MASK_CPP_REPORT` to a writable path when running these tests to retain the
counts, coverage, means and generated Float64 PCM SHA-256.

## Performance evidence

The nested benchmark package contains 26 explicit ten-minute configurations with
64, 256 and 1024-sample deliveries, both source precisions at 16 kHz and a 48 kHz
Double case. It measures LTSF, absolute energy eligibility and dense-mask routing;
separate operations measure event-sweep resolution, reset and complete canonical
metadata export. Inputs and 30,000 disjoint 20 ms annotations are generated before
measurement. Every configured workload is checked against a second chunk size,
and each selected sample or detector output contributes to a checksum.

Run `python3 Tools/Masks/benchmark.py timing --shard float64` for one group;
`float32` and `operations` complete the matrix. Repeat the groups with `allocation`
for the separate allocator/ARC diagnostic binary. Both modes require the pinned
Xcode, Python, dependencies and positive capability controls where applicable.
Full distributions, units, output counts, hardware, prepared memory, source/profile
identities and exported byte volume are retained in the evidence bundle. Ten
measured full-recording passes provide throughput distributions; their p99 is
essentially the observed maximum, not a stable tail estimate for individual frames.
Prepared LTSF, energy, routing and reset operations are checked for zero heap
allocation maxima. Resolution and owned metadata export allocate explicitly.
Physical device, thermal and capture latency evidence remains follow-up #74.

See [the compiled public consumer example](../Examples/CoreConsumer/Sources/CoreConsumer/main.swift)
for energy observations, an explicit selection policy and original-position coverage,
and [the evidence record](Evidence/masks.md) for numerical and selection diagnostics.
