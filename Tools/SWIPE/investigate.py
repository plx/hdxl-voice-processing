#!/usr/bin/env python3
"""Reproduce the pre-native pure-tone bias investigation; never promote goldens."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform

from swipe_analytic import exact_spectrum_estimate
from swipe_oracle import PreparedOracle, configuration

ROOT = Path(__file__).resolve().parents[2]


def investigate():
    rows = []
    for rate in (16000, 44100, 48000):
        for floor, ceiling in ((50., 700.), (25., 2000.)):
            analyzer = PreparedOracle(configuration(rate=rate, floor=floor, ceiling=ceiling))
            count = analyzer.layout['requiredSampleCount']
            for k in range(19):
                frequency = floor * 2 ** (.2 + k * math.log2(ceiling / floor) / 20)
                for phase in (0., .73):
                    samples = [.5 * math.sin(2 * math.pi * frequency * j / rate + phase)
                               for j in range(count)]
                    result = analyzer.frame(samples)
                    rows.append({'sampleRate': rate, 'floorHz': floor, 'ceilingHz': ceiling,
                                 'targetHz': frequency, 'phase': phase,
                                 'frequencyHz': result['frequencyHz'], 'status': result['status'],
                                 'cents': 1200 * math.log2(result['frequencyHz'] / frequency)})
            print(f'{rate} Hz, {floor:g}–{ceiling:g} Hz complete', flush=True)
    analytic = []
    for rate, floor, ceiling, frequency in (
            (16000, 50., 700., 123.45), (16000, 50., 700., 440.),
            (16000, 25., 2000., 106.9234599991188), (44100, 50., 700., 165.05444239489884)):
        analyzer = PreparedOracle(configuration(rate=rate, floor=floor, ceiling=ceiling))
        estimate, strength, _ = exact_spectrum_estimate(analyzer, frequency)
        analytic.append({'sampleRate': rate, 'floorHz': floor, 'ceilingHz': ceiling,
                         'targetHz': frequency, 'frequencyHz': estimate, 'strength': strength,
                         'cents': 1200 * math.log2(estimate / frequency)})
    sources = ['Tools/SWIPE/' + name for name in
               ('swipe_math.py', 'swipe_oracle.py', 'swipe_analytic.py', 'investigate.py', 'README.md')]
    return {'schemaVersion': 1, 'purpose': 'profile investigation, not native parity evidence',
            'pythonVersion': platform.python_version(), 'originalContractCommit': '1905674',
            'sourceSHA256': {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in sources},
            'originalQualityGoalCents': 10., 'frameCount': len(rows),
            'originalGoalFailureCount': sum(abs(x['cents']) > 10 for x in rows),
            'maximumAbsoluteCents': max(abs(x['cents']) for x in rows),
            'unvoicedCount': sum(x['status'] != 'voiced' for x in rows),
            'discreteProfile': rows, 'analyticSpectrumSubstitution': analytic,
            'limitation': 'Analytic substitution shares kernels/blending/refinement; it independently checks only the spectral path.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    if not output.is_relative_to((ROOT / '.build').resolve()) or output.exists():
        raise ValueError('Write a new investigation report below .build')
    report = investigate()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n')
    print({key: report[key] for key in ('frameCount', 'originalGoalFailureCount', 'maximumAbsoluteCents', 'unvoicedCount')})
