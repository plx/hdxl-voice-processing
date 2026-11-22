#!/usr/bin/env python3
"""Measure formant conditioning, predictor, roots and the complete PCM-facing API."""
import hashlib
import itertools
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from SpectralProducts.benchmark import SpectralBenchmarkSuite, main

BOUNDARIES = {
    'Resample': 'Resample one preloaded 100 ms interval in the production conditioner, excluding pre-emphasis.',
    'Burg': 'Normalize, apply the Burg Gaussian and fit one conditioned 50 ms frame. Consume prediction gain.',
    'Roots': 'Solve one known stable polynomial of the configured order and consume convergence diagnostics.',
    'CloseRoots': 'Solve a known stable polynomial with its two lowest resonances 12 Hz apart.',
    'BoundedExit': 'Constrain the production solver to one sweep per start on the close-resonance polynomial. Consume the verified failure.',
    'Analyze': 'Analyze one independent 100 ms PCM interval, including conditioning, all frame estimates and one scalar per emitted frame.',
}


def validate_cases(records):
    expected = set(itertools.product((16000, 44100, 48000), (5000, 5500, 6000), (8, 10, 12, 16), (5, 10)))
    seen = set()
    for item in records:
        profile = item['profile']
        key = tuple(profile[k] for k in ('sourceSampleRate', 'ceilingHz', 'order', 'hopMilliseconds'))
        rate, ceiling, order, hop = key
        if key not in expected or key in seen or item['name'] != f'r{rate}-c{ceiling}-o{order}-h{hop}':
            raise ValueError(f'Invalid or duplicate Burg benchmark case {key}')
        expected_profile = dict(sourceSampleRate=rate, ceilingHz=ceiling, order=order, hopMilliseconds=hop,
                                inputPrecision='float64', declaredBandwidthHz=rate // 2, preEmphasisFromHz=50)
        encoded = json.dumps(expected_profile, sort_keys=True, separators=(',', ':')).encode()
        identity = dict(identifier=dict(name='burg-formants-untracked', version=1),
                        sha256=hashlib.sha256(encoded).hexdigest())
        if profile != expected_profile or item['profileIdentity'] != identity:
            raise ValueError(f'Invalid Burg profile identity for {key}')
        target = 2 * ceiling
        duration = (target // 10) * (1 / target)
        count = 1 + math.floor((duration - .05) / (hop / 1000))
        source = dict(epoch=dict(streamID='00000000-0000-0000-0000-000000000046', sequence=0),
                      startSample=0, sampleCount=rate // 10, sampleRate=rate)
        if (item['source'] != source or item['durationSeconds'] != .1 or item['windowSamples'] != target // 20
                or item['expectedFrames'] != count):
            raise ValueError(f'Invalid Burg interval or frame geometry for {key}')
        seen.add(key)
    if seen != expected:
        raise ValueError('Incomplete Burg formant matrix')


def throughput(op, item, wall):
    if op == 'Analyze':
        count, unit, seconds = item['expectedFrames'], 'frames', item['durationSeconds']
    elif op == 'Resample':
        count, unit, seconds = item['source']['sampleCount'], 'source samples', item['durationSeconds']
    elif op == 'Burg':
        count, unit, seconds = 1, 'frames', .05
    elif op in ('Roots', 'CloseRoots', 'BoundedExit'):
        count, unit, seconds = 1, 'polynomials', 0
    else:
        raise ValueError(f'Unknown formant operation {op}')
    return dict(unit=unit, itemsPerTrial=count, sourceSeconds=seconds,
                itemsPerSecondAtP50Latency=count * 1e9 / wall['p50'],
                itemsPerSecondAtP99Latency=count * 1e9 / wall['p99'])


SUITE = SpectralBenchmarkSuite(
    'FormantBenchmarks', 'BurgFormants', 'Capability.BurgFormantsAllocationARC',
    'burg-formants', 'FormantWorkloadCheck', BOUNDARIES, validate_cases, throughput,
    'Binary64 mono PCM, deterministic LCG noise plus a 31-sample sinusoid. Explicit stable pole pairs for root cases.',
    'Prepare reusable plans, signals, test polynomials and input buffers before measurement. Verify stage results afterward.',
    'One 100 ms interval, one conditioned 50 ms frame or one polynomial per observation, according to the operation.',
    kernel_stages=True, minimum_trials=101)

if __name__ == '__main__':
    main(SUITE)
