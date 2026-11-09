"""Original point sequences: exact dyadic anchors and explicitly rounded stress cases."""
import math


def make_case(name, periods, *, scale=1., start=0., floor=.5/256, ceiling=8/256, factor=1.3, query=None):
    points = [float(start)]
    for period in periods:
        points.append(points[-1] + period * scale)
    domain_end = max(.125 * scale, points[-1] + .03125 * scale)
    return {'schemaVersion': 1, 'name': name, 'pointsSeconds': points,
            'domainStartSeconds': 0., 'domainEndSeconds': domain_end,
            'queryStartSeconds': query[0] if query else 0.,
            'queryEndSeconds': query[1] if query else domain_end,
            'minimumPeriodSeconds': floor * scale, 'maximumPeriodSeconds': ceiling * scale,
            'maximumAdjacentFactor': factor}


def cases():
    result = []
    def add(name, units, **kwargs):
        result.append(make_case(name, [u / 256 for u in units], **kwargs))
    for count in range(8):
        add(f'constant-{count}', [2] * count)
    # An empty object differs from a one-point object (both have zero periods).
    empty = make_case('empty', [])
    empty['pointsSeconds'] = []
    result.append(empty)
    for name, values in [
        ('alternating', [2, 2.25] * 6), ('linear-ramp', [2 + i/8 for i in range(12)]),
        ('outlier', [2] * 5 + [5] + [2] * 5), ('leading-isolated', [1, 2, 2.125]),
        ('trailing-isolated', [2.125, 2, 1]), ('interior-isolated', [2, 2.125, 1, 2, 2.125]),
        ('leading-too-short', [.25, 2, 2.125]), ('leading-too-long', [16, 2, 2.125]),
        ('two-distant', [1, 2]), ('ppq5-outer-only-failure', [1, 2, 2.125, 2, 2.125]),
        ('dense-rejections', [1, 2, 4] * 8), ('split-runs', [2, 2.125, 2, 16, 2, 2.125, 2]),
        ('alternating-gaps', [2, 2.125, 16] * 5), ('ramp-boundaries', [i / 2 for i in range(1, 20)])]:
        add(name, values)
    for name, units in [('alternating', [2, 2.25] * 6), ('linear-ramp', [2 + i/8 for i in range(12)]),
                        ('outlier', [2] * 5 + [5] + [2] * 5)]:
        for scale in (.5, 2.):
            add(name + ('-half-time' if scale == .5 else '-double-time'), units, scale=scale)
    add('factor-one', [2, 2.125, 2, 2.125, 2], factor=1.)
    for name, factor in [('below', math.nextafter(1.5, 0.)), ('equal', 1.5), ('above', math.nextafter(1.5, 2.))]:
        add('factor-' + name, [2, 3, 2, 3, 2], factor=factor)
    for name, floor, ceiling in [('equal', 2/256, 3/256),
                                ('floor-above', math.nextafter(2/256, 1.), 3/256),
                                ('ceiling-below', 2/256, math.nextafter(3/256, 0.))]:
        add('bounds-' + name, [2, 3, 2, 3, 2], factor=1.5, floor=floor, ceiling=ceiling)
    add('invalid-neighbors-similar', [1.75, 2, 1.75], floor=2/256)
    add('invalid-neighbors-distant', [.25, 2, .25])
    for name, units, query in [
        ('isolated-center', [2, 1, 2], [2/256, 3/256]),
        ('isolated-first', [2, 1, 2, 2.125], [2/256, 7.125/256]),
        ('isolated-last', [2.125, 2, 1, 2], [0, 5.125/256]),
        ('one-point', [2, 2.125], [0, .001]), ('empty', [2, 2.125], [.05, .06]),
        ('exact-edges', [2, 2.125, 2, 2.125, 2, 2.125], [2/256, 10.25/256]),
        ('inside-edges', [2, 2.125, 2, 2.125, 2, 2.125], [2.01/256, 10.24/256])]:
        add('crop-' + name, units, query=query)
    # Deterministic, bounded non-dyadic point sums exercise representation error.
    state = 50001
    for index in range(24):
        periods = []
        for j in range(6 + index * 3):
            state = (1664525 * state + 1013904223) & 0xffffffff
            p = (1 + .35 * (state / 4294967296 - .5)) / (80 + index * 20)
            periods.append(p * (4 if index % 3 == 0 and j % 7 == 0 else 1))
        result.append(make_case(f'rounded-sequence-{index}', periods, floor=.0001, ceiling=.02))
    assert len(result) == len({c['name'] for c in result})
    return result
