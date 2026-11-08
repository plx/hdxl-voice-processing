"""Original bounded HNR inputs; no expected values come from the Swift library."""
import math
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
# Keep this algorithm's reference/verify modules ahead of the shared helpers.
sys.path.insert(1, str(ROOT / 'Tools/Reference'))
from common import pcm_wave, read_pcm


def profile(method, *, rate=16000, precision='float64', floor=75., periods=4.5,
            hop=.01, silence=.1):
    if method not in ('ac', 'cc') or precision not in ('float32', 'float64'):
        raise ValueError('Unsupported HNR method/precision')
    if type(rate) is not int or not 4000 <= rate <= 192000:
        raise ValueError('Invalid HNR sample rate')
    for value in (floor, periods, hop, silence):
        if type(value) not in (int, float) or not math.isfinite(value):
            raise ValueError('Nonfinite/non-numeric HNR setting')
    if not 20 <= floor <= rate/8 or not 2 <= periods <= 10:
        raise ValueError('Unsupported HNR window')
    if not 1/rate <= hop <= 1 or not 0 <= silence <= 1:
        raise ValueError('Invalid HNR hop/silence threshold')
    physical = periods * (2 if method == 'ac' else 1) / floor
    size = 2 * (math.floor(physical / (1/rate)) // 2 - 1)
    if not 8 <= size <= 65536:
        raise ValueError('HNR workspace bound')
    return {'schemaVersion': 1, 'method': method,
            'identifier': f'praat-7002-hnr-{method}-whole-interval-v1',
            'sampleRate': rate, 'inputPrecision': precision,
            'arithmeticPrecision': 'float64', 'pitchFloorHz': float(floor),
            'periodsPerWindow': float(periods), 'hopSeconds': float(hop),
            'silenceThreshold': float(silence),
            'silencePolicy': 'wholeIntervalMeanRemovedPeakSoftCandidate',
            'frameGrid': 'centeredWholeIntervalBinary64FusedStep',
            'window': 'pitchGaussianNPlusOne' if method == 'ac' else 'rectangularForwardPair',
            'interpolation': 'sinc700SymmetricRaisedCosineDepthPlusHalf',
            'overshoot': 'reciprocalAboveOne', 'referenceDecibelLimit': 150.,
            'referencePeriodicityLimit': 1e-15,
            'candidateSearch': 'internalPositiveLocalMaximaNyquistCeiling',
            'selection': 'wholeContiguousIntervalNoMaskStitching'}


def geometry(p, count):
    """The recorded binary64 grid, not an epsilon-adjusted rational approximation."""
    validate_profile(p)
    if type(count) is not int or count < 0:
        raise ValueError('Invalid sample count')
    fs = p['sampleRate']
    duration = (1/fs) * count
    periods = p['periodsPerWindow'] * (2 if p['method'] == 'ac' else 1)
    window_duration = periods/p['pitchFloorHz']
    support_duration = window_duration + (1/p['pitchFloorHz'] if p['method'] == 'cc' else 0)
    n = 2 * (math.floor(window_duration / (1/fs))//2 - 1)
    frames = 0 if duration < support_duration else math.floor((duration-support_duration)/p['hopSeconds'])+1
    first = None if not frames else duration/2 - .5*(frames*p['hopSeconds']) + .5*p['hopSeconds']
    return {'frameCount': frames, 'firstCenterSeconds': first,
            'hopSeconds': p['hopSeconds'], 'nominalSupportSeconds': support_duration,
            'windowSampleCount': n, 'maximumCandidateLag': min(math.floor(n/periods)+2,n),
            'maximumCorrelationLag': n//4 if p['method']=='ac' else n}


def validate_profile(p):
    if not isinstance(p, dict):
        raise ValueError('Expected HNR profile')
    try:
        rebuilt = profile(p['method'], rate=p['sampleRate'], precision=p['inputPrecision'],
                          floor=p['pitchFloorHz'], periods=p['periodsPerWindow'],
                          hop=p['hopSeconds'], silence=p['silenceThreshold'])
    except (KeyError, TypeError) as e:
        raise ValueError('Incomplete HNR profile') from e
    if rebuilt != p or type(p.get('schemaVersion')) is not int:
        raise ValueError('Unknown or inconsistent HNR convention')


def cases():
    result = []
    def pair(name, kind, *, precision='float64', duration=.32, rate=16000, **source):
        for method in ('ac','cc'):
            result.append({'name': f'{name}-{method}-{precision}',
                'profile': profile(method, rate=rate, precision=precision),
                'source': {'kind':kind,'durationSeconds':duration,'seed':39001,**source}})
    for precision in ('float32','float64'):
        for hz in (80.,120.,300.,600.,1800.):
            pair(f'tone-{int(hz)}','tone',precision=precision,hz=hz)
        for kind in ('silence','constant','noise','harmonic','missing-fundamental',
                     'clipped','transition','bursts','impulse','alternating'):
            pair(kind,kind,precision=precision)
        for amplitude in (.01,.05,.2,.6):
            pair(f'noisy-{amplitude}','noisy',precision=precision,noiseAmplitude=amplitude)
        pair('filtered','filtered',precision=precision)
        pair('harmonic-inverted','harmonic',precision=precision,gain=-1.)
        pair('harmonic-quiet','harmonic',precision=precision,gain=.001)
        pair('harmonic-offset','harmonic',precision=precision,offset=.35,gain=.5)
    # A single impulse has an analytically flat positive-lag CC curve here.
    # Preserve the external tool's gain-dependent numerical candidates as evidence.
    for name,gain in (('inverted',-1.),('half',.5),('tenth',.1),('hundredth',.01),('decimal',.3)):
        pair('impulse-'+name,'impulse',gain=gain)
    # Full requested performance/profile parameter matrix, also reference-backed.
    for method in ('ac','cc'):
        for rate in (16000,44100,48000):
            for periods in (4.5,6.):
                for floor in (60.,75.):
                    for hop in (.005,.01):
                        name=f'matrix-{method}-{rate}-{periods}-{int(floor)}-{hop}'
                        result.append({'name':name,'profile':profile(method,rate=rate,
                            periods=periods,floor=floor,hop=hop),
                            'source':{'kind':'noisy','durationSeconds':.26,'seed':39002,
                                      'noiseAmplitude':.1,'hz':105.}})
    # Frame-count/phase boundary cases deliberately include nonintegral sample hops.
    for rate,count in ((16000,1920),(16000,1921),(16000,2080),(44100,5292),
                       (44100,5293),(44100,8003),(48000,6257)):
        for method in ('ac','cc'):
            result.append({'name':f'boundary-{method}-{rate}-{count}',
                'profile':profile(method,rate=rate,hop=.005),
                'source':{'kind':'harmonic','sampleCount':count,'seed':39003}})
    for name in ('bl01-vowel-a','bl01-all-voiced','bl02-vowel-a','bl02-consonant-rich',
                 'bl03-vowel-a','bl01-noisy','bl01-low-level','bl01-dropout'):
        pair('speech-'+name,'licensed-speech',duration=.5,rate=44100,
             path=f'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-{name}.wav')
    assert len({r['name'] for r in result})==len(result)
    return result


def source_samples(case):
    p,s=case['profile'],case['source']
    validate_profile(p)
    fs=p['sampleRate']
    count=s.get('sampleCount',round(s.get('durationSeconds',.32)*fs))
    if not 1 <= count <= fs*2:
        raise ValueError('Bounded reference duration required')
    if s['kind']=='licensed-speech':
        raw,record=read_pcm(ROOT/s['path'])
        if record['sampleRate']!=fs or len(raw)<count:
            raise ValueError('Corpus source does not meet declared rate/duration')
        values=raw[:count]
    else:
        state=s['seed']; values=[]; hz=s.get('hz',120.)
        for i in range(count):
            state=(1664525*state+1013904223)&0xffffffff
            noise=2*(state/4294967296)-1
            t=(i+.5)/fs
            harmonic=sum(math.sin(2*math.pi*hz*k*t)/k for k in range(1,9))*.18
            kind=s['kind']
            if kind=='tone': v=.6*math.sin(2*math.pi*hz*t)
            elif kind=='silence': v=0.
            elif kind=='constant': v=.25
            elif kind=='noise': v=.5*noise
            elif kind=='harmonic': v=harmonic
            elif kind=='missing-fundamental':
                v=sum(math.sin(2*math.pi*120*k*t)/k for k in range(2,9))*.35
            elif kind=='noisy': v=(harmonic+s['noiseAmplitude']*noise)/1.5
            elif kind=='filtered': v=harmonic
            elif kind=='clipped': v=max(-1.,min(1.,harmonic*8))
            elif kind=='transition':
                change=count/(2*fs)
                phase=80*min(t,change)+300*max(0.,t-change)
                v=.5*math.sin(2*math.pi*phase)
            elif kind=='bursts':
                amplitude=(.05,.075,.125,.5)[min(3,4*i//count)]
                v=amplitude*math.sin(2*math.pi*120*t)
            elif kind=='impulse': v=.75 if i==count//2 else 0.
            elif kind=='alternating': v=.25 if i%2 else -.25
            else: raise ValueError('Unknown source kind')
            values.append(v)
        if s['kind']=='filtered':
            # Original stable all-pole recursion; same source as the harmonic case.
            for frequency,bandwidth in ((650.,100.),(1200.,150.),(2500.,200.)):
                radius=math.exp(-math.pi*bandwidth/fs)
                a=2*radius*math.cos(2*math.pi*frequency/fs); b=radius*radius
                previous=older=0.; filtered=[]
                for v in values:
                    new=v+a*previous-b*older
                    filtered.append(new); older,previous=previous,new
                values=filtered
            peak=max(map(abs,values)); values=[v*.7/peak for v in values]
        values=[s.get('gain',1.)*v+s.get('offset',0.) for v in values]
    if p['inputPrecision']=='float32':
        values=list(struct.unpack(f'<{len(values)}f',struct.pack(f'<{len(values)}f',*values)))
    return values


def encoded_pcm(case):
    # Float32 cases are rounded first, then losslessly transported as Float64 WAVE.
    return pcm_wave(source_samples(case),case['profile']['sampleRate'])
