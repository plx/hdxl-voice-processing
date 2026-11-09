"""Shimmer PCM queries over existing original, independently pinned pulse fixtures."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(1, str(ROOT / 'Tools/Reference'))
from common import canonical, digest, load_json, read_pcm

PULSES = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Pulses'
BASES = ('gaussian-16000-150', 'gaussian-44100-80', 'gaussian-48000-600',
         'sine-150', 'harmonic', 'filtered', 'modulated', 'alternating', 'quiet',
         'inverted', 'noisy-low', 'noisy-high', 'jitter-12pct', 'missing-cycles',
         'unvoiced-gap', 'silence', 'short-321', 'all-unvoiced')


def cases():
    result = []
    for precision in ('float32', 'float64'):
        for base in BASES:
            name = base + '-' + precision
            rate = 44100 if base == 'gaussian-44100-80' else 48000 if base == 'gaussian-48000-600' else 16000
            count = 321 if base == 'short-321' else rate // 2
            end = count * (1 / rate)
            for label, bounds in [('full', (0., end)), ('crop', (.25 * end, .75 * end))]:
                for factor in ((1.6, 10.) if base in ('modulated', 'alternating') else (1.6,)):
                    result.append(dict(schemaVersion=1, name=name + '-' + label + ('-wide-ratio' if factor == 10. else ''),
                        pulseFixture=name, sampleRate=rate, sampleCount=count, inputPrecision=precision,
                        queryStartSeconds=bounds[0], queryEndSeconds=bounds[1],
                        minimumPeriodSeconds=.0001, maximumPeriodSeconds=.02,
                        maximumAdjacentPeriodFactor=1.3, maximumAmplitudeFactor=factor))
    return result


def validate(case):
    if not isinstance(case, dict) or any(type(case.get(k)) is not int for k in ('schemaVersion', 'sampleRate', 'sampleCount')) \
            or canonical(case) not in {canonical(c) for c in cases()}:
        raise ValueError('Unknown or changed canonical shimmer PCM query')


def source(case):
    validate(case)
    manifest = load_json(PULSES / 'manifest.json')
    name = case['pulseFixture']
    files, paths = {}, {}
    for suffix in ('.json', '.wav', '.Pitch'):
        path = PULSES / (name + suffix)
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing or unsafe shimmer PCM source')
        sha = digest(path.read_bytes())
        if sha != manifest['files'][path.name]:
            raise ValueError('Inherited pulse fixture hash differs')
        files[str(path.relative_to(ROOT))] = sha
        paths[suffix] = path
    fixture = load_json(paths['.json'])
    samples, info = read_pcm(paths['.wav'])
    if fixture['case']['source']['kind'] == 'licensedSpeech' or fixture['case']['pitchSource'] != 'suppliedContour':
        raise ValueError('This catalog contains only original synthetic inputs with supplied F0')
    if (info['sampleRate'], info['sampleCount'], info['artifactSHA256']) != (
            fixture['case']['sampleRate'], fixture['case']['sampleCount'], fixture['reference']['inputSHA256']):
        raise ValueError('Inherited shimmer PCM identity differs')
    if (info['sampleRate'], info['sampleCount'], fixture['case']['inputPrecision']) != (
            case['sampleRate'], case['sampleCount'], case['inputPrecision']):
        raise ValueError('Canonical shimmer PCM geometry/precision differs')
    if digest(paths['.Pitch'].read_bytes()) != fixture['reference']['pitchSHA256']:
        raise ValueError('Inherited shimmer F0 identity differs')
    return dict(fixture=fixture, samples=samples, pcm=info, files=files, paths=paths)
