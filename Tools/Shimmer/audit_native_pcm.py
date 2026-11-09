#!/usr/bin/env python3
"""Audit every native PCM row against original inputs and independent masked equations."""
import argparse
from collections import Counter
from copy import deepcopy
import math
from pathlib import Path
import uuid

import native_oracle
import pcm_catalog
from shimmer_oracle import MEASUREMENTS, finite
from shimmer_reference import ROOT, HERE, canonical, digest, load_json

FIXTURES = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/ShimmerPCM'


def require(condition, message):
    if not condition: raise ValueError(message)


def same(a, b, message):
    require(canonical(a) == canonical(b), message)


def nearby(actual, expected, message, ulps=8):
    require(finite(actual) and finite(expected), message + ': nonfinite or nonnumeric')
    require(abs(actual - expected) <= ulps * max(math.ulp(actual), math.ulp(expected)), message)


def profile(name, configuration):
    return dict(identifier=dict(name=name, version=1), sha256=digest(canonical(configuration)))


def expected_configuration(case):
    return dict(schemaVersion=1, sampleRate=case['sampleRate'], inputPrecision=case['inputPrecision'],
        arithmeticPrecision='float64', applicability='sustainedPhonation',
        minimumPeriodSeconds=case['minimumPeriodSeconds'], maximumPeriodSeconds=case['maximumPeriodSeconds'],
        maximumAdjacentPeriodFactor=case['maximumAdjacentPeriodFactor'], maximumAmplitudeFactor=case['maximumAmplitudeFactor'],
        definition='hdxl-shimmer-amplitude-statistics-v1', amplitudeDefinition='hannRMSPointTwoNeighborPeriods',
        denominatorDefinition='sourceEligibleSelectedAmplitudesExceptFinalIncludingZeros',
        neighborhoodDefinition='completeConsecutivePositiveAmplitudesWithoutStitching',
        dbDefinition='meanTwentyAbsoluteLog10AdjacentAmplitudeRatio')


def expected_pulse_configuration(case, fixture):
    return dict(schemaVersion=1, sampleRate=case['sampleRate'], inputPrecision=case['inputPrecision'],
        arithmeticPrecision='float64', pitchFloorHz=20, pitchCeilingHz=fixture['f0Contour']['ceilingHz'],
        minimumPeriodSeconds=case['minimumPeriodSeconds'], maximumPeriodSeconds=case['maximumPeriodSeconds'],
        maximumAdjacentPeriodFactor=case['maximumAdjacentPeriodFactor'], support='completeInterval',
        definition='hdxl-acoustic-pulses-waveform-cc-v1', seedDefinition='voicedIntervalMidpointAbsoluteExtremumParabola',
        correlationDefinition='observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak',
        interpolationDefinition='threePointParabolaGeometricRangeFallback', amplitudeDefinition='hannRMSPointTwoNeighborPeriods',
        minimumReliableCurvature=128 * math.ulp(1.), minimumRelativeVariation=64 * math.ulp(1.))


def converted_flags(index, records, upstream, case):
    flags = upstream[index]
    require(type(flags) is int and 0 <= flags < 1 << 18, 'Invalid upstream pulse rejection flags')
    output = 0
    if flags & 1 << 7: output |= 1
    if flags & 1: output |= 1 << 3
    if flags & 1 << 3: output |= 1 << 5
    if flags & ((1 << 2) | (1 << 13)): output |= 1 << 6
    if flags & ((1 << 10) | (1 << 11) | (1 << 12)): output |= 1 << 7
    if flags & ((1 << 8) | (1 << 9) | (1 << 16)): output |= 1 << 1
    if flags or records[index].get('amplitude') is None: output |= 1 << 2
    time = records[index]['timeSeconds']
    if time < 0 or time > case['sampleCount'] / case['sampleRate']: output |= 1 << 3
    if index == 0 or index + 1 == len(records) \
            or records[index - 1]['timeSeconds'] < case['queryStartSeconds'] \
            or records[index + 1]['timeSeconds'] > case['queryEndSeconds']:
        output |= 1 << 6
    return output


def audit_row(row, case):
    name = case['name']
    keys = {'name', 'inputSHA256', 'configuration', 'pulseConfiguration', 'result', 'nativeAmplitudes',
            'upstreamAmplitudeRejections', 'amplitudeComparisons', 'maximumAmplitudeBudgetFraction',
            'directReferenceComparison', 'directComparisonReason', 'maximumStatisticsBudgetFraction'}
    require(isinstance(row, dict) and set(row) == keys and row['name'] == name, 'Wrong native PCM row schema/order')
    fixture = load_json(FIXTURES / (name + '.json'))
    source = pcm_catalog.source(case)
    same(row['inputSHA256'], fixture['inputPCM']['artifactSHA256'], 'Native PCM input identity differs')
    configuration = expected_configuration(case)
    pulse_configuration = expected_pulse_configuration(case, fixture)
    same(row['configuration'], configuration, 'Native shimmer configuration differs')
    same(row['pulseConfiguration'], pulse_configuration, 'Native pulse configuration differs')
    result = row['result']
    result_keys = {'schemaVersion', 'profile', 'applicability', 'dependencyTiming', 'query',
                   'inputProvenance', 'coverage', *MEASUREMENTS}
    require(isinstance(result, dict) and set(result) == result_keys, 'Wrong native PCM result schema')
    same(result['schemaVersion'], 1, 'Native result version differs')
    same(result['applicability'], 'sustainedPhonation', 'Native applicability differs')
    same(result['profile'], profile('hdxl-shimmer-amplitude-statistics-v1-sustainedPhonation', configuration),
         'Native shimmer identity differs')
    contour = dict(schemaVersion=1, sampleRate=case['sampleRate'], sampleCount=case['sampleCount'],
        **{k: fixture['f0Contour'][k] for k in ('firstCenterSeconds', 'stepSeconds', 'ceilingHz', 'frequenciesHz')})
    provenance = dict(kind='acousticPulses',
        amplitudeSourceProfile=profile('hdxl-acoustic-pulses-waveform-cc-v1-completeInterval', pulse_configuration),
        f0ContourIdentity=profile('hdxl-pulse-supplied-f0', contour))
    same(result['inputProvenance'], provenance, 'Native PCM upstream provenance differs')
    query = dict(startSeconds=case['queryStartSeconds'], endSeconds=case['queryEndSeconds'])
    same(result['query'], query, 'Native PCM query differs')
    timing = result['dependencyTiming']
    require(set(timing) == {'source', 'includedSampleCount', 'sourceStartSeconds', 'effectiveDelaySeconds'}, 'Wrong native dependency timing schema')
    epoch = timing['source']['epoch']
    require(isinstance(epoch, dict) and set(epoch) == {'sequence', 'streamID'}, 'Wrong native epoch schema')
    same(epoch['sequence'], 0, 'Native epoch sequence differs')
    uuid.UUID(epoch['streamID'])
    same(timing, dict(source=dict(epoch=epoch, startSample=2 ** 63 - 1 - case['sampleCount'],
        sampleCount=case['sampleCount'], sampleRate=case['sampleRate']), includedSampleCount=case['sampleCount'],
        sourceStartSeconds=20, effectiveDelaySeconds=(case['sampleCount'] / case['sampleRate']) / 2), 'Native dependency timing differs')
    records = row['nativeAmplitudes']
    raw = native_oracle.evaluate(records, query, configuration)
    points = source['fixture']['reference']['data']['pulseTimesSeconds']
    upstream = row['upstreamAmplitudeRejections']
    require(len(records) == len(points) and isinstance(upstream, list) and len(upstream) == len(records), 'Native raw pulse coverage differs')
    for i, (record, time) in enumerate(zip(records, points)):
        same(record['sequenceIndex'], i, 'Native pulse sequence index differs')
        require(abs(record['timeSeconds'] - time) * case['sampleRate'] <= 1e-6, 'Native pulse timing differs')
        same(record['rejections']['rawValue'], converted_flags(i, records, upstream, case), 'Native amplitude rejection conversion differs')
    coverage = result['coverage']
    require(set(coverage) == set(raw['coverage']), 'Native coverage fields differ')
    for key, expected in raw['coverage'].items():
        if isinstance(expected, float): nearby(coverage[key], expected, 'Native coverage differs: ' + key)
        else: same(coverage[key], expected, 'Native coverage differs: ' + key)
    maximum_equation_fraction = 0.
    for key in MEASUREMENTS:
        estimate, expected = result[key], raw['values'][key]
        required = {'variant', 'unit', 'status', 'value' if expected is not None else 'unavailability'}
        require(isinstance(estimate, dict) and set(estimate) == required, 'Native scalar fields/status differ: ' + key)
        same(estimate['variant'], key, 'Native scalar variant differs')
        same(estimate['unit'], 'decibelsRatio' if key == 'db' else 'fraction', 'Native scalar unit differs')
        same(estimate['status'], 'available' if expected is not None else 'unavailable', 'Native scalar availability differs')
        if expected is not None:
            require(finite(estimate['value']) and estimate['value'] >= 0, 'Invalid native scalar value')
            fraction = abs(estimate['value'] - expected) / raw['comparisonBounds'][key]
            require(fraction <= 1, 'Native statistical equation differs: ' + key)
            maximum_equation_fraction = max(maximum_equation_fraction, fraction)
        else:
            require(estimate['unavailability'] in {'insufficientData', 'silence', 'unsupportedRange',
                'discontinuity', 'lowConfidence'}, 'Unexpected PCM unavailable reason')
            if case['pulseFixture'].startswith('silence-'):
                same(estimate['unavailability'], 'silence', 'Silence was relabeled')
    if raw['values']['apq3'] is not None:
        same(result['dda']['value'], 3 * result['apq3']['value'], 'Native DDA/APQ3 relation differs')
    accepted = [records[i] for i in raw['acceptedIndices']]
    external = fixture['reference']['data']['amplitudes']
    by_index = {a['pulseIndex']: a for a in external}
    amplitude_error, amplitude_fraction = 0., 0.
    for record in accepted:
        require(record['sequenceIndex'] in by_index, 'Native accepted an amplitude absent from the reference')
        expected = by_index[record['sequenceIndex']]['rmsAmplitude']
        error = abs(record['amplitude'] - expected)
        fraction = error / (2e-12 + 1e-10 * abs(expected))
        require(fraction <= 1, 'Native PCM amplitude extraction differs')
        amplitude_error, amplitude_fraction = max(amplitude_error, error), max(amplitude_fraction, fraction)
    same(row['amplitudeComparisons'], len(accepted), 'Native amplitude comparison count differs')
    nearby(row['maximumAmplitudeBudgetFraction'], amplitude_fraction, 'Native amplitude audit summary differs')
    same_population = [r['sequenceIndex'] for r in accepted] == [a['pulseIndex'] for a in external]
    continuous = all(a['runID'] == b['runID'] and a['sequenceIndex'] + 1 == b['sequenceIndex'] for a, b in zip(accepted, accepted[1:]))
    oracle = fixture['audit']['equations']
    same_windows = all(len(raw['windows'][str(width)]) == len(oracle[key]) for width, key in (
        (2, 'pairStartIndices'), (3, 'apq3WindowStartIndices'), (5, 'apq5WindowStartIndices'), (11, 'apq11WindowStartIndices')))
    values = fixture['reference']['data']['tierValues']
    direct = values is not None and same_population and continuous and same_windows
    reason = 'identical population and neighborhoods' if direct else 'reference not executed: insufficient pulses' if values is None \
        else 'native source reliability excludes additional amplitudes' if not same_population \
        else 'explicit native run or cycle gaps' if not continuous else 'numerical edge eligibility differs'
    same(row['directReferenceComparison'], direct, 'Native direct-comparison eligibility differs')
    same(row['directComparisonReason'], reason, 'Native comparison reason differs')
    statistic_fraction = 0.
    compared_scalars = 0
    if direct:
        for key in MEASUREMENTS:
            expected, actual = values[key], result[key].get('value')
            require((expected is None) == (actual is None), 'Native combined-reference availability differs')
            if expected is None: continue
            arithmetic = fixture['audit']['statisticalComparison']['bounds'][key]
            if key == 'db':
                minimum = min(a['rmsAmplitude'] for a in external)
                require(minimum > amplitude_error, 'Unbounded dB extraction uncertainty')
                bound = arithmetic + 40 / math.log(10) * amplitude_error / (minimum - amplitude_error)
            else:
                mean = oracle['meanAmplitude']
                require(mean > amplitude_error, 'Unbounded normalization uncertainty')
                bound = arithmetic + ((6 if key == 'dda' else 2) + abs(expected)) * amplitude_error / (mean - amplitude_error)
            fraction = abs(actual - expected) / bound
            require(fraction <= 1, 'Native combined-reference scalar differs: ' + key)
            statistic_fraction = max(statistic_fraction, fraction)
            compared_scalars += 1
    nearby(row['maximumStatisticsBudgetFraction'], statistic_fraction, 'Native statistics audit summary differs')
    return dict(name=name, amplitudeComparisons=len(accepted), directReferenceComparison=direct,
        directComparisonReason=reason, directlyComparedScalars=compared_scalars,
        maximumAmplitudeBudgetFraction=amplitude_fraction, maximumEquationBudgetFraction=maximum_equation_fraction,
        maximumStatisticsBudgetFraction=statistic_fraction)


def audit(rows):
    cases = pcm_catalog.cases()
    require(isinstance(rows, list) and len(rows) == len(cases), 'Incomplete native PCM catalog')
    results = [audit_row(row, case) for row, case in zip(rows, cases)]
    return dict(status='passed', cases=len(results), results=results,
        amplitudeComparisons=sum(r['amplitudeComparisons'] for r in results),
        directlyComparedScalars=sum(r['directlyComparedScalars'] for r in results),
        comparisonReasons=dict(Counter(r['directComparisonReason'] for r in results)),
        maximumAmplitudeBudgetFraction=max(r['maximumAmplitudeBudgetFraction'] for r in results),
        maximumEquationBudgetFraction=max(r['maximumEquationBudgetFraction'] for r in results),
        maximumStatisticsBudgetFraction=max(r['maximumStatisticsBudgetFraction'] for r in results))


def corruption_controls(rows):
    mutations = ['missingRow', 'wrongScalar', 'wrongMeanCount', 'wrongSourceFlag', 'wrongProfile']
    for mutation in mutations:
        changed = deepcopy(rows)
        if mutation == 'missingRow': changed.pop()
        elif mutation == 'wrongScalar': changed[0]['result']['local']['value'] += .25
        elif mutation == 'wrongMeanCount': changed[0]['result']['coverage']['normalizationAmplitudeCount'] += 1
        elif mutation == 'wrongSourceFlag': changed[0]['nativeAmplitudes'][2]['rejections']['rawValue'] = 1
        else: changed[0]['result']['profile']['sha256'] = '0' * 64
        try: audit(changed)
        except ValueError: continue
        raise ValueError('Native audit accepted corruption: ' + mutation)
    return dict(status='passed', rejectedMutations=mutations)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native_report', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--corruption-controls', action='store_true')
    args = parser.parse_args()
    require(not args.native_report.is_symlink() and args.native_report.is_file()
            and args.native_report.stat().st_size <= 32 * 1024 * 1024, 'Unsafe or oversized native report')
    rows = load_json(args.native_report)
    result = audit(rows)
    result['inputSHA256'] = digest(args.native_report.read_bytes())
    sources = [HERE / name for name in ('audit_native_pcm.py', 'native_oracle.py', 'shimmer_oracle.py', 'pcm_catalog.py')]
    sources += [FIXTURES / 'manifest.json', pcm_catalog.PULSES / 'manifest.json', ROOT / 'Tools/Reference/common.py']
    sources += list((ROOT / 'Sources/HDXLVoiceProcessing/Shimmer').glob('*.swift'))
    sources += list((ROOT / 'Sources/HDXLVoiceProcessing/Pulses').glob('*.swift'))
    sources += [ROOT / 'Tests/HDXLVoiceProcessingTests/ShimmerPCMReferenceTests.swift']
    result['sourceHashes'] = {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(sources)}
    if args.corruption_controls: result['corruptionControls'] = corruption_controls(rows)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(canonical(result))
    print('SHIMMER_NATIVE_PCM_AUDIT_PASSED', result['cases'], result['amplitudeComparisons'], result['directlyComparedScalars'], flush=True)
