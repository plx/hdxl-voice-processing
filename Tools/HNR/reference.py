#!/usr/bin/env python3
"""Pinned external HNR generation. Writes fresh candidates, never native goldens."""
import argparse
import hashlib
import math
import os
from pathlib import Path
import platform
import re
import struct
import subprocess
import tempfile
import time

from catalog import ROOT, cases, encoded_pcm, geometry, source_samples, validate_profile
from common import canonical, load_json, number
from contract import COMPARISON, finite, reference_state
from setup import verify_tool

HERE=Path(__file__).resolve().parent
LOCK=ROOT/'Tools/Reference/toolchain.json'
SOURCES=['Tools/HNR/catalog.py','Tools/HNR/contract.py','Tools/HNR/probe.praat',
         'Tools/HNR/reference.py','Tools/Reference/common.py','Tools/Reference/toolchain.json']
MAX_FRAMES=2000
MAX_BYTES=2*1024*1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def implementation_hash():
    return sha(canonical({p:sha((ROOT/p).read_bytes()) for p in SOURCES}))


def integer(token):
    if not re.fullmatch(r'0|[1-9][0-9]*',token):
        raise ValueError('Invalid protocol integer')
    return int(token)


def scalar(token):
    value=number(token)
    if value is None:
        raise ValueError('Unexpected undefined protocol number')
    return value


def parse(raw, p, count):
    validate_profile(p)
    if len(raw.encode())>MAX_BYTES:
        raise ValueError('HNR protocol exceeds byte budget')
    lines=raw.splitlines()
    if len(lines)<7 or lines[0]!='begin\thnr-reference-v1' or lines[-1]!='end\thnr-reference-v1':
        raise ValueError('Missing HNR protocol boundaries')
    if lines[1]!=f"input\t{p['sampleRate']}\t{count}":
        raise ValueError('Reference input identity differs')
    settings=lines[2].split('\t')
    wanted=[p[k] for k in ('hopSeconds','pitchFloorHz','silenceThreshold','periodsPerWindow')]
    if len(settings)!=6 or settings[:2]!=['settings',p['method']] or list(map(scalar,settings[2:]))!=wanted:
        raise ValueError('Reference settings differ')
    axis=lines[3].split('\t')
    expected=geometry(p,count)
    if len(axis)!=4 or axis[0]!='axes':
        raise ValueError('Missing HNR axes')
    frames=integer(axis[1]); first=scalar(axis[2]); hop=scalar(axis[3])
    if not 1<=frames<=MAX_FRAMES or frames!=expected['frameCount']:
        raise ValueError('Reference frame count differs')
    if first!=expected['firstCenterSeconds'] or hop!=p['hopSeconds']:
        raise ValueError('Reference frame grid differs')
    mean_line=lines[4].split('\t')
    if len(mean_line)!=3 or mean_line[:2]!=['mean','decibelsRatio']:
        raise ValueError('Missing HNR aggregate/unit')
    mean=number(mean_line[2])
    if len(lines)!=frames+6:
        raise ValueError('Reference frame coverage differs')
    rows=[]
    for i,line in enumerate(lines[5:-1],1):
        parts=line.split('\t')
        if len(parts)!=4 or parts[0]!='frame' or integer(parts[1])!=i:
            raise ValueError('Missing/reordered/repeated HNR frame')
        center=scalar(parts[2]); raw_value=scalar(parts[3])
        if center!=math.fma(float(i-1),hop,first):
            raise ValueError('Reference timestamp differs from frame grid')
        rows.append({'index':i,'centerSeconds':center,'rawReferenceDB':raw_value,
                     **reference_state(raw_value)})
    available=[r['valueDB'] for r in rows if r['valueDB'] is not None]
    expected_mean=math.fsum(available)/len(available) if available else None
    if (mean is None)!=(expected_mean is None) or (mean is not None and
            abs(mean-expected_mean)>COMPARISON['referenceAggregateAbsoluteDB']):
        raise ValueError('Reference aggregate/availability differs')
    return {'unit':'decibelsRatio','axes':{'frameCount':frames,'firstCenterSeconds':first,'hopSeconds':hop},
            'frames':rows,'meanDB':mean,'availableFrameCount':len(available),
            'unavailableFrameCount':frames-len(available),
            'limitFrameCount':sum(r['status'].endswith('ReportingLimit') for r in rows),
            'meanPolicy':'equal arithmetic mean of available reference dB, including explicitly labelled reporting limits',
            'coverageDenominator':'all emitted frame slots; edge support and excluded intervals are not silently counted as valid'}


def input_identity(case, encoded):
    samples=source_samples(case)
    return {'sampleRate':case['profile']['sampleRate'],'sampleCount':len(samples),
            'inputPrecision':case['profile']['inputPrecision'],
            'normalizedFloat64LESHA256':sha(struct.pack(f'<{len(samples)}d',*samples)),
            'encodedSHA256':sha(encoded),'transportEncoding':'float64-WAVE-after-declared-input-rounding'}


def assemble(case, encoded, raw, lock):
    identity=input_identity(case,encoded)
    data=parse(raw,case['profile'],identity['sampleCount'])
    ingredients={'schemaVersion':1,'case':case,'input':identity,'toolchain':lock,
                 'generatorSHA256':implementation_hash(),'comparisonPolicy':COMPARISON,
                 'rawOutputSHA256':sha(raw.encode())}
    return {**ingredients,'referenceIdentity':sha(canonical(ingredients)),'data':data}


def evaluate(case, binary, lock, scratch):
    encoded=encoded_pcm(case); path=scratch/'input.wav'; path.write_bytes(encoded)
    p=case['profile']; samples=source_samples(case)
    count=geometry(p,len(samples))['frameCount']
    if not 1<=count<=MAX_FRAMES:
        raise ValueError('Case needs a complete bounded reference frame grid')
    command=[str(binary),*lock['options'],str(HERE/'probe.praat'),str(path),p['method'],
             *[str(p[k]) for k in ('hopSeconds','pitchFloorHz','silenceThreshold','periodsPerWindow')]]
    started=time.perf_counter()
    completed=subprocess.run(command,capture_output=True,text=True,encoding='utf-8',timeout=120,
                             env={**os.environ,'LC_ALL':'C','LANG':'C'})
    seconds=time.perf_counter()-started
    if completed.returncode or completed.stderr.strip():
        raise ValueError(f'Reference process failed ({completed.returncode}): {completed.stderr[:1200]}')
    raw=completed.stdout
    record=assemble(case,encoded,raw,lock)
    return record,encoded,raw,seconds


def generate(output, selected=None):
    output=Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT/'.build').resolve()):
        raise ValueError('Use an absent candidate directory under .build')
    lock=load_json(LOCK)
    if platform.python_version()!=lock['pythonVersion']:
        raise ValueError('Pinned Python required')
    binary=verify_tool(ROOT/'.build/reference-tool'/lock['version']/lock['executablePath'],lock)
    catalog=cases()
    if selected:
        catalog=[c for c in catalog if c['name'] in selected]
        if len(catalog)!=len(set(selected)) or len(selected)!=len(set(selected)):
            raise ValueError('Unknown/repeated requested case')
    output.mkdir(parents=True)
    files={}; trials=[]
    with tempfile.TemporaryDirectory(prefix='hnr-reference-',dir=ROOT/'.build') as directory:
        for case in catalog:
            record,encoded,raw,seconds=evaluate(case,binary,lock,Path(directory))
            name=case['name']
            for suffix,data in (('.json',canonical(record)),('.wav',encoded),('.raw.txt',raw.encode())):
                path=output/(name+suffix); path.write_bytes(data); files[path.name]=sha(data)
            trials.append({'name':name,'seconds':seconds,'frames':record['data']['axes']['frameCount'],
                           'available':record['data']['availableFrameCount'],'limits':record['data']['limitFrameCount']})
            print(name,record['data']['meanDB'],flush=True)
    manifest={'schemaVersion':1,'toolchain':lock,'generatorSHA256':implementation_hash(),
              'comparisonPolicy':COMPARISON,'catalog':catalog,'files':files,'partialCatalog':bool(selected)}
    (output/'manifest.json').write_bytes(canonical(manifest))
    # Execution timing is external-process evidence, outside canonical golden identity.
    (output/'execution.json').write_bytes(canonical({'pythonVersion':platform.python_version(),
        'boundary':'process launch, WAV read, reference algorithm and export; no native timing claim',
        'trials':trials}))
    print('HNR_CANDIDATES_COMPLETE',len(catalog),flush=True)
    return manifest


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--case',action='append')
    args=parser.parse_args()
    generate(args.output,args.case)
