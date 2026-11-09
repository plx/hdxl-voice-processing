#!/usr/bin/env python3
"""Generate/replay source timing certificates; no native or external tracker input."""
import argparse
import math
from pathlib import Path
import time

import catalog
import source_timing
import verify
from reference import ROOT, HERE, canonical, digest, pcm_wave


def sources():
    paths = [HERE/name for name in ('source_timing.py','source_reference.py','SOURCE_TIMING.md','catalog.py',
                                    'verify.py','reference.py')]
    paths += [ROOT/'Tools/Reference/common.py']
    return {str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in paths}


def assemble(case):
    samples,known = catalog.source(case)
    wave = pcm_wave(samples,case['sampleRate'])
    path = 'Tests/HDXLVoiceProcessingTests/Fixtures/Pulses/'+case['name']+'.wav'
    verify.check(verify.read_bytes(ROOT/path) == wave, 'Existing source PCM differs from generator')
    certificate = source_timing.certify(case)
    body = dict(schemaVersion=1,definition='finite-input-gaussian-pulse-enclosure-v1',
        inputPath=path,inputSHA256=digest(wave),knownSourceIdentity=digest(canonical(known)),
        generatorSources=sources(),**certificate)
    return dict(fixtureIdentity=digest(canonical(body)),**body)


def generate(directory):
    directory = Path(directory).resolve()
    verify.check(not directory.exists() and directory.is_relative_to((ROOT/'.build').resolve()),
                 'Use an absent source-certificate directory under .build')
    directory.mkdir(parents=True)
    files,trials = {},[]
    for case in source_timing.cases():
        start = time.perf_counter()
        record = assemble(case)
        name = case['name']+'.json'
        data = canonical(record)
        (directory/name).write_bytes(data);files[name] = digest(data)
        trials.append(dict(name=case['name'],seconds=time.perf_counter()-start))
        print(case['name'],len(record['points']),record['maximumSourceErrorSamples'],
              record['budget']['radiusSamples'],flush=True)
    manifest = dict(schemaVersion=1,cases=[c['name'] for c in source_timing.cases()],
                    definition='finite-input-gaussian-pulse-enclosure-v1',files=files,generatorSources=sources())
    (directory/'manifest.json').write_bytes(canonical(manifest))
    (directory/'execution.json').write_bytes(canonical(dict(schemaVersion=1,trials=trials,
        scope='Independent exact-integer correlation and interval certification; not native performance')))
    return dict(cases=len(files),files=len(files)+2)


def replay(directory):
    directory = Path(directory)
    verify.check(not directory.is_symlink() and directory.is_dir(), 'Invalid certificate directory')
    manifest = verify.read_json(directory/'manifest.json')
    cases = source_timing.cases()
    names = {c['name']+'.json' for c in cases}
    verify.check(isinstance(manifest,dict) and set(manifest) == {'schemaVersion','definition','cases','files','generatorSources'},
                 'Unknown certificate manifest fields')
    for key,value in dict(schemaVersion=1,definition='finite-input-gaussian-pulse-enclosure-v1',
                          cases=[c['name'] for c in cases],generatorSources=sources()).items():
        verify.same(manifest[key],value,'Certificate manifest changed: '+key)
    verify.check(isinstance(manifest['files'],dict) and set(manifest['files']) == names, 'Incomplete certificate manifest')
    verify.check({p.name for p in directory.iterdir()} == names|{'manifest.json','execution.json'},
                 'Missing/extra certificate artifacts')
    execution = verify.read_json(directory/'execution.json')
    verify.check(isinstance(execution,dict) and set(execution) == {'schemaVersion','scope','trials'}
        and type(execution['schemaVersion']) is int and execution['schemaVersion'] == 1
        and execution['scope'] == 'Independent exact-integer correlation and interval certification; not native performance'
        and isinstance(execution['trials'],list) and all(isinstance(r,dict) and 'name' in r for r in execution['trials'])
        and [r['name'] for r in execution['trials']] == [c['name'] for c in cases], 'Invalid certificate execution scope')
    for row in execution['trials']:
        verify.check(set(row) == {'name','seconds'} and type(row['seconds']) in (int,float)
            and math.isfinite(row['seconds']) and row['seconds'] >= 0, 'Invalid generation timing')
    count = 0
    for case in cases:
        path = directory/(case['name']+'.json')
        verify.check(digest(verify.read_bytes(path)) == manifest['files'][path.name], 'Certificate digest changed')
        actual = verify.read_json(path)
        verify.same(actual,assemble(case),'Finite source certificate replay differs: '+case['name'])
        count += len(actual['points'])
    return dict(cases=len(cases),sourcePoints=count,files=len(names)+2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,required=True)
    parser.add_argument('--verify',action='store_true')
    args = parser.parse_args()
    print(canonical(replay(args.directory) if args.verify else generate(args.directory)).decode())


if __name__ == '__main__': main()
