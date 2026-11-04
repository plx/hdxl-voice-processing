#!/usr/bin/env python3
"""Original direct-definition complex DFT oracle. No Accelerate, FFT, numpy, or native-package imports."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Fourier/oracles.json'
LENGTHS = [2 ** exponent for exponent in range(1, 23)]


def quantize(x, precision):
    return struct.unpack('<f', struct.pack('<f', x))[0] if precision == 'float32' else float(x)


def direct_dft(values, bins=None, inverse=False):
    """sum(x[j] * exp(sign*2*pi*i*j*k/N)); inverse additionally divides by N.

    Full transforms are deliberately bounded at N=128. Larger vectors may request
    at most 16 independent bins. Reducing the integer phase modulo N improves the
    scalar evaluation's trigonometric accuracy; this uses no FFT decomposition.
    """
    n = len(values)
    if not 1 <= n <= 4194304 or (bins is None and n > 128):
        raise ValueError('Unsupported direct-oracle size')
    bins = list(range(n)) if bins is None else list(bins)
    if n > 128 and len(bins) > 16:
        raise ValueError('Too many direct-oracle bins')
    if any(type(k) is not int or not 0 <= k < n for k in bins):
        raise ValueError('Invalid direct-oracle bin')
    if any(not math.isfinite(z.real) or not math.isfinite(z.imag) for z in values):
        raise ValueError('Nonfinite oracle input')
    result = []
    for k in bins:
        real, imag = [], []
        for j, z in enumerate(values):
            phase = (-1 if not inverse else 1) * math.tau * ((j*k) % n) / n
            c, s = math.cos(phase), math.sin(phase)
            real.append(z.real*c - z.imag*s)
            imag.append(z.real*s + z.imag*c)
        divisor = n if inverse else 1
        result.append(complex(math.fsum(real)/divisor, math.fsum(imag)/divisor))
    return result


def noise(n, precision, complex_input, seed=30):
    state = seed
    def sample():
        nonlocal state
        state = (1664525*state + 1013904223) & 0xffffffff
        return quantize((state - 2147483648) / 2147483648, precision)
    return [complex(sample(), sample() if complex_input else 0) for _ in range(n)]


def input_digest(values, precision):
    code = '<ff' if precision == 'float32' else '<dd'
    result = hashlib.sha256()
    block = bytearray()
    for z in values:
        block.extend(struct.pack(code, z.real, z.imag))
        if len(block) >= 65536:
            result.update(block)
            block.clear()
    result.update(block)
    return result.hexdigest()


def pairs(values):
    return [[z.real, z.imag] for z in values]


def make_case(name, kind, values, precision, indices=None, recipe=None):
    n = len(values)
    inverse = kind.endswith('Inverse')
    expected = direct_dft(values, indices, inverse)
    # Forward absolute component error budget = C*u*log2(N)*||x||2.
    # Inverse budgets use ||X||2/N. These are declared acceptance limits, not observed maxima.
    unit = 2**(-24 if precision == 'float32' else -53)
    coefficient = 8 if precision == 'float32' else 64
    norm = math.hypot(*(component for z in values for component in (z.real, z.imag)))
    tolerance = coefficient * unit * math.log2(n) * norm / (n if inverse else 1)
    input_values = values[:n//2+1] if kind == 'realInverse' else values
    return {'name': name, 'kind': kind, 'length': n, 'precision': precision,
            'input': None if recipe else pairs(input_values), 'recipe': recipe,
            'inputSHA256': input_digest(input_values, precision),
            'indices': list(range(n)) if indices is None else indices,
            'expected': pairs(expected), 'maximumAbsoluteError': tolerance}


def generate():
    cases = []
    for precision in ('float32', 'float64'):
        for n in (2, 4, 8, 32):
            tiny = 1e-30 if precision == 'float32' else 1e-200
            real_inputs = {
                'impulse': [1 if j == 0 else 0 for j in range(n)],
                'dc': [0.375]*n,
                'nyquist': [0.5*(-1)**j for j in range(n)],
                'cosine': [math.cos(math.tau*j/n) for j in range(n)],
                'sine': [math.sin(math.tau*j/n) for j in range(n)],
                'off-bin': [0.7*math.sin(math.tau*1.375*j/n + 0.23) for j in range(n)],
                'tiny-dc': [tiny]*n,
                'silence': [0]*n,
            }
            for name, source in real_inputs.items():
                values = [complex(quantize(x, precision), 0) for x in source]
                # All N bins explicitly test Hermitian symmetry independently of real FFT packing.
                cases.append(make_case(name, 'realForward', values, precision))
            for frequency in (1, -1, 1.375):
                values = [complex(quantize(math.cos(math.tau*frequency*j/n), precision),
                                  quantize(math.sin(math.tau*frequency*j/n), precision)) for j in range(n)]
                cases.append(make_case(f'complex-tone-{frequency}', 'complexForward', values, precision))
            values = noise(n, precision, True)
            cases.append(make_case('arbitrary-spectrum', 'complexInverse', values, precision))
            values[0] = complex(values[0].real, 0)
            values[n//2] = complex(values[n//2].real, 0)
            for k in range(1, n//2):
                values[n-k] = values[k].conjugate()
            cases.append(make_case('hermitian-spectrum', 'realInverse', values, precision))
        for n in LENGTHS:
            indices = sorted(set([0, 1, n//4, n//2-1, n//2, n-1]))
            for complex_input in (False, True):
                values = noise(n, precision, complex_input)
                recipe = {'name': 'lcg-v1', 'seed': 30, 'complex': complex_input}
                kind = 'complexForward' if complex_input else 'realForward'
                cases.append(make_case('seeded-noise-selected-bins', kind, values, precision, indices, recipe))
    return {'schemaVersion': 1, 'definition': 'direct negative-exponent forward sum; positive inverse sum divided by N',
            'generatorSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'supportedLengths': LENGTHS,
            'errorBudget': {'float32': '8 * 2^-24 * log2(N) * inputL2Norm / (inverse ? N : 1)',
                            'float64': '64 * 2^-53 * log2(N) * inputL2Norm / (inverse ? N : 1)'},
            'cases': cases}


def register():
    path = ROOT / 'Configuration/provenance.json'
    data = json.loads(path.read_text())
    sha = hashlib.sha256(OUTPUT.read_bytes()).hexdigest()
    generator = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    relative = str(OUTPUT.relative_to(ROOT))
    record = {'id': 'fourier-direct-dft', 'path': relative, 'sha256': sha,
              'source': {'kind': 'original-generated', 'url': 'https://github.com/plx/hdxl-voice-processing/issues/30',
                         'versionOrHash': f'generator-v1-sha256:{generator}'},
              'generator': {'path': 'Tools/Fourier/oracle.py', 'version': '1', 'sha256': generator},
              'redistribution': {'license': 'project', 'permission': 'inherits-project-license',
                                 'evidence': 'https://github.com/plx/hdxl-voice-processing/issues/78'},
              'containsHumanVoice': False,
              'consent': {'status': 'not-applicable', 'evidence': 'Original mathematical vectors; no recordings'},
              'transformations': ['Original scalar direct complex DFT and inverse from mathematical sums',
                                  'Explicit IEEE Float32 rounding of Float32 inputs before scalar evaluation',
                                  'Full small vectors and independently evaluated selected bins for all supported lengths'],
              'expectedProfile': 'fourier-negative-forward-inverse-over-n/v1; explicit length and precision per case',
              'referenceOutputIdentity': f'sha256:{sha}'}
    data['fixtures'] = [x for x in data['fixtures'] if x['path'] != relative] + [record]
    path.write_text(json.dumps(data, indent=2) + '\n')


def verify(stored, fresh):
    # Compare strict metadata and all inputs exactly; tolerate libm's last-place changes in expected sums.
    if stored.keys() != fresh.keys() or len(stored['cases']) != len(fresh['cases']):
        raise ValueError('Oracle structure changed')
    for key in fresh.keys() - {'cases'}:
        if stored[key] != fresh[key]:
            raise ValueError(f'Oracle metadata changed: {key}')
    for saved, new in zip(stored['cases'], fresh['cases']):
        if saved.keys() != new.keys():
            raise ValueError('Case structure changed')
        for key in new.keys() - {'expected'}:
            if saved[key] != new[key]:
                raise ValueError(f'Case metadata/input changed: {new["name"]}/{key}')
        if len(saved['expected']) != len(new['expected']):
            raise ValueError('Oracle output dimensions changed')
        # Much tighter than native transform budgets; relative to the declared input-dependent budget.
        tolerance = new['maximumAbsoluteError'] * (1e-5 if new['precision'] == 'float32' else 0.01)
        for a, b in zip(saved['expected'], new['expected']):
            if len(a) != 2 or any(not math.isfinite(x) or abs(x-y) > tolerance for x,y in zip(a,b)):
                raise ValueError('Scalar regeneration exceeded its tolerance')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Explicitly replace original fixtures and provenance')
    args = parser.parse_args()
    generated = generate()
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(json.dumps(generated, indent=2, allow_nan=False) + '\n')
        register()
    else:
        verify(json.loads(OUTPUT.read_text()), generated)
    print(f'Verified {len(generated["cases"])} independent Fourier oracle cases across {len(LENGTHS)} lengths')


if __name__ == '__main__':
    main()
