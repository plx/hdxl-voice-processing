"""Independent quadrature and temporal GM/AM checks of external spectral matrices."""
import math


def mean(row, center, halfwidth, axes):
    left = max(center-halfwidth, -.5, (axes['minimumTime']-axes['firstCenter'])/axes['hop'])
    right = min(center+halfwidth, len(row)-.5, (axes['maximumTime']-axes['firstCenter'])/axes['hop'])
    if left >= right:
        raise ValueError('Empty averaging support')
    knots = [left] + list(range(max(0, math.floor(left)+1), min(len(row), math.ceil(right)))) + [right]
    def value(x):
        if x <= 0: return row[0]
        if x >= len(row)-1: return row[-1]
        index = math.floor(x)
        fraction = x-index
        return row[index]*(1-fraction) + row[index+1]*fraction
    return math.fsum((b-a)*(value(a)+value(b))*.5 for a,b in zip(knots,knots[1:]))/(right-left)


def flatness(rows, axes, profile, emulate_row_one_mutation=False):
    first = max(1, math.floor(profile['minimumFrequencyHz']/axes['frequencyStep']))-1
    last = min(len(rows), math.floor(profile['maximumFrequencyHz']/axes['frequencyStep']))
    long_count = math.floor(profile['longWindowSeconds']/axes['hop']+.5)
    short_enabled = math.floor(profile['shortWindowSeconds']/axes['hop']) > 1
    total = [0.]*len(rows[0])
    for index in range(first,last):
        row = rows[index][:]
        smooth = []
        for frame in range(len(row)):
            power = mean(row, frame, profile['shortWindowSeconds']/2/axes['hop'], axes) if short_enabled else row[frame]
            smooth.append(power)
            if emulate_row_one_mutation and index == 0: row[frame] = power
        for frame in range(len(row)):
            positive = [value for value in smooth[max(0,frame-long_count+1):frame+1] if value>0]
            if positive:
                total[frame] += math.fsum(math.log10(value) for value in positive)/len(positive) - math.log10(math.fsum(positive)/len(positive))
    return total


def reference_intensity(rows, axes):
    first = max(1, math.floor(80/axes['frequencyStep']))-1
    last = min(len(rows), math.ceil(8000/axes['frequencyStep']))
    powers = [math.fsum(row[i] for row in rows[first:last])/4e-10 for i in range(len(rows[0]))]
    averaged = [mean(powers, i, .032/axes['hop'], axes) for i in range(len(powers))]
    return [-300. if power < 1e-30 else 10*math.log10(power) for power in averaged]
