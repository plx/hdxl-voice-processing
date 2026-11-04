"""Small, dependency-free reference identity, PCM and outcome helpers."""
import hashlib
import json
import math
from pathlib import Path
import struct
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
MAX_SAMPLES = 48000 * 60


class ReferenceError(ValueError):
    pass


class UnsupportedInput(ReferenceError):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


class ReferenceFailure(ReferenceError):
    pass


def normalize(value):
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ReferenceError("Nonfinite JSON value")
        return int(value) if value.is_integer() else value
    if isinstance(value, str):
        return unicodedata.normalize("NFC", value)
    if isinstance(value, list):
        return [normalize(v) for v in value]
    if isinstance(value, dict):
        result = {normalize(k): normalize(v) for k, v in value.items()}
        if len(result) != len(value):
            raise ReferenceError("Keys collide after NFC normalization")
        return result
    return value


def canonical(value):
    return json.dumps(normalize(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_json(path):
    def object_pairs(pairs):
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ReferenceError("Duplicate JSON key")
        return result
    return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=object_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ReferenceError("Nonfinite JSON")))


def write_json(path, value):
    Path(path).write_bytes(canonical(value) + b"\n")


def outcome(value):
    if value is None:
        return {"status": "unavailable", "reason": "analysisFailure"}
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ReferenceFailure("Expected finite reference number or explicit undefined")
    return {"status": "available", "estimate": {"value": value, "confidence": None, "warnings": []}}


def number(token):
    if token == "--undefined--":
        return None
    try:
        value = float(token)
    except ValueError as error:
        raise ReferenceFailure("Malformed reference number") from error
    if not math.isfinite(value):
        raise ReferenceFailure("Unexpected NaN/infinity; not converted to zero")
    return 0.0 if value == 0 else value


def pcm_wave(samples, rate):
    """Encode normalized mono PCM losslessly as a little-endian Float64 WAVE."""
    validate_pcm(samples, rate)
    data = struct.pack(f"<{len(samples)}d", *samples)
    fmt = struct.pack("<HHIIHH", 3, 1, rate, rate * 8, 8, 64)
    chunks = b"fmt " + struct.pack("<I", 16) + fmt + b"fact" + struct.pack("<II", 4, len(samples))
    chunks += b"data" + struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(chunks) + 4) + b"WAVE" + chunks


def validate_pcm(samples, rate):
    if type(rate) is not int or not 1000 <= rate <= 192000:
        raise UnsupportedInput("unsupportedRange")
    if not samples:
        raise UnsupportedInput("insufficientData")
    if len(samples) > MAX_SAMPLES:
        raise UnsupportedInput("unsupportedRange")
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or abs(v) > 1 for v in samples):
        raise UnsupportedInput("invalidInput")


def read_pcm(path):
    if Path(path).stat().st_size > MAX_SAMPLES * 8 + 4096:
        raise UnsupportedInput("unsupportedRange")
    data = Path(path).read_bytes()
    if len(data) > MAX_SAMPLES * 8 + 4096 or len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise UnsupportedInput("invalidInput")
    if struct.unpack_from("<I", data, 4)[0] + 8 != len(data):
        raise UnsupportedInput("invalidInput")
    chunks = {}
    cursor = 12
    while cursor < len(data):
        if cursor + 8 > len(data):
            raise UnsupportedInput("invalidInput")
        name = data[cursor:cursor + 4]
        count = struct.unpack_from("<I", data, cursor + 4)[0]
        cursor += 8
        if cursor + count > len(data) or name in chunks:
            raise UnsupportedInput("invalidInput")
        chunks[name] = data[cursor:cursor + count]
        cursor += count + count % 2
    if cursor != len(data) or b"fmt " not in chunks or b"data" not in chunks or len(chunks[b"fmt "]) != 16:
        raise UnsupportedInput("invalidInput")
    encoding, channels, rate, byte_rate, align, bits = struct.unpack("<HHIIHH", chunks[b"fmt "])
    if channels != 1 or (encoding, bits) not in ((1, 16), (3, 32), (3, 64)):
        raise UnsupportedInput("unsupportedRange")
    if align != bits // 8 or byte_rate != rate * align or len(chunks[b"data"]) % align:
        raise UnsupportedInput("invalidInput")
    code = {(1, 16): "h", (3, 32): "f", (3, 64): "d"}[encoding, bits]
    values = [v[0] for v in struct.iter_unpack("<" + code, chunks[b"data"])]
    samples = [v / 32768.0 for v in values] if encoding == 1 else values
    if b"fact" in chunks and (len(chunks[b"fact"]) != 4 or struct.unpack("<I", chunks[b"fact"])[0] != len(samples)):
        raise UnsupportedInput("invalidInput")
    validate_pcm(samples, rate)
    normalized = struct.pack(f"<{len(samples)}d", *samples)
    return samples, {"artifactSHA256": digest(data), "normalizedFloat64LESHA256": digest(normalized),
                     "sampleRate": rate, "sampleCount": len(samples), "channelCount": 1,
                     "sourceEncoding": f"{'signedInt' if encoding == 1 else 'float'}{bits}",
                     "normalization": "signedInt16 / 32768; IEEE floats unchanged"}
