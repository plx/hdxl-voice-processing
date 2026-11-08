"""Original direct-sum mathematical probes, independent of native FFT execution.

The equations and finite conventions are documented in README.md. This module
does not import, execute or translate the upstream numerical implementation.
"""
import math

from catalog import geometry
from contract import PEAK_POLICY


def dot(a,b):
    return math.fsum(x*y for x,y in zip(a,b))


def autocorrelation(values,maximum_lag):
    if not 0<=maximum_lag<len(values):
        raise ValueError('Invalid autocorrelation extent')
    return [dot(values[:len(values)-k],values[k:]) for k in range(maximum_lag+1)]


def forward_correlation(values,window,maximum_lag):
    if not 1<=window<=len(values) or not 0<=maximum_lag<=len(values)-window:
        raise ValueError('Invalid forward correlation extent')
    first=values[:window]; energy=dot(first,first)
    result=[]
    for lag in range(maximum_lag+1):
        other=values[lag:lag+window]; denominator=math.sqrt(energy*dot(other,other))
        result.append(dot(first,other)/denominator if denominator else None)
    return result


def sinc(values,position,requested_depth):
    """Even lag curve, symmetric depth+half cosine taper, direct compensated sum."""
    radius=len(values)-1
    if not -radius<=position<=radius or requested_depth<1:
        raise ValueError('Interpolation outside observed curve')
    left=math.floor(position)
    if position==left:
        return values[abs(left)]
    depth=min(requested_depth,left+radius+1,radius-left)
    fraction=position-left
    if depth==1:
        a,b=values[abs(left)],values[abs(left+1)]
        return None if a is None or b is None else a+(b-a)*fraction
    if depth==2:
        # Hermite cubic from adjacent centered derivatives, only used at a curve edge.
        a,b,c,d=[values[abs(i)] for i in (left-1,left,left+1,left+2)]
        if any(v is None for v in (a,b,c,d)): return None
        slope_left=(c-a)/2; slope_right=(d-b)/2; u=fraction
        return (2*u**3-3*u*u+1)*b+(u**3-2*u*u+u)*slope_left+(-2*u**3+3*u*u)*c+(u**3-u*u)*slope_right
    terms=[]
    for k in range(depth):
        for distance,index in ((fraction+k,left-k),(1-fraction+k,left+1+k)):
            value=values[abs(index)]
            if value is None: return None
            weight=math.sin(math.pi*distance)/(math.pi*distance)
            weight*=(1+math.cos(math.pi*distance/(depth+.5)))/2
            terms.append(value*weight)
    return math.fsum(terms)


def maximum(values,integer_lag,depth=700):
    """Bounded golden-section search; no upstream optimizer or native code."""
    a,b=integer_lag-1.,integer_lag+1.
    ratio=(math.sqrt(5)-1)/2
    left=b-ratio*(b-a);right=a+ratio*(b-a)
    low,high=sinc(values,left,depth),sinc(values,right,depth)
    if low is None or high is None:return None
    for _ in range(60):
        if low>high:
            b,right,high=right,left,low;left=b-ratio*(b-a);low=sinc(values,left,depth)
        else:
            a,left,low=left,right,high;right=a+ratio*(b-a);high=sinc(values,right,depth)
        if low is None or high is None:return None
    choices=[(sinc(values,t,depth),t) for t in (float(integer_lag),left,right,(a+b)/2)]
    if any(v is None for v,_ in choices):return None
    value,lag=max(choices)
    return lag,value


def decibels(periodicity):
    if periodicity<=1e-15:return -150.
    if periodicity>1-1e-15:return 150.
    return 10*math.log10(periodicity/(1-periodicity))


def peak_kind(left,middle,right):
    if any(v is None for v in (left,middle,right)):
        return 'undefined'
    if not (middle>0 and middle>left and middle>=right):
        return 'notLocalMaximum'
    if (middle-left)+(middle-right)<=PEAK_POLICY['minimumCurvature']:
        return 'numericallyFlatPeak'
    return 'resolvedPeak'


def frame(samples,p,index):
    shape=geometry(p,len(samples))
    if type(index) is not int or not 0<=index<shape['frameCount']:
        raise ValueError('Frame index outside complete grid')
    fs=p['sampleRate']; dx=1/fs
    time=math.fma(float(index),p['hopSeconds'],shape['firstCenterSeconds'])
    center=math.floor(1+(time-.5*dx)/dx)
    period=math.floor(1/dx/p['pitchFloorHz'])
    length=shape['windowSampleCount'];half=length//2
    centered_start=center-half
    local=samples[center-period:center+period]
    if len(local)!=2*period:raise ValueError('Incomplete local-mean support')
    mean=math.fsum(local)/len(local)
    centered=[x-mean for x in samples[centered_start:centered_start+length]]
    if len(centered)!=length:raise ValueError('Incomplete centered support')
    if p['method']=='ac':
        edge=math.exp(-12)
        window=[(math.exp(-12*((2*j+1-length)/(length+1))**2)-edge)/(1-edge)
                for j in range(length)]
        prepared=[x*w for x,w in zip(centered,window)]
    else:
        prepared=centered
    half_period=period//2+1
    peak=max(map(abs,prepared[max(0,half-half_period):min(length,half+half_period)]))
    global_mean=math.fsum(samples)/len(samples)
    global_peak=max(abs(x-global_mean) for x in samples)
    intensity=min(1.,peak/global_peak) if global_peak else 0.
    output={'centerSeconds':time,'localMean':mean,'localPeak':peak,'globalPeak':global_peak,
            'intensity':intensity,'candidates':[],'selected':None,'rawReferenceDB':-200.,
            'correlation':[],'windowed':prepared,'centeredStartSample':centered_start,
            'localMeanStartSample':center-period,'localMeanSampleCount':2*period,
            'peakPolicy':PEAK_POLICY,'rejectedPeaks':[]}
    if not global_peak or not peak:return output
    maximum_lag=shape['maximumCandidateLag'];radius=shape['maximumCorrelationLag']
    if p['method']=='ac':
        signal=autocorrelation(prepared,radius);weights=autocorrelation(window,radius)
        if not signal[0]:return output
        scale=weights[0]/signal[0]
        curve=[scale*a/b if b else None for a,b in zip(signal,weights)]
        curve[0]=1.
        output.update(window=window,signalCorrelation=signal,windowCorrelation=weights,
                      correlationStartSample=centered_start,
                      correlationSampleCount=length)
    else:
        first_time=time-.5*(1/p['pitchFloorHz']+p['periodsPerWindow']/p['pitchFloorHz'])
        first=max(0,math.floor(1+(first_time-.5*dx)/dx)-1)
        computed=min(maximum_lag,len(samples)-first-length)
        if computed<0:raise ValueError('Incomplete forward support')
        values=[x-mean for x in samples[first:first+length+computed]]
        curve=forward_correlation(values,length,computed)+[0.]*(radius-computed)
        curve[0]=1.
        output.update(correlationStartSample=first,correlationSampleCount=length+computed,
                      computedMaximumLag=computed)
    output['correlation']=curve
    possible=[]
    for lag in range(2,min(maximum_lag,radius)):
        left,middle,right=curve[lag-1:lag+2]
        kind=peak_kind(left,middle,right)
        if kind=='numericallyFlatPeak':
            output['rejectedPeaks'].append({'integerLag':lag,'reason':kind,
                                          'curvature':(middle-left)+(middle-right)})
        if kind=='resolvedPeak':
            displacement=(right-left)/2/((middle-left)+(middle-right))
            initial_lag=lag+displacement
            strength=sinc(curve,initial_lag,30)
            if strength is not None:
                possible.append({'integerLag':lag,'initialLag':initial_lag,
                    'initialStrength':1/strength if strength>1 else strength})
    capacity=max(15,math.floor((fs/2)/p['pitchFloorHz']))-1
    retained=sorted(possible,key=lambda c:(-c['initialStrength'],c['integerLag']))[:capacity]
    retained.sort(key=lambda c:c['integerLag'])
    candidates=[]
    for c in retained:
        refined=maximum(curve,c['integerLag'])
        if refined is None:continue
        lag,strength=refined
        periodicity=1/strength if strength>1 else strength
        candidates.append({**c,'lag':lag,'frequencyHz':fs/lag,
                           'unreflectedCorrelation':strength,'periodicity':periodicity,
                           'reflected':strength>1})
    output['candidates']=candidates
    unvoiced=0. if p['silenceThreshold']==0 else max(0.,2-intensity/p['silenceThreshold'])
    best=None;strength=unvoiced
    for i,c in enumerate(candidates):
        if 0<c['frequencyHz']<fs/2 and c['periodicity']>strength:
            best=i;strength=c['periodicity']
    output.update(selected=best,unvoicedStrength=unvoiced,
                  rawReferenceDB=-200. if best is None else decibels(strength))
    return output
