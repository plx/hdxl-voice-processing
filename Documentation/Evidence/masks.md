# A08 mask evidence

Implementation based on main `616bbf0c163fe60be64d855d195de60ef88d74c3`.
Initial evidence was collected 2026-11-05 UTC on Mac13,1 arm64, macOS 27.0.1,
Xcode 27.0 (27A266a), Swift 6.4 and Python 3.14.8. Physical capture/device/thermal
measurements remain [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
Independent human phonation labels remain [#102](https://github.com/plx/hdxl-voice-processing/issues/102);
the supported reference domain and its defects are recorded in
[#109](https://github.com/plx/hdxl-voice-processing/issues/109).

## Reference validation

The promoted catalog has 35 cases, 5,088 frames and 103,571 selected spectral powers.
Every flatness and intensity value, the spectral/intensity/combined interval tiers,
and exact source-sample selection boundaries are compared to pinned Praat 7.0.02.
The ordinary catalog includes analytic/synthetic signals, fricative/quiet-vowel/
breathy/irregular surrogates, previously attributed speech fixtures, 8/16/44.1/48 kHz
sampling, fractional windows, different hops, both source precisions and a long
rolling-history/rebase case. Speech attribution is retained; external speech
activity is not ground-truth phonation.

Before native comparison, the numerical policies were frozen at spectral power
absolute 1e-16 plus relative 1e-9; flatness absolute 1e-8 plus relative 1e-10;
intensity absolute 1e-7 dB; interval times absolute 1e-12 seconds; and exact integer
source-sample boundaries. The largest observed fractions of these budgets were
0.001671 for power, 0.009483 for flatness and 2.843e-7 for intensity. Interval
boundaries matched exactly. No tolerance was enlarged to fit the implementation.

An independent Python quadrature/temporal GM-AM oracle also checks the full external
flatness output. Three explicit negative probes preserve the pinned executable's
first-row mutation, a bounded timeout in short-single-interval removal, and its early
all-speech return. These failures are not numerical goldens: the native supported
profile excludes the mutated band and reports short inputs as insufficient.

An initial grid comparison exposed a one-sample centering difference at off-grid
8/44.1/48 kHz lengths. Reproducing the executable's two fused operations resolved it
without changing the definition or tolerance. Original development scripts and
receipts identify the pinned source/executable; `Tools/Masks/README.md` documents the
reproduction commands. All 55 promoted files are inventoried, bringing the complete
fixture provenance count to 424. Offline negative tests reject corrupted numerical
metadata, PCM, reference anomaly receipts and artifact inventories.

## Original timeline and selection

The randomized sweep tests compare overlapping mask policies against an independent
per-sample oracle. Streaming tests exercise gaps, reset, cancellation, reentrancy,
invalid-input atomicity, extreme finite amplitudes, rolling rebase, empty selection,
source positions above 2^53 and chunk equivalence. Instrumentation checks pairing,
sampling, reset identities and consumer boundaries in all modes.

The actual PCM-to-CPP diagnostic retains the four-second original timeline and its
100 ms acquisition gap. Its 372 all-eligible frames average 19.246652392 dB; selecting
the harmonic regions yields 182 frames averaging 25.349360553 dB, at 50% source
coverage and 51.28205% acquired coverage. Selected regions independently reproduce
the routed/reset worker results. Whole-interval conditioning contexts differ across
these populations. This is an illustration of selection bias, not clinical validation.
The input Float64 SHA-256 is
`2b107bb6a0c45a8ce8259c05a56d17a09a9fc428cab60aef9fb15534ad6675d6`.

## Host performance protocol

The 26-case matrix separates preparation/destruction, 600-second LTSF, energy and
routing passes, dense interval resolution, canonical metadata export and repeated
reset operations. Each input and plan is hashed; all 26 cases reproduce their output
checksums/counts under a second chunk size. A 600-second 16 kHz LTSF run emits 59,999
frames and owns 6,991,928 scalar/interval bytes, excluding opaque FFT setup and object
overhead. It retains neither the complete PCM nor the complete spectrogram.
The routing plan has 30,000 observations, 5.96 seconds of missing acquisition and
297.02 selected seconds. Dense resolution and JSON export allocate on the control
path; preparation and metadata volume are explicit. Repeated reset timings measure
reusable state reset, while functional tests additionally verify clearing prior data.

Clean timing is separate from allocator/ARC diagnostics. Long Runs have ten measured
complete passes after one warmup; their p99 is effectively an observed maximum, not
a stable per-frame tail estimate. Resolution/export/reset request thirty measured
operations after three warmups. The validator requires at least ten observations,
complete geometry/count/metric coverage, a positive allocation/ARC control and zero
heap maxima for prepared detector/routing/reset Runs. These are host distributions,
not physical capture deadlines or acoustic latency claims. LTSF final decisions
still wait for the declared interval to complete.

An initial pre-commit Double timing capture measured 1.7399–1.7971 seconds per
600-second 16 kHz run across 64/256/1024-sample chunks, and 3.3641 seconds at 48 kHz
with 256-sample chunks. These correspond to about 334–345 and 178 audio seconds per
compute second, respectively. The capture is explicitly a dirty development tree;
final PR checks retain separate artifact receipts at their tested revision.
Initial timing raw-distribution SHA-256:
`c9f3adb0adb19822354e3f180630d07978e8ccbd095dccce01750ed652a89599`.

Workloads and instrumentation are registered under
[#25](https://github.com/plx/hdxl-voice-processing/issues/25#issuecomment-6653413515) and
[#18](https://github.com/plx/hdxl-voice-processing/issues/18#issuecomment-6653413907).
