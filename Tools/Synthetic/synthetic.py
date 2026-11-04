"""Original deterministic source models; no native analysis kernels or third-party packages."""
import copy
from decimal import Decimal, localcontext
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import struct
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
VERSION = 1
MAX_SAMPLES = 192000 * 3600
MAX_BLOCK = 65536
MAX_TABLE = 16384
MASK64 = (1 << 64) - 1
PI_DECIMAL = "3.141592653589793238462643383279502884197169399375105820974944592307816406286"
TAU = float.fromhex("0x1.921fb54442d18p+2")
# Taylor through x^25, evaluated on [-pi/2, pi/2] without fused operations.
SINE_COEFFICIENTS = tuple((-1.0 if k % 2 else 1.0) / math.factorial(2 * k + 1) for k in range(13))


class SyntheticError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise SyntheticError(message)


def integer(value, minimum, maximum, label):
    require(type(value) is int and minimum <= value <= maximum, f"Invalid {label}")
    return value


def finite(value, label):
    require(type(value) in (int, float) and math.isfinite(value), f"Invalid {label}")
    return float(value)


def rational(value):
    if type(value) is str:
        try:
            result = Fraction(value)
        except (ValueError, ZeroDivisionError) as error:
            raise SyntheticError("Invalid rational") from error
    elif type(value) in (int, float):
        finite(value, "rational")
        result = Fraction(str(value))
    elif type(value) is Fraction:
        result = value
    else:
        raise SyntheticError("Expected a finite number or rational string")
    require(abs(result.numerator) <= 10**24 and result.denominator <= 10**18, "Rational exceeds bounds")
    return result


def normalize(value):
    if isinstance(value, float):
        require(math.isfinite(value), "Nonfinite JSON")
        return int(value) if value.is_integer() else value
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value)
    if isinstance(value, list):
        return [normalize(v) for v in value]
    if isinstance(value, dict):
        result = {normalize(k): normalize(v) for k, v in value.items()}
        require(len(result) == len(value), "Duplicate normalized key")
        return result
    return value


def canonical(value):
    return json.dumps(normalize(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    Path(path).write_bytes(canonical(value) + b"\n")


def load_json(path):
    def pairs(items):
        result = dict(items)
        require(len(result) == len(items), "Duplicate JSON key")
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(SyntheticError("Nonfinite JSON")))


def sine_phase(numerator, denominator):
    """Rational-turn oscillator: exact cardinal points, <=5e-15 tested absolute error."""
    phase = numerator % denominator
    if (phase * 4) % denominator == 0:
        return (0.0, 1.0, 0.0, -1.0)[(phase * 4 // denominator) % 4]
    sign = 1.0
    if 2 * phase > denominator:
        phase = denominator - phase
        sign = -1.0
    if 4 * phase > denominator:
        phase = Fraction(denominator, 2) - phase
    x = float(phase / denominator) * TAU
    squared = x * x
    polynomial = SINE_COEFFICIENTS[-1]
    for coefficient in reversed(SINE_COEFFICIENTS[:-1]):
        polynomial = coefficient + squared * polynomial
    return sign * x * polynomial


class SplitMix64:
    """Specified unsigned-64 recurrence and top-53-bit uniform conversion."""
    def __init__(self, seed):
        self.state = integer(seed, 0, MASK64, "seed")

    def next_word(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def uniform(self):
        return (self.next_word() >> 11) * (2.0**-52) - 1.0


def pole_section(frequency_hz, bandwidth_hz, rate):
    frequency, bandwidth = rational(frequency_hz), rational(bandwidth_hz)
    require(0 < frequency < Fraction(rate, 2) and 0 < bandwidth < rate, "Invalid formant/bandwidth")
    with localcontext() as context:
        context.prec = 80
        exponent = -Decimal(PI_DECIMAL) * Decimal(bandwidth.numerator) / Decimal(bandwidth.denominator * rate)
        radius = float(exponent.exp())
    require(0 < radius < 1, "Pole radius is not strictly stable in binary64")
    angle_turns = frequency / rate
    cosine_phase = angle_turns + Fraction(1, 4)
    cosine = sine_phase(cosine_phase.numerator, cosine_phase.denominator)
    a1, a2 = -2 * radius * cosine, radius * radius
    gain = 1 + a1 + a2
    require(gain > 0 and 1 - a1 + a2 > 0, "Rounded coefficients lose strict stability/DC normalization")
    return {"frequencyHz": float(frequency), "bandwidthHz": float(bandwidth), "radius": radius,
            "angleTurns": str(angle_turns), "denominator": [1, a1, a2], "numerator": [gain],
            "normalization": "each section has unit DC response"}


def transfer(sections, frequency_hz, rate):
    """Independent algebraic transfer response; does not run the recursive renderer."""
    turns = rational(frequency_hz) / rate
    sine = sine_phase(turns.numerator, turns.denominator)
    cosine_turns = turns + Fraction(1, 4)
    cosine = sine_phase(cosine_turns.numerator, cosine_turns.denominator)
    inverse_z = complex(cosine, -sine)
    response = 1 + 0j
    for section in sections:
        _, a1, a2 = section["denominator"]
        response *= section["numerator"][0] / (1 + a1 * inverse_z + a2 * inverse_z * inverse_z)
    return response


def selection(count, missing):
    result, cursor = [], 0
    for span in missing:
        require(set(span) == {"startSample", "sampleCount"}, "Unknown missing-interval field")
        start = integer(span["startSample"], 0, count, "missing start")
        length = integer(span["sampleCount"], 1, count, "missing length")
        require(start >= cursor and start + length <= count, "Missing intervals overlap or exceed support")
        if start > cursor:
            result.append({"startSample": cursor, "sampleCount": start - cursor, "included": True, "reason": None})
        result.append({"startSample": start, "sampleCount": length, "included": False, "reason": "deliberatelyMissing"})
        cursor = start + length
    if cursor < count:
        result.append({"startSample": cursor, "sampleCount": count - cursor, "included": True, "reason": None})
    return result


def validate_recipe(recipe):
    required = {"schemaVersion", "identifier", "sampleRate", "sampleCount", "source", "gain", "clip",
                "formants", "initialFilterState", "missingIntervals"}
    require(type(recipe) is dict and set(recipe) == required, "Unknown/missing recipe fields")
    integer(recipe["schemaVersion"], 1, VERSION, "schema version")
    identifier = recipe["identifier"]
    require(type(identifier) is dict and set(identifier) == {"name", "version"}, "Invalid identifier")
    require(type(identifier["name"]) is str and 1 <= len(identifier["name"]) <= 64
            and all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in identifier["name"]), "Invalid identifier name")
    integer(identifier["version"], 1, 2**32 - 1, "identifier version")
    rate = integer(recipe["sampleRate"], 1000, 192000, "sample rate")
    count = integer(recipe["sampleCount"], 0, MAX_SAMPLES, "sample count")
    require(abs(finite(recipe["gain"], "gain")) <= 1024, "Excessive gain")
    require(type(recipe["clip"]) is bool, "clip must be boolean")
    require(type(recipe["formants"]) is list and len(recipe["formants"]) <= 8, "Invalid formant list")
    for formant in recipe["formants"]:
        require(type(formant) is dict and set(formant) == {"frequencyHz", "bandwidthHz"}, "Invalid formant")
        pole_section(formant["frequencyHz"], formant["bandwidthHz"], rate)
    require(type(recipe["initialFilterState"]) is list and len(recipe["initialFilterState"]) == len(recipe["formants"]), "Filter state size mismatch")
    for state in recipe["initialFilterState"]:
        require(type(state) is list and len(state) == 2, "Expected y[-1], y[-2] state")
        for value in state:
            require(abs(finite(value, "filter state")) <= 1e6, "Excessive filter state")
    require(type(recipe["missingIntervals"]) is list, "Expected explicit missing intervals")
    selection(count, recipe["missingIntervals"])
    source = recipe["source"]
    require(type(source) is dict and type(source.get("kind")) is str, "Invalid source")
    kind = source["kind"]
    fields = {"dc": {"kind", "value"}, "impulse": {"kind", "index", "amplitude"},
              "harmonics": {"kind", "components"}, "noise": {"kind", "seed", "amplitude"},
              "pulses": {"kind", "startSeconds", "periodsSeconds", "amplitudes"}}
    require(kind in fields and set(source) == fields[kind], "Unknown source fields/kind")
    if kind == "dc":
        finite(source["value"], "DC value")
    elif kind == "impulse":
        integer(source["index"], 0, max(0, count - 1), "impulse index")
        finite(source["amplitude"], "impulse amplitude")
    elif kind == "harmonics":
        require(type(source["components"]) is list and 1 <= len(source["components"]) <= 64, "Invalid components")
        for component in source["components"]:
            require(type(component) is dict and set(component) == {"frequencyHz", "amplitude", "phaseTurns"}, "Invalid component")
            require(0 <= rational(component["frequencyHz"]) <= Fraction(rate, 2), "Frequency exceeds Nyquist")
            finite(component["amplitude"], "amplitude")
            rational(component["phaseTurns"])
    elif kind == "noise":
        integer(source["seed"], 0, MASK64, "seed")
        require(finite(source["amplitude"], "noise amplitude") >= 0, "Negative noise amplitude")
    else:
        require(type(source["periodsSeconds"]) is list and len(source["periodsSeconds"]) <= 100000, "Invalid periods")
        require(type(source["amplitudes"]) is list and len(source["amplitudes"]) == len(source["periodsSeconds"]) + 1, "Pulse amplitude count mismatch")
        start = rational(source["startSeconds"])
        require(start >= 0, "Negative pulse start")
        for period in source["periodsSeconds"]:
            require(rational(period) > 0, "Nonpositive pulse period")
        require(start + sum(map(rational, source["periodsSeconds"])) < Fraction(count, rate), "Pulse sequence exceeds support")
        for amplitude in source["amplitudes"]:
            require(finite(amplitude, "pulse amplitude") >= 0, "Negative pulse amplitude")
    return recipe


class Renderer:
    """Single-owner state; absolute rational phase and persistent PRNG/filter state."""
    def __init__(self, recipe):
        self.recipe = copy.deepcopy(validate_recipe(recipe))
        recipe = self.recipe
        self.position = 0
        self.rate = recipe["sampleRate"]
        self.count = recipe["sampleCount"]
        self.sections = [pole_section(f["frequencyHz"], f["bandwidthHz"], self.rate) for f in recipe["formants"]]
        self.filter_state = [list(map(float, state)) for state in recipe["initialFilterState"]]
        self.clipped = 0
        self.peak_before_clipping = 0.0
        self.source = recipe["source"]
        self.kind = self.source["kind"]
        self.noise = SplitMix64(self.source["seed"]) if self.kind == "noise" else None
        self.components = []
        self.table = None
        self.pulses = {}
        self.pulse_metadata = None
        if self.kind == "harmonics":
            period = 1
            for component in self.source["components"]:
                step = rational(component["frequencyHz"]) / self.rate
                phase = rational(component["phaseTurns"])
                denominator = math.lcm(step.denominator, phase.denominator)
                self.components.append((step.numerator * (denominator // step.denominator),
                                        phase.numerator * (denominator // phase.denominator),
                                        denominator, float(component["amplitude"])))
                period = math.lcm(period, step.denominator)
            if period <= MAX_TABLE:
                self.table = [self._harmonics(i) for i in range(period)]
        elif self.kind == "pulses":
            times = [rational(self.source["startSeconds"])]
            for period in self.source["periodsSeconds"]:
                times.append(times[-1] + rational(period))
            indices = [round(t * self.rate) for t in times]  # rational ties-to-even
            require(all(0 <= i < self.count for i in indices), "Rounded pulse exceeds support")
            require(len(set(indices)) == len(indices), "Pulse collisions after sample-grid rounding")
            self.pulses = dict(zip(indices, self.source["amplitudes"]))
            self.pulse_metadata = {"requestedSeconds": [str(t) for t in times], "renderedSampleIndices": indices,
                "rounding": "nearest sample, exact rational ties-to-even; delta impulses",
                "errorsSeconds": [str(Fraction(i, self.rate) - t) for i, t in zip(indices, times)]}

    def _harmonics(self, index):
        return math.fsum(amplitude * sine_phase(phase + index * step, denominator)
                         for step, phase, denominator, amplitude in self.components)

    def read(self, count):
        integer(count, 1, MAX_BLOCK, "block length")
        end = min(self.count, self.position + count)
        values = []
        for index in range(self.position, end):
            if self.kind == "dc":
                value = float(self.source["value"])
            elif self.kind == "impulse":
                value = float(self.source["amplitude"]) if index == self.source["index"] else 0.0
            elif self.kind == "harmonics":
                value = self.table[index % len(self.table)] if self.table is not None else self._harmonics(index)
            elif self.kind == "noise":
                value = self.noise.uniform() * self.source["amplitude"]
            else:
                value = float(self.pulses.get(index, 0.0))
            for section, state in zip(self.sections, self.filter_state):
                _, a1, a2 = section["denominator"]
                output = section["numerator"][0] * value - a1 * state[0] - a2 * state[1]
                state[1], state[0] = state[0], output
                value = output
            value *= self.recipe["gain"]
            require(math.isfinite(value), "Nonfinite rendered sample")
            self.peak_before_clipping = max(self.peak_before_clipping, abs(value))
            if abs(value) > 1:
                require(self.recipe["clip"], "Rendered sample exceeds normalized range; choose gain or explicit clipping")
                self.clipped += 1
                value = max(-1.0, min(1.0, value))
            values.append(0.0 if value == 0 else value)
        self.position = end
        return values

    def snapshot(self):
        return {"position": self.position, "filterState": [state.copy() for state in self.filter_state],
                "prngState": self.noise.state if self.noise else None,
                "clippedSampleCount": self.clipped, "peakBeforeClipping": self.peak_before_clipping,
                "oscillatorTableSamples": len(self.table) if self.table else 0}


def render(recipe, block=4096):
    renderer = Renderer(recipe)
    require(recipe["sampleCount"] <= 192000, "Use streaming Renderer for benchmark-sized inputs")
    samples = []
    while renderer.position < renderer.count:
        samples.extend(renderer.read(block))
    return samples, renderer


def wave_header(rate, count):
    integer(rate, 1000, 192000, "sample rate")
    integer(count, 0, min(MAX_SAMPLES, (2**32 - 1 - 48) // 8), "WAVE sample count")
    return (b"RIFF" + struct.pack("<I", 48 + count * 8) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 1, rate, rate * 8, 8, 64)
            + b"fact" + struct.pack("<II", 4, count) + b"data" + struct.pack("<I", count * 8))


def pcm_bytes(samples):
    require(all(type(v) in (float, int) and math.isfinite(v) and abs(v) <= 1 for v in samples), "Invalid normalized PCM")
    return struct.pack(f"<{len(samples)}d", *samples)


def wave(samples, rate):
    return wave_header(rate, len(samples)) + pcm_bytes(samples)


def mix_noise(signal, noise, snr_db):
    """Scale a supplied independent noise realization; never infer an HNR estimate."""
    require(len(signal) == len(noise) and 0 < len(signal) <= 192000, "Noise/input length mismatch or empty")
    require(all(type(v) in (int, float) and math.isfinite(v) and abs(v) <= 1 for values in (signal, noise) for v in values), "Mixture components must be finite normalized PCM")
    snr = finite(snr_db, "SNR")
    require(-120 <= snr <= 120, "SNR exceeds bounds")
    signal_energy = math.fsum(x * x for x in signal)
    noise_energy = math.fsum(x * x for x in noise)
    require(signal_energy > 0 and noise_energy > 0, "SNR unavailable for zero-energy components")
    with localcontext() as context:
        context.prec = 80
        ratio = float((Decimal(str(-snr)) / 10 * Decimal(10).ln()).exp())
    scale = math.sqrt(signal_energy * ratio / noise_energy)
    scaled = [x * scale for x in noise]
    mixture = [x + y for x, y in zip(signal, scaled)]
    require(all(math.isfinite(v) and abs(v) <= 1 for v in mixture), "Mixture exceeds normalized range; reduce source gain")
    return mixture, {"requestedSNRDB": snr, "noiseScale": scale,
        "sourceEnergy": signal_energy, "noiseEnergyBeforeScaling": noise_energy,
        "noiseEnergyAfterScaling": math.fsum(v * v for v in scaled),
        "crossTerm": 2 * math.fsum(x * y for x, y in zip(signal, scaled)),
        "definition": "10*log10(sum(source^2)/sum(scaledNoise^2)); not an estimator HNR or total-mixture energy ratio"}
