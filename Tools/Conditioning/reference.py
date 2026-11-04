#!/usr/bin/env python3
"""Pinned external resampling and independent raw pre-emphasis fixtures, never native-generated."""
import argparse
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUTPUT = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Conditioning/praat.json'
sys.path.insert(0, str(ROOT / 'Tools/Reference'))
from common import canonical, pcm_wave
from setup import verify_tool


def sha(data):
    return hashlib.sha256(data).hexdigest()


def implementation_hash():
    paths = ['Tools/Conditioning/reference.py', 'Tools/Conditioning/reference.praat',
             'Tools/Reference/common.py', 'Tools/Reference/setup.py', 'Tools/Reference/toolchain.json']
    return sha(canonical({p: sha((ROOT / p).read_bytes()) for p in paths}))


def rounded(value, precision):
    return struct.unpack('<f', struct.pack('<f', value))[0] if precision == 'float32' else float(value)


def samples(recipe, precision):
    if precision not in ('float32', 'float64'):
        raise ValueError('Unsupported precision')
    n, rate, kind = recipe['count'], recipe['rate'], recipe['kind']
    if type(n) is not int or not 1 <= n <= 2_880_000 or type(rate) is not int or not 4000 <= rate <= 192000:
        raise ValueError('Unsupported original input recipe')
    state = recipe.get('seed', 31)
    result = []
    for j in range(n):
        if kind == 'explicit': value = recipe['values'][j]
        elif kind == 'impulse': value = 0.5 if j == n // 2 else 0.0
        elif kind == 'dc': value = 0.25
        elif kind == 'step': value = 0.0 if j < n // 2 else 0.5
        elif kind == 'tone': value = 0.5 * math.sin(math.tau * recipe['frequency'] * j / rate + 0.23)
        elif kind == 'sweep':
            t = j / rate
            duration = n / rate
            phase = math.tau * (0.35 * rate * t + 0.5 * 0.14 * rate / duration * t * t)
            value = 0.5 * math.sin(phase)
        elif kind == 'noise':
            state = (1664525 * state + 1013904223) & 0xffffffff
            value = (state - 2147483648) / 4294967296
        else: raise ValueError('Unknown original input recipe')
        value *= recipe.get('gain', 1.0)
        if not math.isfinite(value) or abs(value) > 1:
            raise ValueError('Invalid original sample')
        result.append(rounded(value, precision))
    return result


def input_hash(values, precision):
    digest = hashlib.sha256()
    code = '<f' if precision == 'float32' else '<d'
    block = bytearray()
    for value in values:
        block.extend(struct.pack(code, value))
        if len(block) >= 65536:
            digest.update(block); block.clear()
    digest.update(block)
    return digest.hexdigest()


def raw_pre_emphasis(value, previous, frequency, rate, index):
    """Published raw one-zero filter; first sample unchanged. No peak normalization."""
    if frequency is None or index == 0:
        return value
    return value - math.exp(-math.tau * frequency / rate) * previous


def parse(raw):
    lines = [line.split('\t') for line in raw.splitlines()]
    if not lines or len(lines[0]) != 6 or lines[0][0] != 'axis':
        raise ValueError('Missing reference axis')
    count, rate, start, end, first = map(float, lines[0][1:])
    if not all(math.isfinite(v) for v in (count, rate, start, end, first)) or not count.is_integer() or not 1 <= count <= 5_760_000 or rate <= 0 or start != 0 or end <= start:
        raise ValueError('Invalid reference axis')
    count = int(count)
    wanted = list(range(count)) if count <= 4096 else [(count - 1) * j // 63 for j in range(64)]
    indices, values, previous = [], [], []
    for row in lines[1:]:
        if len(row) != 4 or row[0] != 'sample':
            raise ValueError('Malformed reference sample')
        index = int(row[1])
        value, predecessor = map(float, row[2:])
        if not math.isfinite(value) or not math.isfinite(predecessor) or index == 0 and predecessor != 0:
            raise ValueError('Invalid reference sample')
        indices.append(index); values.append(value); previous.append(predecessor)
    if indices != wanted:
        raise ValueError('Missing, duplicate, reordered, or extra reference samples')
    return {'sampleCount': count, 'sampleRate': rate, 'domainStartSeconds': start,
            'domainEndSeconds': end, 'firstSampleCenterSeconds': first,
            'indices': indices, 'resampled': values, 'previousResampled': previous}


def recipes():
    matrix = []
    def add(name, recipe, target, depth=50, frequency=50.0):
        matrix.append({'name': name, 'inputRecipe': recipe, 'targetRate': target,
                       'interpolationDepth': depth, 'preEmphasisFromHz': frequency})
    for rate in (16000, 44100, 48000):
        for target in (10000, 11000, 16000):
            for kind in ('impulse', 'dc', 'step', 'passband', 'upperband', 'sweep', 'noise'):
                recipe = {'kind': kind, 'count': 257, 'rate': rate}
                if kind in ('passband', 'upperband'):
                    recipe.update(kind='tone', frequency=1500 if kind == 'passband' else min(0.65 * target, 0.45 * rate))
                add(f'matrix-{rate}-{target}-{kind}', recipe, target)
    for n, target, depth in [(1,22050,50), (2,22050,50), (3,22050,50), (7,22050,2),
                             (7,22050,3), (7,22050,50), (7,22050,1), (7,32000,50),
                             (257,32000,50), (257,16001,50), (257,16001,128),
                             (4,10000,50), (12,10000,50), (20,10000,50)]:
        add(f'edge-{n}-{target}-d{depth}', {'kind':'noise','count':n,'rate':16000}, target, depth)
    explicit = [0.25, 0.5, -0.125, 0.75, 0.1, -0.3, 0.2]
    for frequency in (None, 0.0, 50.0, 5000.0):
        add(f'preemphasis-{frequency}', {'kind':'explicit','count':len(explicit),'rate':16000,'values':explicit},16000,50,frequency)
    for gain in (0.5, 1.0):
        add(f'gain-{gain}', {'kind':'noise','count':513,'rate':44100,'gain':gain},10000)
    for rate in (16000,44100,48000):
        for kind, frequency in [('passband',1500),('stopband',6500)]:
            add(f'response-{rate}-{kind}', {'kind':'tone','count':rate//4,'rate':rate,'frequency':frequency},10000,50,None)
        add(f'long-60s-{rate}', {'kind':'noise','count':rate*60,'rate':rate},10000)
    return matrix


def generate(tool):
    lock = json.loads((ROOT / 'Tools/Reference/toolchain.json').read_text())
    if platform.python_version() != lock['pythonVersion']:
        raise ValueError('Python version differs from the pinned reference environment')
    binary = verify_tool(tool, lock)
    cases = []
    with tempfile.TemporaryDirectory(prefix='conditioning-') as directory:
        wave = Path(directory) / 'input.wav'
        def reference(values, rate, target, depth, menu_frequency=-1):
            wave.write_bytes(pcm_wave(values, rate))
            command = [str(binary), *lock['options'], str(HERE / 'reference.praat'), str(wave), str(target), str(depth), str(menu_frequency)]
            result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=120,
                                    env={**os.environ,'LC_ALL':'C','LANG':'C'})
            if result.returncode or result.stderr.strip() or len(result.stdout.encode()) > 2*1024*1024:
                raise ValueError('Pinned reference failed, warned, or exceeded export budget')
            return parse(result.stdout), sha(result.stdout.encode())
        for precision in ('float32','float64'):
            for item in recipes():
                source = samples(item['inputRecipe'], precision)
                data, raw_hash = reference(source,item['inputRecipe']['rate'],item['targetRate'],item['interpolationDepth'])
                data['conditioned'] = [raw_pre_emphasis(x,p,item['preEmphasisFromHz'],item['targetRate'],i)
                                       for i,x,p in zip(data['indices'],data['resampled'],data['previousResampled'])]
                cases.append({**item,'precision':precision,'input':source if len(source)<=2048 else None,
                              'inputSHA256':input_hash(source,precision),'referenceOutputSHA256':raw_hash,
                              'maximumAbsoluteError':2e-5 if precision=='float32' else max(2e-12, 32*math.ulp(1.0)*len(source)),
                              'maximumAxisErrorSeconds':1e-12,'expected':data})
                print(f'reference {precision} {item["name"]}', flush=True)
        menu_source = samples({'kind':'explicit','count':7,'rate':16000,'values':[.25,.5,-.125,.75,.1,-.3,.2]},'float64')
        menu, menu_hash = reference(menu_source,16000,16000,50,50)
        raw_values = [raw_pre_emphasis(x,menu_source[i-1] if i else 0,50,16000,i) for i,x in enumerate(menu_source)]
        scale = .99 / max(map(abs, raw_values))
        if max(abs(x-y*scale) for x,y in zip(menu['resampled'],raw_values)) > 1e-14:
            raise ValueError('Menu normalization calibration changed')
    return {'schemaVersion':1,'referenceToolchain':lock,'generatorSHA256':implementation_hash(),
            'definition':'Pinned Praat resampling followed by an independent published raw pre-emphasis equation; no peak normalization in the pipeline',
            'referencePrecision':'float64 on precision-rounded source PCM',
            'menuCalibration':{'input':menu_source,'sampleRate':16000,'frequencyHz':50,'raw':raw_values,
                               'menu':menu['resampled'],'scaleToPeak099':scale,'referenceOutputSHA256':menu_hash},
            'cases':cases}


def verify(saved, fresh):
    if saved.keys()!=fresh.keys() or len(saved['cases'])!=len(fresh['cases']):
        raise ValueError('Reference structure changed')
    for key in fresh.keys()-{'cases','menuCalibration'}:
        if saved[key]!=fresh[key]: raise ValueError(f'Reference identity changed: {key}')
    for old,new in zip(saved['cases'],fresh['cases']):
        if old.keys()!=new.keys(): raise ValueError('Case structure changed')
        for key in new.keys()-{'expected','referenceOutputSHA256'}:
            if old[key]!=new[key]: raise ValueError(f'Case metadata changed: {new["name"]}/{key}')
        if old['expected'].keys()!=new['expected'].keys(): raise ValueError('Expected structure changed')
        for key,wanted in new['expected'].items():
            actual=old['expected'][key]
            if key in ('resampled','previousResampled','conditioned'):
                if len(actual)!=len(wanted) or any(not math.isfinite(x) or abs(x-y)>2e-12 for x,y in zip(actual,wanted)):
                    raise ValueError(f'Reference regeneration mismatch: {new["name"]}/{key}')
            elif actual!=wanted: raise ValueError(f'Reference axis/count changed: {new["name"]}/{key}')
    old,new=saved['menuCalibration'],fresh['menuCalibration']
    if old.keys()!=new.keys(): raise ValueError('Menu calibration structure changed')
    for key in new.keys()-{'referenceOutputSHA256'}:
        if old[key]!=new[key]: raise ValueError('Menu calibration changed')


def register():
    path=ROOT/'Configuration/provenance.json'
    data=json.loads(path.read_text()); relative=str(OUTPUT.relative_to(ROOT)); digest=sha(OUTPUT.read_bytes())
    record={'id':'conditioning-praat7','path':relative,'sha256':digest,
            'source':{'kind':'original-generated','url':'https://github.com/plx/hdxl-voice-processing/issues/31','versionOrHash':f'generator-v1-sha256:{implementation_hash()}'},
            'generator':{'path':'Tools/Conditioning/reference.py','version':'1','sha256':sha(Path(__file__).read_bytes())},
            'redistribution':{'license':'project','permission':'inherits-project-license','evidence':'https://github.com/plx/hdxl-voice-processing/issues/78'},
            'containsHumanVoice':False,'consent':{'status':'not-applicable','evidence':'Original mathematical inputs; no recordings'},
            'transformations':['Pinned Praat 7.0.02 numeric resampling exports','Independent raw pre-emphasis equation; no menu peak normalization','Explicit Float32 source rounding before binary64 external reference'],
            'expectedProfile':'praat7-whole-interval-conditioning/v1; explicit rate, depth, precision and pre-emphasis per case',
            'referenceOutputIdentity':f'sha256:{digest}'}
    data['fixtures']=[r for r in data['fixtures'] if r['path']!=relative]+[record]
    path.write_text(json.dumps(data,indent=2)+'\n')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write',action='store_true')
    parser.add_argument('--tool',type=Path,default=ROOT/'.build/reference-tool/7.0.02/Praat.app/Contents/MacOS/Praat')
    args=parser.parse_args()
    fresh=generate(args.tool)
    if args.write:
        OUTPUT.parent.mkdir(parents=True,exist_ok=True)
        OUTPUT.write_text(json.dumps(fresh,indent=2,allow_nan=False)+'\n'); register()
    else: verify(json.loads(OUTPUT.read_text()),fresh)
    print(f'Verified {len(fresh["cases"])} independent conditioning cases')


if __name__=='__main__': main()
