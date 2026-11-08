"""Narrow, executable algebraic proof for a retained reference disagreement.

This is not an exception by fixture name. Every qualifying frame must prove its
PCM, support geometry, local mean and observed curve satisfy the derivation.
"""
from fractions import Fraction
import math

from catalog import geometry


def impulse_plateau(samples,profile,result):
    """Return a proof of a flat positive-lag CC curve, or None.

    With a single amplitude A, local mean A/K, and both N-sample windows containing
    the impulse at distinct locations, dot=A²(N-2K)/K² and each energy equals
    A²(K²-2K+N)/K². Their ratio is independent of lag and nonzero amplitude.
    """
    if profile['method']!='cc' or result['selected'] is not None or result['candidates']:
        return None
    nonzero=[i for i,x in enumerate(samples) if x!=0]
    if len(nonzero)!=1 or not all(math.isfinite(x) for x in samples):return None
    index=nonzero[0];amplitude=samples[index]
    shape=geometry(profile,len(samples));n=shape['windowSampleCount']
    k=result['localMeanSampleCount'];mean_start=result['localMeanStartSample']
    first=result.get('correlationStartSample');maximum=result.get('computedMaximumLag')
    if first is None or maximum!=shape['maximumCandidateLag'] or maximum<3:return None
    if not mean_start<=index<mean_start+k or not first+maximum<=index<first+n:return None
    mean=amplitude/k
    if abs(result['localMean']-mean)>8*math.ulp(mean):return None
    exact=Fraction(n-2*k,k*k-2*k+n)
    if not 0<exact<1:return None
    value=float(exact);curve=result['correlation'][1:maximum+1]
    if len(curve)!=maximum or any(x is None or not math.isfinite(x) for x in curve):return None
    # Tight equation-specific comparison, not the much larger native peak guard.
    error=max(abs(x-value) for x in curve)
    if error>32*math.ulp(value):return None
    return {'kind':'singleImpulseFlatForwardCorrelation-v1',
            'impulseSample':index,'amplitude':amplitude,
            'localMeanStartSample':mean_start,'localMeanSampleCount':k,
            'comparisonStartSample':first,'comparisonSampleCount':n,
            'positiveLagRangeInclusive':[1,maximum],
            'exactCorrelationNumerator':exact.numerator,
            'exactCorrelationDenominator':exact.denominator,
            'maximumEquationError':error,'equationErrorBudget':32*math.ulp(value),
            'nativeDisposition':'unavailable; no resolved positive local maximum',
            'referenceDisposition':'retain raw output; excluded from agreement count only when it differs'}
