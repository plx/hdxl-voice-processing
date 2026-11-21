"""Independent closed-form spectrum of a finite Hann-windowed sinusoid.

Derived directly from the finite geometric series and the three exponential
terms of the periodic Hann. This is a verification/investigation helper, not
the discrete analyzer profile and not a replacement for its interpolated FFT.
"""
import cmath
import math


def geometric_sum(omega, count):
    """Sum exp(-i*omega*j), j=0..<count, including its removable singularity."""
    omega = math.remainder(omega, 2 * math.pi)
    if omega == 0:
        return complex(count)
    return (cmath.exp(-1j * omega * (count - 1) / 2)
            * (math.sin(count * omega / 2) / math.sin(omega / 2)))


def hann_tone_magnitude(frequency_hz, signal_hz, rate, count, offset, phase=0.):
    omega, fundamental = 2 * math.pi * frequency_hz / rate, 2 * math.pi * signal_hz / rate
    local_phase = phase + fundamental * offset

    def sine_sum(at):
        return (cmath.exp(1j * local_phase) * geometric_sum(at - fundamental, count)
                - cmath.exp(-1j * local_phase) * geometric_sum(at + fundamental, count)) / (2j)

    return abs(.5 * sine_sum(omega) - .25 * sine_sum(omega - 2 * math.pi / count)
               - .25 * sine_sum(omega + 2 * math.pi / count))


def exact_spectrum_estimate(analyzer, frequency_hz, phase=0.):
    """Isolate spectral interpolation from the otherwise unchanged profile.

    Shares candidate kernels/window blending/refinement with the oracle, so
    this investigation is not independent validation of those shared stages.
    Its analytic DTFT bypasses the entire FFT/magnitude interpolation path.
    """
    from swipe_oracle import refine
    layout = analyzer.layout
    count = layout['requiredSampleCount']
    loudness = {}
    for length in layout['windowLengths']:
        values = [math.sqrt(hann_tone_magnitude(
            f, frequency_hz, analyzer.profile['sampleRate'], length, (count - length) // 2, phase))
            for f in layout['erbFrequenciesHz']]
        norm = math.sqrt(math.fsum(x * x for x in values))
        loudness[length] = [x / norm for x in values]
    scores = []
    for kernel, pair in zip(analyzer.kernels, layout['candidateWindows']):
        score = math.fsum(x * y for x, y in zip(kernel, loudness[pair['lowerLength']]))
        weight = pair['upperWeight']
        if weight:
            upper = math.fsum(x * y for x, y in zip(kernel, loudness[pair['upperLength']]))
            score = (1 - weight) * score + weight * upper
        scores.append(score)
    index = max(range(len(scores)), key=lambda i: (scores[i], -i))
    return refine(layout['candidateFrequenciesHz'], scores, index)
