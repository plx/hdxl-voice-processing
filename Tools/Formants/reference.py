#!/usr/bin/env python3
"""Regenerate parallel keep-all and edge-filtered Praat observations on identical PCM."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FIXTURES = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures'
OUTPUT = FIXTURES / 'Formants/burg.json'
CORPUS = FIXTURES / 'Corpus'
POLES = [(550, 70), (1480, 110), (2550, 170), (3450, 210), (4250, 255)]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def synthetic(rate, frequencies, f0, tilt, noise):
    """Original cascade of pole pairs, driven by periodic impulses or deterministic noise."""
    state = 46001
    phase = 1.0
    previous = 0.0
    output = []
    for _ in range(rate // 5):
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        random = state / 2**31 - 1
        excitation = random if f0 is None else float(phase >= 1) + noise * random
        phase = (phase % 1) + (f0 or 0) / rate
        previous = excitation + tilt * previous
        output.append(previous)
    for frequency, bandwidth in frequencies:
        radius = math.exp(-math.pi * bandwidth / rate)
        feedback = 2 * radius * math.cos(2 * math.pi * frequency / rate)
        prior = previous = 0.0
        for i, x in enumerate(output):
            y = x + feedback * previous - radius**2 * prior
            output[i] = y
            prior, previous = previous, y
    scale = 26000 / max(map(abs, output))
    return [round(scale * x) for x in output]


def read_cases():
    cases = [
        ('five-pole-pairs', 10000, 5000, 10, 10, POLES, None, 0, 0),
        ('low-f0', 16000, 5500, 10, 5, POLES, 105, 0, .002),
        ('high-f0', 16000, 5500, 10, 5, POLES, 385, 0, .002),
        ('close-resonances', 16000, 6000, 12, 10, [(550, 70), (1390, 75), (1560, 80), *POLES[-2:]], 115, 0, .003),
        ('strong-tilt', 16000, 5000, 8, 10, POLES[:4], 95, .95, .01),
        ('noisy-excitation', 48000, 6000, 16, 5, POLES, 135, .25, .65),
        ('white-noise', 16000, 5500, 10, 10, [], None, 0, 0),
    ]
    for name, rate, ceiling, order, hop, poles, f0, tilt, noise in cases:
        samples = synthetic(rate, poles, f0, tilt, noise)
        yield dict(name=name, sampleRate=rate, ceilingHz=ceiling, order=order, hopMilliseconds=hop,
                   imposedPolePairsHz=poles, f0Hz=f0, excitationTilt=tilt, noiseMix=noise,
                   syntheticPCM16=samples), samples
    manifest = json.loads((CORPUS / 'manifest.json').read_bytes())
    for name, ceiling, order in [('corpus-bl01-vowel-a', 5000, 10), ('corpus-bl02-vowel-i', 5500, 12),
                                 ('corpus-bl03-consonant-rich', 6000, 16)]:
        row = next(x for x in manifest['fixtures'] if x['id'] == name)
        path = CORPUS / row['path']
        if sha(path.read_bytes()) != row['sha256']:
            raise ValueError(f"Corpus source hash differs for {name}")
        with wave.open(str(path)) as reader:
            rate = reader.getframerate()
            if reader.getnchannels() != 1 or reader.getsampwidth() != 2:
                raise ValueError(f"Expected mono PCM16 for {name}")
            start = rate // 2
            reader.setpos(start)
            samples = [v[0] for v in struct.iter_unpack('<h', reader.readframes(rate // 5))]
        if len(samples) != rate // 5:
            raise ValueError(f"Truncated corpus excerpt for {name}")
        yield dict(name=name, sampleRate=rate, ceilingHz=ceiling, order=order, hopMilliseconds=10,
                   corpusPath=row['path'], corpusSHA256=row['sha256'], sourceOffset=start), samples


def parse(output, ceiling, order):
    lines = iter(output.splitlines())

    def fields(tag, count):
        line = next(lines, '').split('\t')
        if len(line) != count + 1 or line[0] != tag:
            raise ValueError(f'Expected {tag} with {count} fields')
        return line[1:]

    passes = []
    for pass_number in (1, 2):
        index, count = map(int, fields('pass', 2))
        if index != pass_number or not 0 < count <= 100:
            raise ValueError('Invalid reference pass')
        frames = []
        for index in range(1, count + 1):
            number, time, size = fields('frame', 3)
            time, size = float(time), int(size)
            if (int(number) != index or not math.isfinite(time) or time < 0
                    or frames and time <= frames[-1]['centerSeconds'] or not 0 <= size <= order):
                raise ValueError('Invalid frame geometry')
            poles = []
            for j in range(1, size + 1):
                number, frequency, bandwidth = fields('pole', 3)
                frequency, bandwidth = float(frequency), float(bandwidth)
                if (int(number) != j or not 0 <= frequency <= ceiling or not 0 <= bandwidth < math.inf
                        or poles and frequency < poles[-1][0] - 1e-8):
                    raise ValueError('Invalid pole or rank order')
                poles.append([frequency, bandwidth])
            frames.append(dict(centerSeconds=time, polesHz=poles))
        passes.append(frames)
    if next(lines, None) is not None:
        raise ValueError('Extra reference output')

    result = []
    for raw, selected in zip(*passes, strict=True):
        if raw['centerSeconds'] != selected['centerSeconds']:
            raise ValueError('Reference grids differ')
        # The CLI interpolates queries at its printed frame time. Allow its sub-Hz rounding
        # while requiring a distinct physical candidate for each selected rank.
        remaining = raw['polesHz'].copy()
        for f, b in selected['polesHz']:
            match = next((i for i, (c, d) in enumerate(remaining)
                          if abs(f - c) <= 1e-6 and abs(b - d) <= 1e-6), None)
            if match is None or not 50 - 1e-6 <= f <= ceiling - 50 + 1e-6:
                raise ValueError('Selected pole is absent from the admissible raw candidates')
            remaining.pop(match)
        result.append(dict(centerSeconds=raw['centerSeconds'], candidatesHz=raw['polesHz'],
                           selectedHz=selected['polesHz']))
    return result


def generate(executable):
    pin = json.loads((ROOT / 'Tools/Reference/toolchain.json').read_bytes())
    if sha(executable.read_bytes()) != pin['executableSHA256']:
        raise ValueError('Praat executable differs from pin')
    cases = []
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'source.wav'
        for row, samples in read_cases():
            raw = struct.pack(f'<{len(samples)}h', *samples)
            with wave.open(str(path), 'wb') as writer:
                writer.setparams((1, 2, row['sampleRate'], 0, 'NONE', 'uncompressed'))
                writer.writeframes(raw)
            args = [str(row['hopMilliseconds'] / 1000), str(row['order']), str(row['ceilingHz']), '0.025', '50']
            output = subprocess.check_output(
                [executable, *pin['options'], HERE / 'reference.praat', path, *args],
                text=True, env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
            row.update(sampleCount=len(samples), pcm16LESHA256=sha(raw), arguments=args,
                       frames=parse(output, row['ceilingHz'], row['order']))
            cases.append(row)
    return dict(schemaVersion=1, praat=pin['version'], executableSHA256=pin['executableSHA256'],
                scriptSHA256=sha((HERE / 'reference.praat').read_bytes()), effectiveWindowSeconds=.025,
                preEmphasisFromHz=50, implementationSHA256=sha(Path(__file__).read_bytes()), cases=cases)


def register():
    path = ROOT / 'Configuration/provenance.json'
    inventory = json.loads(path.read_bytes())
    relative = str(OUTPUT.relative_to(ROOT))
    code = sha(Path(__file__).read_bytes())
    digest = sha(OUTPUT.read_bytes())
    entry = dict(
        id='burg-formant-reference-v1', path=relative, sha256=digest,
        source=dict(kind='original-generated', url='https://github.com/plx/hdxl-voice-processing/issues/46',
                    versionOrHash=code),
        generator=dict(path='Tools/Formants/reference.py', version='1', sha256=code),
        redistribution=dict(license='project', permission='inherits-project-license',
                            evidence='https://github.com/plx/hdxl-voice-processing/issues/78'),
        containsHumanVoice=False,
        consent=dict(status='not-applicable', evidence='Contains synthetic integers and numerical measurements only. '
                     'Measured corpus sources retain their existing PVQD attribution and consent records.'),
        transformations=['Independent all-pole synthesis and quantization to mono PCM16.',
                         'Pinned Praat 7.0.02 keep-all and Burg formants on identical PCM, including bounded '
                         'PVQD slices with source hashes in the corpus manifest.'],
        expectedProfile='Untracked Burg formants. Per-case order, ceiling, hop, conditioning and source coordinates are serialized.',
        referenceOutputIdentity='sha256:' + digest)
    inventory['fixtures'] = [item for item in inventory['fixtures'] if item['path'] != relative] + [entry]
    path.write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    generated = generate(args.executable.resolve())
    encoded = json.dumps(generated, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n'
    if args.write:
        OUTPUT.parent.mkdir(exist_ok=True)
        OUTPUT.write_text(encoded)
        register()
    elif OUTPUT.read_text() != encoded:
        raise SystemExit('Formant observations differ from the registered fixture')
    frames = sum(len(row['frames']) for row in generated['cases'])
    print(f"Verified {len(generated['cases'])} cases and {frames} paired frame observations")
