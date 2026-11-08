"""Comparison policy declared before native HNR implementation/comparison."""
import math

PEAK_POLICY = {
    'identifier': 'positiveLocalMaximumCurvature128Binary64Ulps-v1',
    'minimumCurvature': 128 * math.ulp(1.),
    'curvature': '(middle-left)+(middle-right)',
    'equality': 'reject at or below the minimum; retain rejection diagnostics',
    'purpose': 'native numerical resolution policy, distinct from the pinned external candidate test',
}

COMPARISON = {
    'countsIndicesStatuses': 'exact',
    'axisAbsoluteSeconds': 1e-12,
    'referenceAggregateAbsoluteDB': 1e-10,
    'moderateRangeAbsoluteDB': 1e-4,
    'moderateRangeMaximumAbsoluteDB': 60.,
    'extremeFractionAbsolute': 2e-14,
    'extremeFractionRelative': 1e-4,
    'purpose': 'native versus pinned reference; extreme dB compared in its small energy fraction',
    'limitPolicy': 'reporting limits are distinct states, not exact finite HNR or proven physical noise absence',
}


def finite(value):
    return type(value) in (int,float) and math.isfinite(value)


def reference_state(db):
    if not finite(db) or (not -150 <= db <= 150 and db != -200):
        raise ValueError('Invalid raw HNR reference value')
    if db == -200:
        return {'status':'unavailable','valueDB':None,'periodicity':None,'noiseFraction':None}
    if abs(db)==150:
        return {'status':'upperReportingLimit' if db>0 else 'lowerReportingLimit',
                'valueDB':db,'periodicity':None,'noiseFraction':None}
    power_ratio=10**(db/10)
    noise=1/(1+power_ratio)
    periodicity=power_ratio/(1+power_ratio)
    return {'status':'finite','valueDB':db,'periodicity':periodicity,'noiseFraction':noise}


def comparison_fraction(actual_db, expected_db):
    """Budget use; callers must separately compare availability/limit state."""
    if not finite(actual_db) or not finite(expected_db):
        raise ValueError('Expected finite comparable dB')
    if not -150<=actual_db<=150 or not -150<=expected_db<=150:
        raise ValueError('Unavailable sentinel/out-of-range HNR is not comparable')
    if abs(expected_db)<=COMPARISON['moderateRangeMaximumAbsoluteDB']:
        return abs(actual_db-expected_db)/COMPARISON['moderateRangeAbsoluteDB']
    # Avoid subtracting an almost-unit periodicity to recover tiny noise energy.
    def fraction(db):
        return 1/(1+10**(db/10)) if expected_db>0 else 1/(1+10**(-db/10))
    expected=fraction(expected_db)
    return abs(fraction(actual_db)-expected)/(COMPARISON['extremeFractionAbsolute']
                                            +COMPARISON['extremeFractionRelative']*expected)
