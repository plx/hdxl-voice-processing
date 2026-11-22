"""Independently generate the benchmark PCM and fit its harmonic levels by QR."""
from functools import lru_cache
import hashlib
import math
import struct


@lru_cache(maxsize=6)
def stimulus(rate, first_resonance):
    count = rate // 20
    state = 52
    samples = []
    for i in range(5 * count):
        state = (1664525 * state + 1013904223) % 2**32
        phase = 2 * math.pi * 137.3 * i / rate
        value = .1 * (state / (2**32 - 1) - .5)
        for harmonic in range(1, math.floor(4800 / 137.3) + 1):
            value += math.cos(harmonic * phase) / math.sqrt(harmonic)
        samples.append(value)
    for frequency, width in ((first_resonance, 110), (1500, 115), (2660, 150), (3650, 190)):
        radius = math.exp(-math.pi * width / rate)
        feedback = 2 * radius * math.cos(2 * math.pi * frequency / rate)
        previous = previous2 = 0.0
        for i, value in enumerate(samples):
            output = (1 - feedback + radius**2) * value + feedback * previous - radius**2 * previous2
            samples[i] = output
            previous2, previous = previous, output
    cut = samples[-count:]
    scale = .5 / max(map(abs, cut))
    integers = [round(scale * value * 32768) for value in cut]
    digest = hashlib.sha256(struct.pack(f'<{count}h', *integers)).hexdigest()
    return tuple(value / 32768 for value in integers), digest


def raw_difference(samples, rate, f0, periods):
    n = math.floor(rate * periods / f0 + .5)
    if not 12 <= n <= len(samples):
        raise ValueError('Incomplete reference fit window')
    offset = (len(samples) - n) // 2
    weights = [math.sin(math.pi * i / (n - 1)) for i in range(n)]  # sqrt(Hann)
    phases = [2 * math.pi * f0 * i / rate for i in range(n)]
    columns = [weights]
    for harmonic in (1, 2):
        for quadrature in (math.cos, math.sin):
            columns.append([w * quadrature(harmonic * phase) for w, phase in zip(weights, phases)])
    response = [w * samples[offset + i] for i, w in enumerate(weights)]

    # Modified Gram–Schmidt on the weighted design; no normal equations.
    upper = [[0.0] * 5 for _ in columns]
    orthonormal = []
    coefficients = []
    for k, column in enumerate(columns):
        v = list(column)
        for j, q in enumerate(orthonormal):
            upper[j][k] = math.fsum(a * b for a, b in zip(q, v))
            v = [a - upper[j][k] * b for a, b in zip(v, q)]
        upper[k][k] = math.sqrt(math.fsum(a * a for a in v))
        q = [a / upper[k][k] for a in v]
        orthonormal.append(q)
        coefficients.append(math.fsum(a * b for a, b in zip(q, response)))
    for k in reversed(range(5)):
        remainder = math.fsum(upper[k][j] * coefficients[j] for j in range(k + 1, 5))
        coefficients[k] = (coefficients[k] - remainder) / upper[k][k]
    h1 = math.hypot(coefficients[1], coefficients[2])
    h2 = math.hypot(coefficients[3], coefficients[4])
    return 20 * math.log10(h1 / h2)
