#!/usr/bin/env python3
"""Measure the raw fit, supplied correction, dependencies and complete pitch/LPC/harmonic path."""
import hashlib
import itertools
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Harmonics.reference import gain_db, pole
from SpectralProducts.benchmark import SpectralBenchmarkSuite, main

BOUNDARIES = {
    'RawFit': 'Fit DC, H1 and H2 to the original PCM using the precomputed YIN result; publish raw amplitudes and difference.',
    'SuppliedCorrection': 'Apply the two measured pole pairs to the precomputed raw frame; publish individual gains and corrected amplitudes.',
    'YINAndBurg': 'Compute voiced YIN on 50 ms of PCM and fit a full Burg frame with that exact observation.',
    'Complete': 'Compute YIN, fit pitch-qualified Burg poles, fit raw amplitudes and apply correction to one complete 50 ms input.',
}


# Digests of little-endian PCM16 before exact widening to binary64.
# The fit-window variants use identical PCM at a given rate and first resonance.
PCM16_DIGESTS = {
    (16000, 291): '5d36d4601391f8e33b45094e9de91f14d7865ba754691330fdbcd95c565b9af2',
    (16000, 640): '86211a99a006f20309b5ad4c39678eb8056175bc02ec63356c13c77034e571da',
    (44100, 291): 'f2c30b26dc59e4f1dc251dbf8e719f4d64aeae42445633c840bf0f286e81c986',
    (44100, 640): '32b2ff975add299c26955942a9d5fff7610c26d3d481e5837ae6310affe1d2c0',
    (48000, 291): 'bde6f6f6f30fb409963f19c7b6ad574570d4879ad5aac94eb53b0c6d781852d3',
    (48000, 640): 'd749580ebd60fe6764e275e4b775595e678ff3d8da367a5b6dc489272e75788b',
}


def identity(recipe, name):
    encoded = json.dumps(recipe, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
    return dict(identifier=dict(name=name, version=1), sha256=hashlib.sha256(encoded).hexdigest())


def expected_configuration(rate, cycles, geometry):
    yin = dict(schemaVersion=1, definition='hdxl-yin-fixed-time-2002-steps2to5', sampleRate=rate,
               inputPrecision='float64', arithmeticPrecision='float64', pitchFloorHz=80, pitchCeilingHz=450,
               integrationLength=rate // 20 - math.ceil(rate / 80) - 1, hopLength=rate // 100, threshold=.1,
               silenceRMSThreshold=1e-7, differenceBackend='fft', partialWindowPolicy='emitUnavailable',
               rangeBoundaryToleranceSamples=2e-6, interpolation='cmndOrdinateRawDifferencePeriod',
               supportPolicy='fixedIntegrationPlusMaximumLagAndNeighbor', normalization='observedPeak',
               neighboringTimeRefinement='disabled')
    raw = dict(schemaVersion=1, sourceSampleRate=rate, inputPrecision='float64', declaredBandwidthHz=rate // 2,
               periods=cycles, pitchProfile=identity(yin, yin['definition']),
               pitchAlgorithm=dict(name=yin['definition'], version=1), pitchRecipe=dict(kind='yin', recipe=yin))
    formants = dict(schemaVersion=1, sourceSampleRate=rate, inputPrecision='float64', declaredBandwidthHz=rate // 2,
                    order=10, ceilingHz=5000, hopMilliseconds=10, preEmphasisFromHz=50)
    corrected = dict(schemaVersion=1, fit=raw, formants=formants)
    source = dict(epoch=dict(sequence=0, streamID='00000000-0000-0000-0000-000000000052'),
                  startSample=0, sampleCount=rate // 20, sampleRate=rate)
    return dict(name=f'r{rate}-p{cycles}-{geometry}', source=source, yin=yin, profile=corrected,
                excitationHz=137.3, firstResonanceHz=291 if geometry == 'near' else 640,
                rawIdentity=identity(raw, 'h1-h2-joint-hann'),
                correctedIdentity=identity(corrected, 'h1-h2-iseli-measured-f1-f2'))


def validate_cases(rows):
    expected = {}
    for axes in itertools.product((16000, 44100, 48000), (3, 5), ('ordinary', 'near')):
        configuration = expected_configuration(*axes)
        expected[configuration['name']] = configuration
    seen = set()
    for row in rows:
        name = row['name']
        case = row['configuration']
        if name not in expected or name in seen or case != expected[name]:
            raise ValueError(f'Unexpected or repeated harmonic configuration {name}')
        seen.add(name)
        rate = case['source']['sampleRate']
        cycles = case['profile']['fit']['periods']
        if row['pcm16LESHA256'] != PCM16_DIGESTS[rate, case['firstResonanceHz']]:
            raise ValueError(f'Unexpected synthetic PCM in {name}')
        f0 = row['measuredPitchHz']
        if not abs(f0 - 137.3) < 3 or row['windowSamples'] != math.floor(cycles * rate / f0 + .5):
            raise ValueError(f'Unexpected observed pitch or fit window in {name}')
        gains = row['contributions']
        if [p['number'] for p in gains] != [1, 2] or gains[0]['nearResonance'] != (case['firstResonanceHz'] == 291):
            raise ValueError(f'Missing qualified pole pair or near-resonance coverage in {name}')
        previous_frequency = 0
        for contribution in gains:
            frequency, bandwidth = contribution['frequencyHz'], contribution['bandwidthHz']
            if not previous_frequency < frequency < 5000 or not 0 < bandwidth < rate / 2:
                raise ValueError(f'Invalid measured pole in {name}')
            previous_frequency = frequency
            near = min(abs(frequency - f0), abs(frequency - 2 * f0)) <= bandwidth / 2
            coefficients = pole(rate, frequency, bandwidth)
            if (contribution['nearResonance'] != near
                    or not math.isclose(contribution['firstGainDB'], gain_db(coefficients, rate, f0), abs_tol=1e-8)
                    or not math.isclose(contribution['secondGainDB'], gain_db(coefficients, rate, 2 * f0), abs_tol=1e-8)):
                raise ValueError(f'Inconsistent measured pole response in {name}')
        if not all(math.isfinite(row[k]) for k in ('rawDB', 'correctedDB')):
            raise ValueError(f'Nonfinite harmonic observation in {name}')
        calculated = row['rawDB'] + sum(p['secondGainDB'] - p['firstGainDB'] for p in gains)
        if not math.isclose(calculated, row['correctedDB'], rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError(f'Inconsistent raw and corrected readouts in {name}')
    if seen != expected.keys():
        raise ValueError('Incomplete harmonic benchmark matrix')


def throughput(op, item, wall):
    if op not in BOUNDARIES:
        raise ValueError(f'Unknown harmonic stage {op}')
    return dict(framesPerTrial=1, sourceSeconds=.05, fitWindowSamples=item['windowSamples'],
                framesPerSecondAtP50Latency=1e9 / wall['p50'], framesPerSecondAtP99Latency=1e9 / wall['p99'])


def comparisons(data, records, mode):
    metrics = ('wallClock', 'cpuTotal') if mode == 'timing' else ('mallocCountTotal', 'mallocBytesCount')
    rows = []
    for record in records:
        name = record['name']
        complete = data[f'HarmonicDifference.Complete.{name}']
        dependencies = data[f'HarmonicDifference.YINAndBurg.{name}']
        for metric in metrics:
            total = complete[metric]['p50']
            baseline = dependencies[metric]['p50']
            rows.append(dict(case=name, metric=metric, completeMedian=total, dependencyMedian=baseline,
                             differenceOfTrialMediansPerFrame=total - baseline))
    return rows


SUITE = SpectralBenchmarkSuite(
    'HarmonicBenchmarks','HarmonicDifference','Capability.HarmonicDifferenceAllocationARC',
    'harmonic-difference','HarmonicWorkloadCheck',BOUNDARIES,validate_cases,throughput,
    'Deterministic mono binary64 voiced excitation through four causal resonances, quantized to pinned PCM16 before exact widening. F0 is off the 50 ms Fourier grid.',
    'Prepare signals, workers, supplied dependencies and reference results before timing. Clear outputs before, verify exact frames afterward.',
    'One independent 50 ms PCM frame or its precomputed fit and pole dependencies, according to the operation.',
    comparisons=comparisons, minimum_trials=101)

if __name__ == '__main__':
    main(SUITE)
