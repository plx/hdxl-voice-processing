"""Original compact source recipes, independent expectations, and roadmap coverage."""
import copy
import math
from fractions import Fraction

from sequences import statistics, outcome
from synthetic import require


def signal(name, source, count=2048, rate=16000, **changes):
    return {"schemaVersion": 1, "identifier": {"name": name, "version": 1},
            "sampleRate": rate, "sampleCount": count, "source": source, "gain": 1, "clip": False,
            "formants": [], "initialFilterState": [], "missingIntervals": [], **changes}


def harmonics(fundamental, orders=(1,), amplitudes=None, phase=0):
    if amplitudes is None:
        amplitudes = [0.125 / order for order in orders]
    require(len(amplitudes) == len(orders), "Harmonic amplitude count mismatch")
    return {"kind": "harmonics", "components": [{"frequencyHz": float(Fraction(str(fundamental)) * order),
        "amplitude": amplitude, "phaseTurns": phase} for order, amplitude in zip(orders, amplitudes)]}


def changed(base, name, **changes):
    result = copy.deepcopy(base)
    result.update(changes)
    result["identifier"]["name"] = name
    return result


def recipes():
    tone = signal("bin-tone", harmonics(1000, amplitudes=[0.25]))
    formants = [{"frequencyHz": 500, "bandwidthHz": 70}, {"frequencyHz": 1500, "bandwidthHz": 100},
                {"frequencyHz": 2500, "bandwidthHz": 140}]
    periods = ["1/100"] * 13
    periods[6] = "11/1000"
    amplitudes = [0.25] * 14
    amplitudes[6] = 0.275
    result = [
        signal("silence", {"kind": "dc", "value": 0}),
        signal("empty", {"kind": "dc", "value": 0}, count=0),
        signal("one-sample", {"kind": "dc", "value": 0.25}, count=1),
        signal("dc", {"kind": "dc", "value": 0.25}, count=16),
        signal("impulse", {"kind": "impulse", "index": 0, "amplitude": 0.5}, count=16),
        signal("quarter-tone", harmonics(4000, amplitudes=[0.5]), count=8),
        signal("nyquist-cosine", harmonics(8000, amplitudes=[0.25], phase="1/4"), count=16),
        signal("nyquist-sine-zero", harmonics(8000, amplitudes=[0.25]), count=16),
        tone,
        changed(tone, "tone-inverted", gain=-1),
        changed(tone, "tone-half-gain", gain=0.5),
        changed(tone, "tone-double-rate", sampleRate=32000, sampleCount=4096),
        signal("tone-time-dilated", harmonics(500, amplitudes=[0.25]), count=4096),
        signal("off-bin-tone", harmonics("217.25", amplitudes=[0.25])),
        signal("harmonic-low", harmonics("62.5", (1, 2, 3, 5), [0.125, 0.0625, 0.03125, 0.015625]), count=4096),
        signal("harmonic-high", harmonics(625, (1, 2, 3), [0.125, 0.0625, 0.03125])),
        signal("missing-fundamental", harmonics(125, (2, 3, 4), [0.125, 0.0625, 0.03125]), count=4096),
        signal("dominant-upper", harmonics(125, (1, 2, 3), [0.015625, 0.25, 0.0625]), count=4096),
        signal("inharmonic", {"kind": "harmonics", "components": [
            {"frequencyHz": f, "amplitude": 0.0625, "phaseTurns": 0} for f in (220, 331, 503)]}, count=4096),
        signal("clipped-dc", {"kind": "dc", "value": 0.75}, count=32, gain=2, clip=True),
        signal("subnormal-dc", {"kind": "dc", "value": 2**-1074}, count=16),
        signal("regular-pulses", {"kind": "pulses", "startSeconds": "1/125",
            "periodsSeconds": ["1/125"] * 15, "amplitudes": [0.25] * 16}, count=2304),
        signal("irregular-pulses", {"kind": "pulses", "startSeconds": "1/200",
            "periodsSeconds": periods, "amplitudes": amplitudes}, count=2400),
        changed(tone, "missing-intervals", missingIntervals=[{"startSample": 512, "sampleCount": 256},
                                                            {"startSample": 1408, "sampleCount": 64}]),
        changed(tone, "fully-excluded", sampleCount=64, missingIntervals=[{"startSample": 0, "sampleCount": 64}]),
        signal("noise-seed-zero", {"kind": "noise", "seed": 0, "amplitude": 0.125}, count=4096),
        signal("noise-seed-seven", {"kind": "noise", "seed": 7, "amplitude": 0.125}, count=4096),
        signal("known-pole-impulse", {"kind": "impulse", "index": 0, "amplitude": 0.5}, count=32,
               formants=[{"frequencyHz": 4000, "bandwidthHz": "3530.1696024424255"}], initialFilterState=[[0, 0]]),
        signal("vowel-low", harmonics(125, tuple(range(1, 13)), [0.04/k for k in range(1, 13)]), count=4096,
               formants=formants, initialFilterState=[[0, 0] for _ in formants], gain=0.01),
        signal("vowel-high", harmonics(625, (1, 2, 3, 4, 5), [0.04/k for k in range(1, 6)]), count=4096,
               formants=formants, initialFilterState=[[0, 0] for _ in formants], gain=0.01),
        signal("source-harmonics", harmonics(200, (1, 2), [0.125, 0.0625]), count=8000),
        signal("filtered-harmonics", harmonics(200, (1, 2), [0.125, 0.0625]), count=8000,
               formants=formants[:2], initialFilterState=[[0, 0], [0, 0]], gain=0.01),
    ]
    mixture_signal = signal("mixture-source", harmonics(1000, amplitudes=[0.05]), count=4096)
    mixture_noise = signal("mixture-noise", {"kind": "noise", "seed": 42, "amplitude": 1}, count=4096)
    for snr in (0, 20):
        result.append({"schemaVersion": 1, "identifier": {"name": f"noise-mixture-{snr}db", "version": 1},
                       "mixture": {"source": mixture_signal, "noise": mixture_noise, "snrDB": snr}})
    return result


def scalar(kind, unit, value=None, reason=None, formula="", tolerance=1e-14):
    return {"classification": "analytic", "measurement": {"kind": kind, "unit": unit,
        "algorithm": {"name": "synthetic-equations", "version": 1}},
        "outcome": outcome(value, reason=reason), "formula": formula, "absoluteTolerance": tolerance}


def expectations():
    return {
        "silence": [scalar("rms", "normalizedAmplitude", 0, formula="Constant zero has zero RMS"),
                    scalar("levelDBFS", "decibelsFullScale", reason="silence", formula="log(0) has no finite dB estimate")],
        "empty": [scalar("rms", "normalizedAmplitude", reason="insufficientData", formula="Empty support is not a zero measurement")],
        "dc": [scalar("rms", "normalizedAmplitude", 0.25, formula="RMS of constant c = abs(c)"),
               scalar("peakAmplitude", "normalizedAmplitude", 0.25, formula="Constant amplitude")],
        "impulse": [scalar("rms", "normalizedAmplitude", 0.125, formula="0.5 / sqrt(16)"),
                    scalar("peakAmplitude", "normalizedAmplitude", 0.5, formula="Impulse amplitude")],
        "quarter-tone": [scalar("rms", "normalizedAmplitude", math.sqrt(0.125), formula="Complete cycles: A/sqrt(2)")],
        "bin-tone": [scalar("rms", "normalizedAmplitude", 0.25/math.sqrt(2), formula="128 complete cycles: A/sqrt(2)")],
        "nyquist-cosine": [scalar("rms", "normalizedAmplitude", 0.25, formula="Alternating +/-A has RMS A, not A/sqrt(2)")],
        "nyquist-sine-zero": [scalar("rms", "normalizedAmplitude", 0, formula="sin(pi*n) = 0 at all integer n")],
        "clipped-dc": [scalar("rms", "normalizedAmplitude", 1, formula="Explicitly clipped constant"),
                       scalar("clippingFraction", "fraction", 1, formula="32 of 32 pre-clip samples exceed full scale"),
                       scalar("calibratedSPL", "decibelsSPL", reason="inapplicableTask", formula="No acoustic calibration supplied")],
        "subnormal-dc": [scalar("peakAmplitude", "normalizedAmplitude", 2**-1074, formula="Smallest positive binary64, nonzero", tolerance=0)],
        "missing-intervals": [{"classification": "analytic", "includedSampleCount": 1728,
                               "formula": "2048 - 256 - 64; gaps remain in source support"}],
        "fully-excluded": [{"classification": "analytic", "includedSampleCount": 0,
                            "formula": "No included samples; do not erase the exclusion mask"}],
        "harmonic-low": [{"classification": "analytic", "fundamentalHz": 62.5, "exactIntegerPeriodSamples": 256,
                          "formula": "All harmonic orders are integers with GCD 1; d(tau=256)=0 with full support"}],
        "missing-fundamental": [{"classification": "analytic", "fundamentalHz": 125,
            "formula": "Harmonic orders 2,3,4 have GCD 1 although H1 amplitude is zero",
            "estimatorCaveat": "Source periodicity is known; a pitch estimator may make octave errors"}],
        "source-harmonics": [scalar("h1MinusH2", "decibelsRatio", 20*math.log10(2), formula="20*log10(0.125/0.0625)", tolerance=1e-12)],
    }


def sequence_cases():
    periods = ["1/100"] * 13
    periods[6] = "11/1000"
    amplitudes = ["1/2"] * 13
    amplitudes[6] = "11/20"
    mask = [True] * 13
    mask[6] = False
    return {"schemaVersion": 1, "cases": {
        "period-constant": statistics(["1/100"] * 13, "period"),
        "period-irregular": statistics(periods, "period"),
        "period-missing": statistics(periods, "period", mask),
        "period-short": statistics(["1/100"], "period"),
        "period-zero": statistics([0, 0], "period"),
        "amplitude-constant": statistics(["1/2"] * 13, "amplitude"),
        "amplitude-irregular": statistics(amplitudes, "amplitude"),
        "amplitude-missing": statistics(amplitudes, "amplitude", mask),
        "amplitude-silence": statistics([0] * 13, "amplitude"),
        "amplitude-short": statistics(["1/2"], "amplitude"),
    }}


def algebra_cases():
    # Explicit closed-form arrays, not results of the generator/native analyzers.
    return {"schemaVersion": 1, "cases": {
        "quarter-dft": {"classification": "analytic", "inputCase": "quarter-tone", "real": [0]*8,
            "imaginary": [0,0,-2,0,0,0,2,0], "normalization": "unnormalized forward negative-exponent DFT"},
        "impulse-cepstrum": {"classification": "analytic", "inputCase": "impulse",
            "realCepstrum": [math.log(0.25)] + [0]*15,
            "convention": "rectangular, no preprocessing; inverse DFT(log(abs(DFT(x))^2)), inverse scaled 1/N; natural log"},
        "straight-background": {"classification": "analytic", "quefrencySeconds": [i/1000 for i in range(1,22)],
            "decibels": [10 - i/10 + (8 if i == 5 else 0) for i in range(1,22)],
            "expectedSlopeDBPerSecond": -100, "expectedInterceptDB": 10, "explicitPeakIndex": 4, "prominenceAtExplicitBinDB": 8,
            "scope": "robust straight-fit and supplied-bin prominence only; not an interpolated native peak estimate"},
        "constant-smoothing": {"classification": "invariant", "input": [[4]*7 for _ in range(5)],
            "expected": [[4]*7 for _ in range(5)], "condition": "normalized rectangular averaging with renormalized edges"},
        "interval-db-mean": {"classification": "analytic", "valuesDB": [10,20], "includedFrameCounts": [3,1],
            "expectedDB": 12.5, "condition": "arithmetic frame-dB mean on separate included intervals; no stitching"},
        "yin-difference": {"classification": "analytic", "inputCase": "quarter-tone", "integrationSamples": 4,
            "lags": [1,2,3,4], "differences": [1,2,1,0], "cmnd": [1,4/3,0.75,0],
            "scope": "difference/CMND primitives; 4kHz is outside ordinary speaking-range profiles"},
        "spectral-two-lines": {"classification": "analytic", "frequenciesHz": [1000,3000], "powerWeights": [3,1],
            "centroidHz": 1500, "varianceHzSquared": 750000, "bandEnergyRatio": 3,
            "weighting": "power, positive-frequency lines; population moments; bands separate the two lines"},
        "dc-preemphasis": {"classification": "analytic", "inputCase": "dc", "alpha": 0.5, "previousInput": 0,
            "expected": [0.25]+[0.125]*15, "formula": "y[n] = x[n] - alpha*x[n-1]"},
    }}


COVERAGE = [
    ("A01",24,["dc"],["missing-intervals","one-sample"],"Exact source indices, windows and missing support; production framing tests follow in #24"),
    ("A02",30,["quarter-dft","nyquist-cosine"],["empty","off-bin-tone"],"Closed-form DFT packing/scaling and leakage case"),
    ("A03",31,["dc-preemphasis","tone-double-rate"],["nyquist-sine-zero","one-sample"],"Pre-emphasis recurrence and common-time rate samples; Nyquist ambiguity"),
    ("A04",32,["dc","bin-tone","clipped-dc"],["silence","subnormal-dc"],"RMS/peak/gain/clip counts; K-filter linearity and DC rejection require its profile/warm-up in #32"),
    ("A05",33,["impulse-cepstrum","tone-half-gain"],["silence","one-sample"],"Log-power cepstrum scaling; gain affects quefrency zero only in the stated no-floor convention"),
    ("A06",35,["straight-background"],["silence","off-bin-tone"],"Robust baseline anchors and explicit-bin prominence; peak interpolation cases added in #35"),
    ("A07",37,["constant-smoothing","interval-db-mean"],["fully-excluded","missing-intervals"],"Constant-preserving smoothing and separate-interval aggregation"),
    ("A08",34,["missing-intervals"],["fully-excluded","noise-seed-zero"],"Exact coverage; source labels are synthetic applicability labels, not speech probabilities"),
    ("A09",38,["yin-difference","harmonic-low"],["missing-fundamental","dominant-upper","silence"],"Known difference/periodicity; source F0 is not a guarantee of estimator success"),
    ("A10",44,["harmonic-low","tone-half-gain"],["inharmonic","missing-fundamental","silence"],"Known harmonic frequencies and gain-invariant normalized pitch strength within eligibility"),
    ("A11",39,["noise-mixture-20db","tone-inverted"],["noise-mixture-0db","silence"],"Known component SNR and polarity invariance; estimated HNR bias is empirical"),
    ("A12",42,["regular-pulses"],["irregular-pulses","missing-intervals","one-sample"],"Declared pulse times/amplitudes and explicit sample-grid rounding"),
    ("A13",50,["period-constant","period-irregular"],["period-missing","period-zero","period-short"],"Exact accepted-sequence jitter; waveform eligibility is separate"),
    ("A14",51,["amplitude-constant","amplitude-irregular"],["amplitude-missing","amplitude-silence","amplitude-short"],"Exact rational APQ/local/DDA and high-precision logarithmic shimmer"),
    ("A15",41,["quarter-dft","interval-db-mean"],["missing-intervals","empty"],"Line energies and covered weighted aggregation; no invented frames at gaps"),
    ("A16",45,["spectral-two-lines"],["silence","nyquist-cosine"],"Power-weighted spectral moments/ratios; zero denominator and edge-bin conventions"),
    ("A17",46,["known-pole-impulse","vowel-low"],["vowel-high","one-sample"],"Known stable poles; spectral peaks and finite-window LPC estimates may differ"),
    ("A18",52,["source-harmonics","filtered-harmonics"],["missing-fundamental","vowel-high","nyquist-sine-zero"],"Known harmonic amplitudes and discrete all-pole response; Iseli/VoiceSauce-specific correction oracle follows in #52"),
]
