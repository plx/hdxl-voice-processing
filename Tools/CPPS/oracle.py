"""Original analytic basis-function integration; no reference implementation code.

The integral of each triangular interpolation basis supplies a coefficient. Endpoint
bases also include constant half-cell caps, clipped to the object's domain. This
oracle intentionally differs from the runtime's segmented quadrature traversal.
"""
import math


def triangle_integral(x):
    if x <= -1: return 0.0
    if x <= 0: return (x + 1) ** 2 / 2
    if x < 1: return 1 - (1 - x) ** 2 / 2
    return 1.0


def weights(count, center, width, domain_lower, domain_upper):
    left = max(center - width / 2, domain_lower, -0.5)
    right = min(center + width / 2, domain_upper, count - 0.5)
    if not left < right: raise ValueError('Empty averaging support')
    # Singleton has a constant basis on its complete clipped cell.
    if count == 1: return [(0, 1.0)]
    result = []
    for index in range(max(0, math.floor(left)), min(count, math.ceil(right) + 1)):
        a, b = max(0.0, left), min(float(count - 1), right)
        area = triangle_integral(b - index) - triangle_integral(a - index) if a < b else 0
        if index == 0: area += max(0, min(0, right) - left)
        if index == count - 1: area += max(0, right - max(count - 1, left))
        if area > 0: result.append((index, area / (right - left)))
    if abs(math.fsum(weight for _, weight in result) - 1) > 1e-12:
        raise ValueError('Basis weights do not sum to one')
    return result


def smooth(values, frames, bins, time_width, q_width, hop, qstep,
           first_center, duration):
    if len(values) != frames * bins: raise ValueError('Matrix shape mismatch')
    time_weights = [weights(frames, i, time_width / hop, -first_center / hop,
                           (duration - first_center) / hop)
                    if math.floor(time_width / hop) > 1 else [(i, 1.0)]
                    for i in range(frames)]
    q_weights = [weights(bins, i, q_width / qstep, 0, bins - 1)
                if math.floor(q_width / qstep) > 1 else [(i, 1.0)]
                for i in range(bins)]
    temporal = [math.fsum(values[row * frames + i] * w for i, w in time_weights[col])
                for row in range(bins) for col in range(frames)]
    return [math.fsum(temporal[i * frames + col] * w for i, w in q_weights[row])
            for row in range(bins) for col in range(frames)]
