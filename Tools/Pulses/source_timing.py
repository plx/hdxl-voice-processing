#!/usr/bin/env python3
"""Independent finite-input enclosures for generated Gaussian pulse timing."""
from dataclasses import dataclass
from decimal import Decimal, localcontext
from itertools import product
import math
import sys

import catalog

EXTRA_CASES = ('inverted', 'quiet', 'jitter-1pct', 'jitter-12pct', 'modulated', 'alternating')
MAX_WINDOW = 4096
MAX_GEOMETRIES = 64


def require(condition, message):
    if not condition: raise ValueError(message)


@dataclass(frozen=True)
class Interval:
    low: float
    high: float

    def __post_init__(self):
        require(math.isfinite(self.low) and math.isfinite(self.high) and self.low <= self.high,
                'Invalid finite interval')

    @staticmethod
    def point(value): return Interval(float(value), float(value))

    @staticmethod
    def hull(values):
        values = list(values)
        require(bool(values), 'Empty enclosure')
        return Interval(min(x.low for x in values), max(x.high for x in values))

    @staticmethod
    def outward(low, high):
        return Interval(math.nextafter(low, -math.inf), math.nextafter(high, math.inf))

    def __add__(self, other):
        other = other if isinstance(other, Interval) else Interval.point(other)
        return Interval.outward(self.low + other.low, self.high + other.high)

    def __sub__(self, other):
        other = other if isinstance(other, Interval) else Interval.point(other)
        return Interval.outward(self.low - other.high, self.high - other.low)

    def __mul__(self, other):
        other = other if isinstance(other, Interval) else Interval.point(other)
        values = [a*b for a in (self.low, self.high) for b in (other.low, other.high)]
        return Interval.outward(min(values), max(values))

    def __truediv__(self, other):
        other = other if isinstance(other, Interval) else Interval.point(other)
        require(not other.low <= 0 <= other.high, 'Interval division contains zero')
        values = [a/b for a in (self.low, self.high) for b in (other.low, other.high)]
        return Interval.outward(min(values), max(values))

    def as_json(self): return [self.low, self.high]


def cases():
    names = {f'gaussian-{rate}-{hz}-{precision}' for rate in (16000,44100,48000)
             for hz in (80,150,300,600) for precision in ('float32','float64')}
    names |= {f'{stem}-{precision}' for stem in EXTRA_CASES for precision in ('float32','float64')}
    result = [c for c in catalog.cases() if c['name'] in names]
    require(len(result) == 36, 'Incomplete source-timing catalog')
    return result


def gamma(count):
    unit = 2.**-53
    return count * unit / (1 - count * unit)


def source_budget(case, known):
    period = case['sampleRate'] / case['source']['frequencyHz']
    sigma = .06 * period
    a = 1 / (4 * sigma * sigma)
    def curvature(exponent):
        h = .500001
        return 2 * math.exp(-exponent*h*h) * (1-math.exp(-exponent)*math.cosh(2*exponent*h))
    biases = []
    for left, right in zip(known, known[1:]):
        spacing = (right['timeSeconds']-left['timeSeconds']) * case['sampleRate']
        d = spacing - math.floor(spacing+.5)
        vertex = math.sinh(2*a*d)/(2*(math.exp(a)-math.cosh(2*a*d)))
        biases.append(abs(vertex-d))
    epsilon = 1e-7 if case['inputPrecision'] == 'float32' else 1e-11
    q = math.exp(-math.pi**2*sigma*sigma)
    theta = 2*q/(1-q**3)
    error = 4*epsilon/(1-epsilon) + 2*theta/(1-theta) + 8*gamma(math.ceil(period)+7)
    require(curvature(2*a) > 4*epsilon and curvature(a) > 4*error, 'Budget curvature unresolved')
    seed = 1/(8*sigma*sigma)+3e-6+3*epsilon/(curvature(2*a)-4*epsilon)+1e-8
    steps = math.ceil(len(known)/2)+2
    bias = max(biases)+3e-8
    radius = 2*(seed+steps*(bias+3*error/(curvature(a)-4*error)+1e-8))+.01
    return dict(definition='finite-gaussian-source-radius-v1', radiusSamples=radius,
                seedAllowanceSamples=seed, maximumIdealStepBiasSamples=bias, maximumSteps=steps)


class Enclosure:
    def __init__(self, samples, rate, frequency):
        require(1 <= len(samples) <= 24000 and all(math.isfinite(x) and abs(x) <= 1 for x in samples),
                'Unsupported source PCM')
        nonzero = [abs(x) for x in samples if x]
        require(nonzero and (min(nonzero)**2)**2 >= 16*sys.float_info.min,
                'Source certificate requires normal positive products and energy products')
        require(all(x >= 0 for x in samples) or all(x <= 0 for x in samples),
                'Source certificate does not cover cancellation')
        fractions = [x.as_integer_ratio() for x in samples]
        denominator = max(d for _, d in fractions)
        self.values = [n*(denominator//d) for n,d in fractions]
        self.squares = [0]
        for value in self.values: self.squares.append(self.squares[-1]+value*value)
        self.samples, self.rate, self.frequency = samples, rate, frequency
        self.global_peak = max(nonzero)
        self.step, self.first = 1/rate, .5/rate
        self.cache = {}
        self.geometry_count = 0
        self.peak_alternatives = 0

    def indices(self, time, selection):
        q = (time-self.first)/self.step+1
        if selection == 'nearest': q = q+.5
        convert = math.ceil if selection == 'high' else math.floor
        first, last = convert(q.low)-1, convert(q.high)-1
        require(0 <= last-first <= 2, 'Rounded coordinate branches exceed certificate budget')
        return range(first,last+1)

    def correlation(self, a, b, k):
        key = a,b,k
        if key in self.cache: return self.cache[key]
        shift = k-a
        first, end = max(a,0,-shift), min(b+1,len(self.values),len(self.values)-shift)
        count = max(0,end-first)
        require(count <= MAX_WINDOW, 'Unbounded correlation support')
        if not count: result = Interval.point(0),0.
        else:
            aa = self.squares[end]-self.squares[first]
            bb = self.squares[end+shift]-self.squares[first+shift]
            peak = max(abs(x) for x in self.samples[first+shift:end+shift])
            if not aa or not bb: result = Interval.point(0),peak
            else:
                ab = sum(self.values[i]*self.values[i+shift] for i in range(first,end))
                require(ab >= 0 and ab*ab <= aa*bb, 'Exact positive-correlation invariant failed')
                with localcontext() as context:
                    context.prec = 80
                    value = float(Decimal(ab)/Decimal(aa*bb).sqrt())
                error = math.nextafter(8*gamma(count)+4*math.ulp(1.),math.inf)
                result = Interval.outward(value-error,value+error),peak
        self.cache[key] = result
        return result

    def seed(self, midpoint):
        lower = midpoint-Interval.point(.5)/self.frequency
        upper = midpoint+Interval.point(.5)/self.frequency
        positions = []
        for first,last in product(self.indices(lower,'low'),self.indices(upper,'high')):
            first,last = max(0,first),min(len(self.samples)-1,last)
            require(last-first >= 2, 'Seed has insufficient support')
            index = max(range(first,last+1),key=lambda i:(abs(self.samples[i]),self.samples[i],-i))
            require(first < index < last, 'Source certificate requires an interior seed')
            left,middle,right = map(Interval.point,self.samples[index-1:index+2])
            denominator = middle*2-left-right
            offset = (right-left)*.5/denominator
            positions.append((Interval.point(index)+offset)*self.step+self.first)
        return Interval.hull(positions)

    def match(self, anchor, direction):
        period = Interval.point(1)/self.frequency
        near = anchor+Interval.point(direction*.8)/self.frequency
        far = anchor+Interval.point(direction*1.25)/self.frequency
        lower,upper = (near,far) if direction > 0 else (far,near)
        possibilities = [self.indices(anchor-period*.5,'nearest'),
            self.indices(anchor+period*.5,'nearest'),self.indices(lower-period*.5,'low'),
            self.indices(upper-period*.5,'high')]
        require(math.prod(map(len,possibilities)) <= MAX_GEOMETRIES, 'Too many window geometries')
        proposals = []
        for a,b,low,high in product(*possibilities):
            self.geometry_count += 1
            require(1 <= b-a+1 <= MAX_WINDOW and 2 <= high-low <= 1024, 'Invalid window geometry')
            rows = [(Interval.point(0),0.),(Interval.point(0),0.)]
            rows += [self.correlation(a,b,k) for k in range(low,high+1)]
            coefficients = [r[0] for r in rows]
            floor = max(c.low for c in coefficients[1:-1])
            require(floor > max(coefficients[0].high,coefficients[-1].high),
                    'Global maximum might be a nonselectable table endpoint')
            possible = [i for i in range(1,len(rows)-1)
                if coefficients[i].high >= floor
                and coefficients[i].high >= max(coefficients[i-1].low,coefficients[i+1].low)]
            require(possible and len(possible) <= 2, 'Unresolved source peak selection')
            self.peak_alternatives += len(possible)
            for i in possible:
                require(i >= 2, 'Synthetic candidate could win')
                left,middle,right = coefficients[i-1:i+2]
                curvature = (middle-left)+(middle-right)
                require(curvature.low > 128*math.ulp(1.), 'Unresolved source peak curvature')
                slope = (right-left)*.5
                offset = slope/curvature
                height = middle+slope*slope*.5/curvature
                require(height.low > .7 and rows[i+1][1] > .023333*self.global_peak,
                        'Source match acceptance is not guaranteed')
                fractional = Interval.point(low+i-2+1)+offset
                proposed = anchor+(fractional-(a+1))*self.step
                require(proposed.low >= lower.high and proposed.high <= upper.low,
                        'Source match could use range fallback')
                proposals.append(proposed)
        return Interval.hull(proposals)


def certify(case):
    require(case in cases(), 'Source case is outside the declared certificate catalog')
    samples,known = catalog.source(case)
    pitch = catalog.supplied_pitch(case)
    frequency = case['source']['frequencyHz']
    require(known and all(p['rendered'] for p in known)
            and all(f == frequency for f in pitch['frequenciesHz']), 'Incomplete/variable source F0')
    budget = source_budget(case,known)
    engine = Enclosure(samples,case['sampleRate'],frequency)
    left = max(0.,pitch['firstCenterSeconds']-.5*pitch['stepSeconds'])
    right = min(pitch['domainEndSeconds'],math.fma(len(pitch['frequenciesHz'])-1,
        pitch['stepSeconds'],pitch['firstCenterSeconds'])+.5*pitch['stepSeconds'])
    seed = engine.seed((Interval.point(left)+right)*.5)
    seed_index = min(range(len(known)),key=lambda i:abs(known[i]['timeSeconds']-(seed.low+seed.high)/2))
    require(max(seed_index,len(known)-1-seed_index) <= budget['maximumSteps'], 'Seed exceeds step budget')
    times = {seed_index:seed}
    for direction in (-1,1):
        anchor = seed
        for index in range(seed_index+direction, len(known) if direction > 0 else -1,direction):
            anchor = engine.match(anchor,direction)
            times[index] = anchor
    result = []
    for index,point in enumerate(known):
        bounds = times[index]
        require(left < bounds.low <= bounds.high < right,'Source enclosure leaves acquired/voiced support')
        error = (bounds-Interval.point(point['timeSeconds']))*case['sampleRate']
        maximum = max(abs(error.low),abs(error.high))
        require(maximum <= budget['radiusSamples'],f'{case["name"]}: source radius exceeded at {index}: {maximum} > {budget["radiusSamples"]}')
        result.append(dict(sourceIndex=index,sourceTimeSeconds=point['timeSeconds'],
            algorithmTimeSeconds=bounds.as_json(),sourceErrorSamples=error.as_json()))
    return dict(case=case,pitch=pitch,budget=budget,seedSourceIndex=seed_index,points=result,
                maximumSourceErrorSamples=max(max(abs(x) for x in p['sourceErrorSamples']) for p in result),
                maximumEnclosureWidthSamples=max((p['algorithmTimeSeconds'][1]-p['algorithmTimeSeconds'][0])*case['sampleRate'] for p in result),
                evaluatedGeometries=engine.geometry_count,peakAlternatives=engine.peak_alternatives,
                exactCorrelations=len(engine.cache))
