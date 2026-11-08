#!/usr/bin/env python3
"""Retain bounded intermediate equations before native implementation exists."""
import argparse
from pathlib import Path

from catalog import ROOT, cases, geometry, source_samples
from common import canonical, load_json
from contract import PEAK_POLICY
from degeneracy import impulse_plateau
import oracle
from reference import sha
from verify import verify as verify_reference

NAMES = [
    'tone-80-ac-float64','tone-80-cc-float64',
    'noisy-0.05-ac-float32','noisy-0.05-cc-float32',
    'harmonic-ac-float64','harmonic-cc-float64',
    'noise-ac-float64','noise-cc-float64',
    'impulse-cc-float64','impulse-tenth-cc-float64',
    'matrix-ac-44100-4.5-60-0.005','matrix-cc-44100-6.0-60-0.005',
    'matrix-ac-48000-6.0-60-0.01','matrix-cc-48000-6.0-60-0.01',
    'speech-bl01-vowel-a-ac-float64','speech-bl01-vowel-a-cc-float64',
]
SOURCES=['Tools/HNR/stages.py','Tools/HNR/oracle.py','Tools/HNR/degeneracy.py',
         'Tools/HNR/catalog.py','Tools/HNR/contract.py']


def artifacts(reference_directory):
    reference_directory=Path(reference_directory)
    verify_reference(reference_directory)
    source_hashes={p:sha((ROOT/p).read_bytes()) for p in SOURCES}
    source_identity=sha(canonical(source_hashes))
    reference_manifest=sha((reference_directory/'manifest.json').read_bytes())
    catalog={c['name']:c for c in cases()};output={}
    for name in NAMES:
        case=catalog[name];samples=source_samples(case)
        index=geometry(case['profile'],len(samples))['frameCount']//2
        result=oracle.frame(samples,case['profile'],index)
        external=load_json(reference_directory/(name+'.json'))
        record={'schemaVersion':1,'case':case,'input':external['input'],
                'frameIndex':index,'equationSourceIdentity':source_identity,
                'referenceIdentity':external['referenceIdentity'],
                'externalFrame':external['data']['frames'][index],
                'equations':result,'flatImpulseProof':impulse_plateau(samples,case['profile'],result)}
        output[name+'.json']=canonical(record)
    output['manifest.json']=canonical({'schemaVersion':1,
        'definition':'independent-compensated-direct-sum-hnr-stages-v1',
        'peakPolicy':PEAK_POLICY,'sourceSHA256':source_hashes,
        'referenceManifestSHA256':reference_manifest,
        'files':{name:sha(data) for name,data in output.items()}})
    return output


def generate(reference_directory,output):
    output=Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT/'.build').resolve()):
        raise ValueError('Use an absent stage directory under .build')
    records=artifacts(reference_directory)
    output.mkdir(parents=True)
    for name,data in records.items():(output/name).write_bytes(data)
    print('HNR_STAGES_COMPLETE',len(records)-1,flush=True)


def verify(reference_directory,directory):
    directory=Path(directory)
    expected=artifacts(reference_directory)
    if {p.name for p in directory.iterdir()}!=set(expected):
        raise ValueError('Stage inventory differs')
    for name,data in expected.items():
        if (directory/name).is_symlink() or (directory/name).read_bytes()!=data:
            raise ValueError('Stage identity or independent equations differ: '+name)
    print('HNR_STAGES_VERIFIED',len(expected)-1,flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-directory',required=True,type=Path)
    parser.add_argument('--directory',required=True,type=Path)
    parser.add_argument('--verify',action='store_true')
    args=parser.parse_args()
    (verify if args.verify else generate)(args.reference_directory,args.directory)
