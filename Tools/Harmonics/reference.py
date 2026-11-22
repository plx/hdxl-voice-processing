#!/usr/bin/env python3
"""Original filtered mixtures, pinned whole-period Praat amplitudes and complex transfer gains."""
import argparse
import cmath
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
OUTPUT = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Harmonics/h1-h2.json'
CASES = [
    ('source-a', 16000, 100, 3, [(650, 80), (1700, 130)]),
    ('same-source-different-filter', 16000, 100, 3, [(350, 60), (950, 100)]),
    ('narrow-at-h2', 16000, 80, 5, [(400, 38), (1600, 110)]),
    ('same-poles-wide', 16000, 80, 5, [(400, 130), (1600, 250)]),
    ('low-pitch-short-window', 8000, 90, 3, [(420, 65), (920, 120)]),
    ('off-fft-grid', 44100, 223, 5, [(520, 60), (1390, 115)]),
    ('wideband', 48000, 193, 3, [(550, 90), (1250, 100)]),
    ('high-pitch', 48000, 128, 3, [(780, 120), (1800, 160)]),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def significant(x):
    return float(format(x, '.12g'))


def pole(rate, hz, bw):
    radius = math.exp(-math.pi * bw / rate)
    feedback = 2 * radius * math.cos(2 * math.pi * hz / rate)
    return 1 - feedback + radius**2, feedback, radius**2


def gain_db(coefficients, rate, hz):
    dc, feedback, square = coefficients
    z = cmath.exp(-2j * math.pi * hz / rate)
    return 20 * math.log10(abs(dc / (1 - feedback * z + square * z**2)))


def make_case(name, rate, period, cycles, formants, executable, pin, temp):
    f0 = rate / period
    n = cycles * period
    coeffs = [pole(rate, *pair) for pair in formants]
    # Warm up actual causal sections for whole periods. The measured cut starts
    # in steady state with the same source phase in both filter-comparison cases.
    warm = math.ceil(rate / period) * period
    data = [.01 + .032 * math.sin(2 * math.pi * (i % period) / period + .3)
            + .012 * math.cos(4 * math.pi * (i % period) / period - .4) for i in range(warm+n)]
    for dc, feedback, square in coeffs:
        prev = prev2 = 0
        for i, value in enumerate(data):
            out = dc * value + feedback * prev - square * prev2
            data[i] = out
            prev2, prev = prev, out
    samples = [round(v * 32768) for v in data[warm:]]
    payload = struct.pack('<' + 'h' * n, *samples)
    audio = temp / 'input.wav'
    with wave.open(str(audio), 'wb') as file:
        file.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
        file.writeframes(payload)
    result = subprocess.run([str(executable), *pin['options'], str(HERE/'spectrum.praat'), str(audio), str(cycles)],
                            check=True, capture_output=True, text=True, env={**os.environ, 'LC_ALL': 'C'})
    lines = [line.split('\t') for line in result.stdout.strip().splitlines()]
    if len(lines) != 2 or [row[0] for row in lines] != ['1', '2']:
        raise ValueError('Incomplete Praat spectrum output')
    peaks = [float(row[1]) for row in lines]
    for h, measured in enumerate(peaks, 1):
        dft = 2 / n * abs(sum((v / 32768) * cmath.exp(-2j*math.pi*h*i/period) for i,v in enumerate(samples)))
        if abs(measured - dft) > 1e-12:
            raise ValueError(f'Unexpected Praat amplitude normalization in {name}')
    gains = [[significant(gain_db(c, rate, h*f0)) for h in (1,2)] for c in coeffs]
    corrected = [20*math.log10(value)-sum(row[i] for row in gains) for i,value in enumerate(peaks)]
    return dict(name=name, sourceRate=rate, f0=significant(f0), periodSamples=period, periods=cycles,
                formantsHz=formants, pcm16=samples, pcm16LESHA256=sha(payload),
                sourcePeaksFS=[.032,.012], praatPeaksFS=list(map(significant, peaks)), poleGainsDB=gains,
                correctedDBFS=list(map(significant, corrected)))


def generate(executable):
    pin = json.loads((ROOT/'Tools/Reference/toolchain.json').read_bytes())
    if sha(executable.read_bytes()) != pin['executableSHA256']:
        raise ValueError('Praat executable differs from the pinned reference')
    with tempfile.TemporaryDirectory() as folder:
        rows = [make_case(*case, executable, pin, Path(folder)) for case in CASES]
    return dict(schemaVersion=1, reference=f"Praat {pin['version']}", executableSHA256=pin['executableSHA256'],
                scriptSHA256=sha((HERE/'spectrum.praat').read_bytes()), generatorSHA256=sha(Path(__file__).read_bytes()), cases=rows)


def register():
    path = ROOT / 'Configuration/provenance.json'
    inventory = json.loads(path.read_bytes())
    code = sha(Path(__file__).read_bytes())
    rel = str(OUTPUT.relative_to(ROOT))
    entry = dict(id='harmonics-filtered-h1-h2',path=rel,sha256=sha(OUTPUT.read_bytes()),
                 source=dict(kind='original-generated',url='https://github.com/plx/hdxl-voice-processing/issues/52',versionOrHash=code),
                 generator=dict(path='Tools/Harmonics/reference.py',version='1',sha256=code),
                 redistribution=dict(license='project',permission='inherits-project-license',evidence='https://github.com/plx/hdxl-voice-processing/issues/78'),
                 containsHumanVoice=False,consent=dict(status='not-applicable',evidence='Original synthesized two-harmonic mixtures.'),
                 transformations=['Causal pole-pair filtering, mono PCM16 quantization, pinned Praat Fourier bins and independent complex transfer gains.'],
                 expectedProfile='Peak full-scale F0 and 2F0 amplitudes; digital DC-normalized F1/F2 gains and corrected differences.',
                 referenceOutputIdentity='sha256:'+sha(OUTPUT.read_bytes()))
    inventory['fixtures'] = [row for row in inventory['fixtures'] if row['path']!=rel]+[entry]
    path.write_text(json.dumps(inventory,indent=2,ensure_ascii=False)+'\n')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--write',action='store_true')
    args=parser.parse_args()
    observed=json.dumps(generate(args.executable.resolve()),sort_keys=True,separators=(',',':'),allow_nan=False)+'\n'
    if args.write:
        OUTPUT.parent.mkdir(exist_ok=True)
        OUTPUT.write_text(observed)
        register()
    elif observed!=OUTPUT.read_text():
        raise SystemExit('Harmonic reference observations differ')
    print(f'Verified {len(CASES)} synthetic cases against pinned Praat and the discrete pole model.')
