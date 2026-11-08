#!/usr/bin/env python3
"""Offline HNR reference verification: inputs, raw protocol and paired invariants."""
import argparse
from pathlib import Path

from catalog import ROOT, cases, encoded_pcm
from common import canonical, load_json
from contract import COMPARISON, comparison_fraction
from reference import LOCK, assemble, implementation_hash, sha


def check(value, message):
    if not value:
        raise ValueError(message)


def verify_record(record, case, encoded, raw, lock):
    check(encoded==encoded_pcm(case),'Encoded source differs from declared generator/corpus')
    expected=assemble(case,encoded,raw,lock)
    check(canonical(record)==canonical(expected),'Reference record differs from raw protocol/identity')
    if case['source']['kind'] in ('silence','constant'):
        check(record['data']['availableFrameCount']==0,'Silence/DC acquired a numeric HNR')
    return record['data']


def paired_checks(records):
    pairs=0; maximum_fraction=0.; trends=[]
    for method in ('ac','cc'):
        for precision in ('float32','float64'):
            suffix=f'-{method}-{precision}'
            original=records['harmonic'+suffix]['frames']
            for variant in ('harmonic-inverted','harmonic-quiet','harmonic-offset'):
                changed=records[variant+suffix]['frames']
                check(len(original)==len(changed),'Pair frame count changed')
                for a,b in zip(original,changed):
                    check(a['status']==b['status'],'Gain/polarity/DC changed availability or limit state')
                    if a['status']=='finite':
                        # Float32 gain/offset rounding changes the actual waveform, and
                        # cannot promise invariance of extremely high HNR. Preserve
                        # those deltas without relaxing same-input native tolerances.
                        fraction=comparison_fraction(b['valueDB'],a['valueDB'])
                        if precision=='float64' or variant=='harmonic-inverted':
                            check(fraction<=1,'Exact gain/polarity/DC invariant exceeded budget')
                            maximum_fraction=max(maximum_fraction,fraction)
                pairs+=1
            values=[records[f'noisy-{v}'+suffix]['meanDB'] for v in (.01,.05,.2,.6)]
            check(all(v is not None for v in values),'Noise-mixture reference unexpectedly has no aggregate')
            check(all(a>b for a,b in zip(values,values[1:])),'Controlled-noise aggregate trend reversed')
            trends.append({'method':method,'precision':precision,'meanDB':values})
    return {'pairs':pairs,'maximumExactInvariantBudgetFraction':maximum_fraction,'noiseTrends':trends}


def verify(directory, allow_partial=False):
    directory=Path(directory)
    manifest=load_json(directory/'manifest.json')
    keys={'schemaVersion','toolchain','generatorSHA256','comparisonPolicy','catalog','files','partialCatalog'}
    check(set(manifest)==keys and type(manifest['schemaVersion']) is int and manifest['schemaVersion']==1,
          'Unexpected HNR manifest schema/fields')
    check((directory/'manifest.json').read_bytes()==canonical(manifest),'Manifest is not canonical')
    check(type(manifest['partialCatalog']) is bool,'Invalid partial-catalog state')
    check(allow_partial or manifest['partialCatalog'] is False,'Incomplete HNR catalog')
    catalog=cases()
    if manifest['partialCatalog']:
        names=[c['name'] for c in manifest['catalog']]
        catalog=[c for c in catalog if c['name'] in names]
        check(bool(catalog) and len(names)==len(set(names)),'Empty/repeated partial catalog')
    check(canonical(manifest['catalog'])==canonical(catalog),'HNR catalog differs')
    lock=load_json(LOCK)
    check(manifest['toolchain']==lock and manifest['generatorSHA256']==implementation_hash(),
          'Reference tool/generator identity differs')
    check(manifest['comparisonPolicy']==COMPARISON,'Frozen comparison policy differs')
    expected={c['name']+suffix for c in catalog for suffix in ('.json','.wav','.raw.txt')}
    check(set(manifest['files'])==expected,'Manifest file coverage differs')
    check({p.name for p in directory.iterdir()}==expected|{'manifest.json','execution.json'},
          'Directory file coverage differs')
    for name,digest in manifest['files'].items():
        p=directory/name
        check(not p.is_symlink() and p.is_file() and p.stat().st_size<=2*1024*1024,
              'Unsafe/oversized reference artifact')
        check(sha(p.read_bytes())==digest,'Reference artifact hash differs')
    records={}; frames=available=limits=0
    for case in catalog:
        name=case['name']; path=directory/(name+'.json'); record=load_json(path)
        check(path.read_bytes()==canonical(record),'Reference record is not canonical')
        records[name]=verify_record(record,case,(directory/(name+'.wav')).read_bytes(),
                                   (directory/(name+'.raw.txt')).read_text(),lock)
        data=records[name]
        frames+=data['axes']['frameCount']; available+=data['availableFrameCount']; limits+=data['limitFrameCount']
    pairs=paired_checks(records) if not manifest['partialCatalog'] else None
    return {'cases':len(catalog),'frames':frames,'available':available,'limits':limits,
            'partial':manifest['partialCatalog'],'pairedInvariants':pairs}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,default=ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/HNR')
    parser.add_argument('--allow-partial',action='store_true')
    args=parser.parse_args()
    print(verify(args.directory,args.allow_partial))
