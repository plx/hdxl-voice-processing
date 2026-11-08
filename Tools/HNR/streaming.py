#!/usr/bin/env python3
"""Independent finite-window HNR and exact-rational streaming-grid fixtures.

No native implementation is imported or executed. Complete-window equations are
the existing direct-sum oracle; rational multiplication generates the frame starts
independently of the native incremental ring/phase execution path.
"""
import argparse
from fractions import Fraction
import math
from pathlib import Path
import struct

from catalog import ROOT, profile
from common import canonical, load_json, pcm_wave
from contract import PEAK_POLICY, reference_state
import oracle
from reference import sha

SOURCES=['Tools/HNR/streaming.py','Tools/HNR/oracle.py','Tools/HNR/catalog.py',
         'Tools/HNR/contract.py','Tools/Reference/common.py']


def native_profile(method,rate,precision):
    return dict(schemaVersion=1,method=method,sampleRate=rate,inputPrecision=precision,
        arithmeticPrecision='float64',pitchFloorHz=75.,periodsPerWindow=4.5,
        hopSeconds=.005,silenceThreshold=.1,normalization='causalWindowMeanRemovedPeak',
        window='pitchGaussianNPlusOne' if method=='ac' else 'rectangularForwardPair',
        interpolation='sinc700SymmetricRaisedCosineDepthPlusHalf',overshoot='reciprocalAboveOne',
        peakResolution=PEAK_POLICY['identifier'],minimumPeakCurvature=PEAK_POLICY['minimumCurvature'],
        reportingPeriodicityLimit=1e-15,reportingDecibelLimit=150.,
        frameGrid='causalAcquiredWindowCenterExactBinary64StepAccumulator',
        arithmeticScaling='framePeakScaledBinary64WithSeparateSilenceReference',
        partialWindowPolicy='emitUnavailable')


def geometry(p):
    width=(2*p['periodsPerWindow'] if p['method']=='ac' else p['periodsPerWindow']+1)/p['pitchFloorHz']
    # Preserve the declared order: CC support is P/floor + 1/floor.
    if p['method']=='cc':width=p['periodsPerWindow']/p['pitchFloorHz']+1/p['pitchFloorHz']
    window=math.ceil(width*p['sampleRate'])
    step=Fraction.from_float(max(1.,p['hopSeconds']*p['sampleRate']))
    count=2*window+math.floor(6*step)+17
    starts=[];index=0
    while math.floor(index*step)+window<=count:
        starts.append(math.floor(index*step));index+=1
    return window,step,count,starts,math.floor(index*step)


def samples(p):
    window,step,count,_,_=geometry(p)
    change=window+math.floor(2*step)
    state=39004;result=[]
    for i in range(count):
        state=(1664525*state+1013904223)&0xffffffff
        noise=2*(state/4294967296)-1
        t=(i+.5)/p['sampleRate']
        value=.25*math.sin(2*math.pi*120*t)+.08*math.sin(2*math.pi*240*t)+.015*noise
        result.append(value*(.02 if i<change else .8))
    if p['inputPrecision']=='float32':
        result=list(struct.unpack(f'<{len(result)}f',struct.pack(f'<{len(result)}f',*result)))
    return result


def artifacts():
    sources={p:sha((ROOT/p).read_bytes()) for p in SOURCES}
    identity=sha(canonical(sources));output={};catalog=[]
    for method in ('ac','cc'):
        for rate in (16000,44100,48000):
            for precision in ('float32','float64'):
                p=native_profile(method,rate,precision);values=samples(p)
                window,step,count,starts,tail=geometry(p)
                duration=(1/rate)*window
                # Exactly one reference window, with first center duration/2.
                # This independent bounded reference is not a whole-stream peak.
                equation_profile=profile(method,rate=rate,precision=precision,hop=duration)
                rows=[]
                for index,start in enumerate(starts):
                    data=oracle.frame(values[start:start+window],equation_profile,0)
                    assert data['centerSeconds']==duration/2
                    rows.append({'frameIndex':index,'startSample':start,'sampleCount':window,
                        'centerSecondsFromStreamOrigin':start/rate+duration/2,
                        'normalizationMean':math.fsum(values[start:start+window])/window,
                        'normalizationPeak':data['globalPeak'],'localMean':data['localMean'],
                        'localPeak':data['localPeak'],'relativeIntensity':data['intensity'],
                        'candidates':data['candidates'],'selectedCandidateIndex':data['selected'],
                        'rawReportingDB':data['rawReferenceDB'],**reference_state(data['rawReferenceDB'])})
                assert all(r['status']=='finite' for r in rows[:3]),'Future gain affected early windows'
                assert all(r['status']=='finite' for r in rows[-3:]),'Finite-window normalization did not recover'
                name=f'causal-{method}-{rate}-{precision}'
                encoded=pcm_wave(values,rate)
                record={'schemaVersion':1,'name':name,'profile':p,
                    'profileSHA256':sha(canonical(p)),'generatorIdentity':identity,
                    'source':{'kind':'original-harmonics-plus-LCG-amplitude-step','seed':39004,
                        'changeSample':window+math.floor(2*step),'earlyGain':.02,'laterGain':.8},
                    'input':{'sampleRate':rate,'sampleCount':count,'inputPrecision':precision,
                        'encodedSHA256':sha(encoded),
                        'normalizedFloat64LESHA256':sha(struct.pack(f'<{count}d',*values))},
                    'grid':{'windowSampleCount':window,'stepNumerator':step.numerator,
                        'stepDenominator':step.denominator,'completeFrameCount':len(rows),
                        'tailStartSample':tail,'tailSampleCount':count-tail},'frames':rows}
                output[name+'.json']=canonical(record);output[name+'.wav']=encoded
                catalog.append(name)
                print(name,len(rows),'complete frames',flush=True)
    output['manifest.json']=canonical({'schemaVersion':1,'definition':'finite-causal-window-hnr-equations-v1',
        'sourceSHA256':sources,'catalog':catalog,'files':{n:sha(v) for n,v in output.items()},
        'comparison':{'axisAbsoluteSeconds':1e-12,'periodicityAbsolute':2e-14,
                      'ordinaryDecibelsAbsolute':1e-4,'localNormalizedAmplitudeAbsolute':2e-14},
        'gridPolicy':'floor(k * exact rational value of max(1, binary64(hopSeconds * sampleRate))); one acquired finite window per start',
        'silencePolicy':'window-only mean-removed peak; unknown future input cannot affect earlier output'})
    return output


def run(directory,verify=False):
    directory=Path(directory).resolve()
    if not verify and (directory.exists() or not directory.is_relative_to((ROOT/'.build').resolve())):
        raise ValueError('Use an absent candidate directory under .build')
    expected=artifacts()
    if verify:
        if {p.name for p in directory.iterdir()}!=set(expected):raise ValueError('Causal fixture inventory differs')
        for name,data in expected.items():
            if (directory/name).is_symlink() or (directory/name).read_bytes()!=data:
                raise ValueError('Causal independent equations or identity differ: '+name)
    else:
        directory.mkdir(parents=True)
        for name,data in expected.items():(directory/name).write_bytes(data)
    print('HNR_CAUSAL_VERIFIED' if verify else 'HNR_CAUSAL_GENERATED',len(expected),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',required=True,type=Path)
    parser.add_argument('--verify',action='store_true')
    args=parser.parse_args();run(args.directory,args.verify)
