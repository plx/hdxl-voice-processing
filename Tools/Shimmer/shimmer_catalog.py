"""Original supplied-amplitude anchors and deterministic numerical stress cases."""
import math


def make_case(name, amplitudes, *, periods=None, start=1/256, gain=1.,
              scale=1., floor=1/512, ceiling=1/32, factor=1.6, query=None):
    values = [float(a * gain) for a in amplitudes]
    if periods is None:
        periods = [1/128] * max(0, len(values) - 1)
    if len(periods) != max(0, len(values) - 1):
        raise ValueError('Period count must match amplitude edges')
    times = [float(start * scale)] if values else []
    for period in periods:
        times.append(times[-1] + period * scale)
    end = max(.125 * scale, (times[-1] if times else 0.) + .03125 * scale)
    return dict(schemaVersion=1, name=name, timesSeconds=times, amplitudes=values,
        domainStartSeconds=0., domainEndSeconds=end,
        queryStartSeconds=query[0] if query else 0.,
        queryEndSeconds=query[1] if query else end,
        minimumPeriodSeconds=floor * scale, maximumPeriodSeconds=ceiling * scale,
        maximumAmplitudeFactor=factor)


def cases():
    result = [make_case(f'constant-{n}', [1.] * n) for n in range(14)]
    sequences = [
        ('alternating', [1., 1.25] * 6 + [1.]),
        ('linear-ramp', [1. + i/16 for i in range(13)]),
        ('sinusoidal', [1. + .1 * math.sin(2 * math.pi * i / 7) for i in range(29)]),
        ('outlier', [1.] * 6 + [8.] + [1.] * 6),
        ('zero-center', [1.] * 6 + [0.] + [1.] * 6),
        ('zero-leading', [0.] + [1., 1.25] * 6),
        ('zero-trailing', [1., 1.25] * 6 + [0.]),
        ('all-zero', [0.] * 13),
        ('dense-rejections', [1., 2., 4.] * 9),
        ('two-ascending', [1., 2.]), ('two-descending', [2., 1.]),
        ('excluded-normalization', [1., 2., 100., 4., 8.]),
        ('zero-normalization', [0., 1., 1., 2.])]
    for name, values in sequences:
        result.append(make_case(name, values, factor=2. if name in (
            'two-ascending', 'two-descending', 'excluded-normalization', 'zero-normalization') else 1.6))
    for name, values in sequences[:4]:
        result.append(make_case(name + '-reversed', list(reversed(values))))
        for suffix, gain in [('tiny', 2. ** -400), ('quiet', .125), ('loud', 8.), ('large', 2. ** 400)]:
            result.append(make_case(name + '-' + suffix, values, gain=gain))
        for suffix, scale in [('half-time', .5), ('double-time', 2.)]:
            result.append(make_case(name + '-' + suffix, values, scale=scale))
    for name, factor in [('below', math.nextafter(1.5, 0.)), ('equal', 1.5), ('above', math.nextafter(1.5, 2.))]:
        result.append(make_case('factor-' + name, [1., 1.5] * 6 + [1.], factor=factor))
    result.append(make_case('factor-one', [1., 1.125] * 6 + [1.], factor=1.))
    for name, floor, ceiling in [('equal', 1/256, 1/128),
                                ('floor-above', math.nextafter(1/256, 1.), 1/128),
                                ('ceiling-below', 1/256, math.nextafter(1/128, 0.))]:
        result.append(make_case('bounds-' + name, [1., 1.25] * 6 + [1.],
            periods=[1/256, 1/128] * 6, floor=floor, ceiling=ceiling))
    for name, periods in [
        ('split-runs', [1/128] * 5 + [1/16] + [1/128] * 5),
        ('alternating-gaps', [1/128, 1/16] * 6),
        ('apq11-outer-only-failure', [1/16] + [1/128] * 9),
        ('apq5-outer-only-failure', [1/1024] + [1/128] * 3)]:
        result.append(make_case(name, [1. + (i % 2)/4 for i in range(len(periods) + 1)], periods=periods))
    for name, query in [('empty', (.12, .124)), ('one', (0., 1/128)),
                        ('exact-edges', (5/256, 21/256)), ('inside-edges', (5.01/256, 20.99/256))]:
        result.append(make_case('crop-' + name, [1., 1.25] * 6 + [1.], query=query))
    state = 51001
    for index in range(24):
        amplitudes, periods = [], []
        for j in range(7 + index * 3):
            state = (1664525 * state + 1013904223) & 0xffffffff
            amplitudes.append((.5 + state / 4294967296) * (5 if j % 13 == 0 else 1))
            if j:
                periods.append((1 + .1 * (state / 4294967296 - .5)) / (80 + index * 20))
        result.append(make_case(f'rounded-sequence-{index}', amplitudes, periods=periods,
                               floor=.0001, ceiling=.02))
    if len(result) != len({c['name'] for c in result}):
        raise ValueError('Duplicate shimmer case names')
    return result
