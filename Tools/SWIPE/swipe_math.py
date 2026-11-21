"""Original scalar mathematical anchors for SWIPE-prime reference development.

Camacho & Harris (2008), DOI 10.1121/1.2951592, equations 7, 12,
15--17 and 19--21. These functions neither import nor execute native code
or a third-party SWIPE implementation. They do not yet define a complete
discrete analyzer profile; its sampling and boundary policies are separate.
"""
import math


def _finite(value):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError('Expected a finite real number')
    return float(value)


def erb_rate(frequency_hz):
    """Equation 7, with the paper's 229 Hz constant, including zero."""
    frequency_hz = _finite(frequency_hz)
    if frequency_hz < 0:
        raise ValueError('Frequency cannot be negative')
    return 21.4 * math.log1p(frequency_hz / 229.) / math.log(10.)


def erb_frequency(rate):
    """Inverse of equation 7; reject unrepresentable results explicitly."""
    rate = _finite(rate)
    if rate < 0:
        raise ValueError('ERB rate cannot be negative')
    try:
        frequency = 229. * math.expm1(rate * math.log(10.) / 21.4)
    except OverflowError as error:
        raise ValueError('Frequency is not representable') from error
    if not math.isfinite(frequency):
        raise ValueError('Frequency is not representable')
    return frequency


def is_prime(number):
    """Exact integer predicate, independent of any native kernel table."""
    if type(number) is not int or number < 0:
        raise ValueError('Expected a nonnegative integer')
    if number < 2:
        return False
    return all(number % divisor for divisor in range(2, math.isqrt(number) + 1))


def harmonic_lobe(frequency_ratio, harmonic):
    """One equation-16 component, before the 1/sqrt(frequency) envelope.

    Adjacent included harmonics each contribute half a valley. Summing
    components is essential: the valleys between 1/2 and 2/3 have full
    weight, whereas a valley adjacent to just one prime has half weight.
    At either quarter-period boundary the mathematical value is exactly 0.
    """
    ratio = _finite(frequency_ratio)
    if ratio < 0 or type(harmonic) is not int or harmonic < 1:
        raise ValueError('Invalid frequency ratio or harmonic')
    distance = abs(ratio - harmonic)
    if distance == .25 or distance >= .75:
        return 0.
    weight = 1. if distance < .25 else .5
    # Reduce the argument about the selected harmonic to avoid loss of
    # phase accuracy from unnecessarily large integer multiples of 2*pi.
    return weight * math.cos(2. * math.pi * (ratio - harmonic))


def pitch_strength(loudness, weighted_kernel):
    """Equation-12 normalized product on an already selected discrete grid.

    Loudness is sqrt(magnitude), not power. The *positive part* of the
    kernel supplies its L2 normalization, but negative kernel entries
    remain in the numerator. Scores can therefore be negative, including
    less than -1; they are not probabilities. None means zero norm, not
    a numerical score of zero. Common grid-step factors cancel.
    """
    if not loudness or len(loudness) != len(weighted_kernel):
        raise ValueError('Equal nonempty vectors are required')
    values = [_finite(x) for x in loudness]
    kernel = [_finite(x) for x in weighted_kernel]
    if any(x < 0 for x in values):
        raise ValueError('Loudness cannot be negative')
    signal_scale = max(values)
    kernel_scale = max(0., max(kernel))
    if signal_scale == 0 or kernel_scale == 0:
        return None
    signal = [x / signal_scale for x in values]
    scaled_kernel = [x / kernel_scale for x in kernel]
    if not all(math.isfinite(x) for x in scaled_kernel):
        raise ValueError('Kernel normalization is not representable')
    signal_energy = math.fsum(x * x for x in signal)
    positive_energy = math.fsum(max(0., x) ** 2 for x in scaled_kernel)
    try:
        numerator = math.fsum(x * y for x, y in zip(signal, scaled_kernel))
        result = numerator / math.sqrt(signal_energy * positive_energy)
    except (OverflowError, ValueError) as error:
        raise ValueError('Pitch strength is not representable') from error
    if not math.isfinite(result):
        raise ValueError('Pitch strength is not representable')
    return result


def window_pair(sample_rate, candidate_hz):
    """Equations 17 and 19--21: bracket the eight-period Hann support.

    Return both neighboring powers of two and the upper-window weight.
    The upper window has zero weight at an exact power-of-two optimum;
    its presence in this tuple does not require evaluating it.
    """
    rate, candidate = _finite(sample_rate), _finite(candidate_hz)
    if rate <= 0 or candidate <= 0:
        raise ValueError('Sample rate and candidate must be positive')
    periods = rate / candidate
    if not math.isfinite(periods) or not .125 <= periods <= 2. ** 27:
        raise ValueError('Window geometry outside bounded reference domain')
    logarithm = math.log2(periods) + 3.
    lower_exponent = math.floor(logarithm)
    fraction = logarithm - lower_exponent
    return 2 ** lower_exponent, 2 ** (lower_exponent + 1), fraction
