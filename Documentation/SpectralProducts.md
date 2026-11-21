# Bounded spectral products

The core library accepts finite mono PCM and its source sample grid. A prepared spectrogram emits one synchronous borrowed column per eligible grid position. Copy a column with `owned()` to send it across an isolation boundary, retain it, or encode it as a standalone JSON record. The caller controls how many records to keep. A worker and its aggregate can process successive chunks for an entire continuity epoch.

## Profiles, axes and source support

Construct a `SpectrogramLayout` from a validated framing configuration, transform length, upstream channel selection and usable bandwidth. Supply a conditioning profile identity when preprocessing the PCM. A channel index identifies input selected before analysis. Arithmetic mixing averages channels in the time domain before windowing, so phase cancellation can reduce power. The worker applies the declared window directly. It adds no pre-emphasis, demeaning, or resampling. Restart with a new worker and aggregate after a discontinuity or profile change.

Each spectral row records the zero-origin frequency grid in hertz, supported bin count, actual source interval, epoch origin, frame ordinal, nominal window, FFT length, precision, channel policy, bandwidth and profile fingerprint. Frequency bin `k` lies at `k × sampleRate / transformLength`. The last supported bin lies at or below both the declared usable source bandwidth and Nyquist. Queries beyond that grid return `unsupportedRange`. Window length determines time support and spectral leakage. Extra transform zeros refine the frequency grid. Equivalent noise bandwidth is `sampleRate × sum(w²) / sum(w)²` hertz, using coefficients rounded to the selected precision. [Fourier conventions](FourierTransforms.md) and [framing conventions](Framing.md) define these primitives. Praat also documents its own time-frequency window and grid choices. [Praat spectrogram manual](https://www.fon.hum.uva.nl/praat/manual/Sound__To_Spectrogram___.html)

For an unnormalized transform of windowed samples, one-sided linear bin power is `c × |X[k]|² / (N × sum(w²))`, with `c = 1` at DC and Nyquist and `c = 2` in the interior. With the whole band present, the sum equals the window-weighted mean square. Supported-band sums omit power above the declared cutoff. A presentation can return bin power (FS²), bin RMS amplitude (FS), periodogram density (FS²/Hz), or decibels. Density divides by the FFT grid spacing. Decibels use `10 × (log10(power) − log10(referencePower))`, with a positive finite reference in FS². A zero-power bin has a measured linear zero and an unavailable logarithmic value with reason `silence`. A whole zero-power column has status `noEnergy`. Log values are uncalibrated power ratios. `presented(_:bins:)` serializes the presentation, unit, reference when applicable, starting bin, and individual numerical outcomes.

## Weights and coverage

The default LTAS gives every complete eligible window weight one. The optional `newlyCoveredSamples` policy gives each window an integer weight equal to the number of source samples it adds to the union of measured windows. For contiguous 64-sample windows with hop 16 the first weight is 64 and subsequent weights are 16. Following an excluded region, a disjoint full window contributes 64 again. Both policies retain measured silence in the denominator. They average the full linear-power vector with a stable online weighted mean. Each row exports its weight and new coverage count. Convert the final mean to dB after averaging.

A `MaskTimeline` selects a frame only when its full dependency window lies within one acquired, selected region. A crossing window emits an unavailable row. Missing acquisition inside the mask, other exclusions, numerical analysis failure, and insufficient final support have distinct reasons. The earliest partial tail follows the framing policy and contributes zero LTAS weight. First-frame offsets, gaps between windows, discarded tails, and mask boundaries can all reduce coverage. An empty interval has no columns, zero coverage, and an insufficient-data aggregate. Each LTAS includes unique measured sample count, total observed duration, total weight, row counts and warnings. Supply the original mask with `snapshot(observedSource:selection:)` to report selected, excluded, missing, and outside-plan sample counts and the fraction of selected support measured. Frame-only replay can compute the mean and measured support without the original mask. In that case the independent selected-support denominator is unavailable.

```swift
let worker = try PreparedSpectrogram<Double>(layout: layout, epoch: epoch, selection: mask)
let ltas = try LongTermSpectrumAccumulator(
    layout: layout, epoch: epoch, selectionProfile: worker.selectionProfile)
let ring = try RollingSpectralProducts(layout: layout, capacity: 32)
var consumerError: Error?
let consume: (BorrowedSpectrogramFrame<Double>) -> Void = { frame in
    guard consumerError == nil else { return }
    do {
        try ltas.append(frame)
        try ring.append(frame)
    } catch { consumerError = error }
}
for chunk in chunks {
    try chunk.samples.withUnsafeBufferPointer { samples in
        _ = try worker.process(samples, interval: chunk.source, emit: consume)
    }
    if let consumerError { throw consumerError }
}
let completion = try worker.finish(emit: consume)
if let consumerError { throw consumerError }
let average = try ltas.snapshot(observedSource: completion.observedSource, selection: mask)
let retained = ring.snapshot()
```

Offline consumers can encode each owned row with `JSONEncoder` and append a newline to a file or stream. Decode each line as a `SpectrogramFrame`, then pass it to an accumulator configured with the same layout, epoch origin and selection fingerprint. Keep the original grid order and all eligible rows. Omitting unavailable rows preserves the mean and unique measured time, while their reason counts require the original rows. Pass the full observed interval from the framer when finishing a replay.

## Cepstrograms, retention and display

`PowerCepstrogramExporter` copies the power-cepstrum stage of the existing interval or finite-FIR preview worker. Use its `slice(_:)` export to serialize the row, quefrency axis and unit together. Its row uses the canonical configuration, center, source dependencies, precision and unavailability. Its zero-origin quefrency axis advances by one analysis sample period, in seconds, and its power unit is s⁻². A reference whole-interval worker can report wider source dependencies than the nominal analysis frame. Existing `BoundedCepstrogram` callers retain their capacity-exhaustion behavior. [Canonical cepstral recipe](Cepstrum.md) and [Praat power cepstrogram manual](https://www.fon.hum.uva.nl/praat/manual/Sound__To_PowerCepstrogram___.html)

`RollingSpectralProducts` accepts spectra or canonical cepstra from one profile and continuity origin in increasing frame order. Capacity is 1–30,000 columns with a maximum of 16,777,216 linear scalars. Full rings evict the oldest row. Chronological snapshots serialize capacity, evictions, axes, units and the actual support of each retained row. Snapshots and exported rows own their data. External clients that retain many snapshots control that additional memory.

`displayColumns(framesPerColumn:aggregation:)` groups consecutive retained columns, including the final shorter group. Maximum linear power preserves brief peaks in each bin. Arithmetic mean weights complete columns equally. The display export identifies its rule, frame indices, source envelope, complete frame count and unavailable reasons. An all-unavailable group has no power vector. Partial cepstral diagnostic prefixes stay available in the source row and do not enter display averages. The original rows remain available for numerical measurements.

The [benchmark protocol](../Tools/SpectralProducts/README.md) includes the shared workload registration, operation boundaries and long-stream memory check.
