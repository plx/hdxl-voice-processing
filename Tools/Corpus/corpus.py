#!/usr/bin/env python3
"""Offline, deterministic licensed corpus verification and explicit acquisition.

Only `acquire` accesses the network. Generation writes candidates, never approves
new goldens. This test/developer decoder is deliberately not a runtime API.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import urllib.request

from corpus_catalog import ANNOTATION, DATASET_URL, RIGHTS, SOURCES, SUBSETS, VERSION, recipes

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Corpus"
MAX_BYTES = 64 * 1024 * 1024
MAX_SAMPLES = 44100 * 60
RATE = 44100


class CorpusError(ValueError):
    pass


class InputFailure(CorpusError):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


def require(condition, message):
    if not condition:
        raise CorpusError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    def pairs(items):
        result = dict(items)
        require(len(result) == len(items), "Duplicate JSON key")
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(CorpusError("Nonfinite JSON")))


def safe_path(root, relative):
    require(isinstance(relative, str) and relative, "Missing relative path")
    path = PurePosixPath(relative)
    require(not path.is_absolute() and ".." not in path.parts and str(path) == relative,
            "Unsafe relative path")
    result = root
    for part in path.parts:
        result = result / part
        require(not result.is_symlink(), "Symbolic link in corpus path")
    require(result.resolve().is_relative_to(root.resolve()), "Path leaves corpus")
    return result


def read_bytes(path):
    require(path.is_file() and path.stat().st_size <= MAX_BYTES, "Missing or oversized corpus artifact")
    data = path.read_bytes()
    require(len(data) <= MAX_BYTES, "Oversized corpus artifact")
    return data


def wav(payload, rate=RATE, channels=1, encoding=1, bits=16):
    align = channels * bits // 8
    fmt = struct.pack("<HHIIHH", encoding, channels, rate, rate * align, align, bits)
    content = b"WAVEfmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(payload)) + payload
    if len(payload) % 2:
        content += b"\0"
    return b"RIFF" + struct.pack("<I", len(content)) + content


def decode(data):
    """Bounded RIFF PCM16/Float32 mono; explicit file-input applicability reasons."""
    if len(data) > MAX_BYTES:
        raise InputFailure("unsupportedRange")
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise InputFailure("invalidInput")
    if struct.unpack_from("<I", data, 4)[0] + 8 != len(data):
        raise InputFailure("invalidInput")
    chunks = {}
    position = 12
    while position < len(data):
        if position + 8 > len(data):
            raise InputFailure("invalidInput")
        tag, count = struct.unpack_from("<4sI", data, position)
        position += 8
        end = position + count
        if tag in chunks or end + count % 2 > len(data):
            raise InputFailure("invalidInput")
        chunks[tag] = data[position:end]
        position = end + count % 2
    if b"fmt " not in chunks or b"data" not in chunks or len(chunks[b"fmt "]) != 16:
        raise InputFailure("invalidInput")
    encoding, channels, rate, byte_rate, align, bits = struct.unpack("<HHIIHH", chunks[b"fmt "])
    if channels != 1 or (encoding, bits) not in {(1, 16), (3, 32)} or not 4000 <= rate <= 192000:
        raise InputFailure("unsupportedRange")
    if align != bits // 8 or byte_rate != rate * align or len(chunks[b"data"]) % align:
        raise InputFailure("invalidInput")
    count = len(chunks[b"data"]) // align
    if count == 0:
        raise InputFailure("insufficientData")
    if count > MAX_SAMPLES:
        raise InputFailure("unsupportedRange")
    code = "h" if encoding == 1 else "f"
    raw = [item[0] for item in struct.iter_unpack("<" + code, chunks[b"data"])]
    samples = [value / 32768 for value in raw] if encoding == 1 else raw
    if any(not math.isfinite(value) or abs(value) > 1 for value in samples):
        raise InputFailure("invalidInput")
    return samples, {
        "sampleRate": rate, "sampleCount": count, "channelCount": channels,
        "encoding": "signedInt16" if encoding == 1 else "float32",
        "durationSeconds": count / rate,
        "normalizedFloat64LESHA256": sha(struct.pack(f"<{count}d", *samples)),
    }


def pcm16(data):
    _, info = decode(data)
    require(info["sampleRate"] == RATE and info["encoding"] == "signedInt16",
            "Transform requires source PCM16 at 44100 Hz")
    # All committed originals have exactly these two chunks and a 44-byte header.
    require(data[:44] == wav(data[44:])[:44], "Transform requires canonical source header")
    return [item[0] for item in struct.iter_unpack("<h", data[44:])]


def outcome(data):
    try:
        samples, info = decode(data)
    except InputFailure as error:
        return {"status": "unavailable", "reason": error.reason}, None
    info["peak"] = max(map(abs, samples))
    info["meanSquare"] = math.fsum(value * value for value in samples) / len(samples)
    info["zeroSampleCount"] = sum(value == 0 for value in samples)
    info["railSampleCount"] = sum(value <= -1 or value >= 32767 / 32768 for value in samples)
    return {"status": "available", "reason": None}, info


def integer(value, minimum, maximum, label):
    require(type(value) is int and minimum <= value <= maximum, "Invalid " + label)
    return value


def apply_step(data, step):
    kind = step["kind"]
    samples = pcm16(data)
    extra = {}
    if kind == "excerpt":
        require(set(step) == {"kind", "startSample", "sampleCount"}, "Invalid excerpt fields")
        start = integer(step["startSample"], 0, len(samples), "excerpt start")
        count = integer(step["sampleCount"], 1, len(samples), "excerpt count")
        require(start + count <= len(samples), "Excerpt outside source bounds")
        samples = samples[start:start + count]
    elif kind == "integer-gain":
        require(set(step) == {"kind", "numerator", "denominator"}, "Invalid gain fields")
        numerator = integer(step["numerator"], 1, 256, "gain numerator")
        denominator = integer(step["denominator"], 1, 256, "gain denominator")
        # Division rounds toward zero, then saturates to the signed PCM16 rails.
        samples = [max(-32768, min(32767, (1 if x >= 0 else -1) * (abs(x) * numerator // denominator))) for x in samples]
    elif kind == "integer-noise":
        require(set(step) == {"kind", "seed", "amplitudeLSB"}, "Invalid noise fields")
        state = integer(step["seed"], 1, 0xFFFFFFFF, "noise seed")
        amplitude = integer(step["amplitudeLSB"], 1, 32767, "noise amplitude")
        result = []
        for value in samples:
            state ^= (state << 13) & 0xFFFFFFFF
            state ^= state >> 17
            state ^= (state << 5) & 0xFFFFFFFF
            noise = state % (2 * amplitude + 1) - amplitude
            result.append(max(-32768, min(32767, value + noise)))
        signal_energy = sum(x * x for x in samples)
        error_energy = sum((x - y) ** 2 for x, y in zip(samples, result))
        extra = {"generator": "xorshift32-13-17-5-modulo-inclusive/v1", "finalState": state,
                 "inputSumSquaresLSB": signal_energy, "addedErrorSumSquaresLSB": error_energy,
                 "measuredSNRDB": round(10 * math.log10(signal_energy / error_energy), 12)}
        samples = result
    elif kind == "replace-with-zero":
        require(set(step) == {"kind", "startSample", "sampleCount"}, "Invalid replacement fields")
        start = integer(step["startSample"], 0, len(samples), "replacement start")
        count = integer(step["sampleCount"], 1, len(samples), "replacement count")
        require(start + count <= len(samples), "Replacement outside source bounds")
        samples[start:start + count] = [0] * count
        extra["observedSilence"] = False
    elif kind == "duplicate-channel":
        require(set(step) == {"kind"}, "Invalid channel fields")
        return wav(struct.pack(f"<{2 * len(samples)}h", *(v for x in samples for v in (x, x))), channels=2), extra
    elif kind == "empty-payload":
        require(set(step) == {"kind"}, "Invalid empty fields")
        return wav(b""), extra
    elif kind == "truncate-file":
        require(set(step) == {"kind", "removeBytes"}, "Invalid truncation fields")
        count = integer(step["removeBytes"], 1, len(data) - 1, "truncation")
        return data[:-count], extra
    elif kind == "float32-nan":
        require(set(step) == {"kind", "sampleIndex"}, "Invalid nonfinite fields")
        index = integer(step["sampleIndex"], 0, len(samples) - 1, "nonfinite index")
        payload = bytearray(struct.pack(f"<{len(samples)}f", *(x / 32768 for x in samples)))
        struct.pack_into("<I", payload, index * 4, 0x7FC00000)
        return wav(payload, encoding=3, bits=32), extra
    else:
        raise CorpusError("Unsupported transformation")
    return wav(struct.pack(f"<{len(samples)}h", *samples)), extra


def generator_identity():
    files = [{"path": "Tools/Corpus/" + name, "sha256": sha((ROOT / "Tools/Corpus" / name).read_bytes())}
             for name in ("corpus_catalog.py", "corpus.py")]
    return {"version": VERSION, "files": files, "sha256": sha(canonical(files))}


def source_record(source, data):
    require(len(data) == source["byteCount"] and sha(data) == source["sha256"], "Pinned original hash/size mismatch")
    samples, info = decode(data)
    require(info["sampleRate"] == RATE and info["sampleCount"] == source["sampleCount"]
            and info["encoding"] == "signedInt16", "Pinned source format mismatch")
    pcm16(data)
    return {**source, **info, "path": "originals/" + source["id"] + ".wav",
            "datasetURL": DATASET_URL, "datasetVersion": 3, "doi": "10.17632/9dz247gnyb.3",
            "downloadURL": "https://data.mendeley.com/public-files/datasets/9dz247gnyb/files/" + source["fileID"] + "/file_downloaded"}


def build(originals):
    """Build candidate bytes in memory from exact pinned originals, without I/O."""
    sources = [source_record(source, originals[source["id"]]) for source in SOURCES]
    records, artifacts = [], {}
    for recipe in recipes():
        data = originals[recipe["sourceID"]]
        chain = []
        for step in recipe["steps"]:
            before = sha(data)
            data, detail = apply_step(data, step)
            chain.append({"parameters": step, "inputSHA256": before, "outputSHA256": sha(data), "details": detail})
        expected, info = outcome(data)
        start, count = (recipe["steps"][0][key] for key in ("startSample", "sampleCount"))
        record = {key: recipe[key] for key in ("id", "sourceID", "task", "condition")}
        record.update(path="samples/" + recipe["id"] + ".wav", sha256=sha(data), byteCount=len(data),
                      sourceSupport={"startSample": start, "sampleCount": count, "sampleRate": RATE},
                      transformations=chain, expectedInput=expected, decoded=info)
        records.append(record)
        artifacts[record["path"]] = data
    manifest = {
        "schemaVersion": 1, "corpusVersion": VERSION, "generator": generator_identity(),
        "rights": RIGHTS, "annotations": ANNOTATION, "sources": sources, "fixtures": records,
        "normalization": "signed PCM16 / 32768; no peak normalization, filtering or resampling",
        "selection": "First three lexically ordered BL records in PVQD v3; engineering regression material, not a representative cohort",
        "subsets": SUBSETS,
        "longStream": {"id": "corpus-long-stream/v1", "fixtureID": SUBSETS["corpus-long-stream/v1"][0],
                       "sampleCount": MAX_SAMPLES, "sampleRate": RATE,
                       "method": "Repeat the complete excerpt without crossfade, truncate at 60 seconds; every join is a new continuity epoch, not continuous natural speech"},
        "coverage": coverage(records),
    }
    return manifest, artifacts


def coverage(records):
    available = [x["id"] for x in records if x["expectedInput"]["status"] == "available"]
    rejected = {reason: [x["id"] for x in records if x["expectedInput"]["reason"] == reason]
                for reason in ("invalidInput", "insufficientData", "unsupportedRange")}
    return {"total": len(records), "available": available, "unavailable": rejected,
            "policy": "All fixtures, including invalid/unsupported cases, remain in denominators; availability is decoder applicability, not a valid acoustic measurement"}


def original_bytes(root):
    return {source["id"]: read_bytes(safe_path(root, "originals/" + source["id"] + ".wav")) for source in SOURCES}


def validate_manifest(manifest, root=FIXTURES):
    require(type(manifest.get("schemaVersion")) is int and manifest["schemaVersion"] == 1, "Unsupported corpus schema")
    require(manifest.get("rights") == RIGHTS, "Missing or changed license/consent/attribution")
    require(manifest.get("annotations") == ANNOTATION, "Unapproved annotation fields or labels")
    sources = manifest["sources"]
    ids = [x["id"] for x in sources]
    require(len(set(ids)) == len(ids), "Duplicate source ID")
    source_by_id = {source["id"]: source for source in sources}
    ids = [x["id"] for x in manifest["fixtures"]]
    require(len(set(ids)) == len(ids), "Duplicate fixture ID")
    paths = [x["path"] for x in sources + manifest["fixtures"]]
    require(len(set(paths)) == len(paths), "Duplicate artifact path")
    for record in sources + manifest["fixtures"]:
        require(re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is not None, "Invalid artifact SHA256")
        safe_path(root, record["path"])
    for record in manifest["fixtures"]:
        require(record["sourceID"] in source_by_id, "Unknown source ID")
        source = source_by_id[record["sourceID"]]
        support = record["sourceSupport"]
        start = integer(support["startSample"], 0, source["sampleCount"], "source start")
        count = integer(support["sampleCount"], 1, source["sampleCount"], "source count")
        require(start + count <= source["sampleCount"], "Excerpt outside source bounds")
        require(support["sampleRate"] == source["sampleRate"], "Inconsistent source rate")
        previous = source["sha256"]
        for step in record["transformations"]:
            require(step["inputSHA256"] == previous, "Broken transformation chain")
            previous = step["outputSHA256"]
        require(previous == record["sha256"], "Transformation final hash mismatch")
        decoded = record["decoded"]
        if decoded is not None:
            require(decoded["durationSeconds"] == decoded["sampleCount"] / decoded["sampleRate"], "Inconsistent duration")
    require(manifest["coverage"] == coverage(manifest["fixtures"]), "Coverage omits or changes fixture outcomes")
    require(manifest["subsets"] == SUBSETS, "Changed or incomplete stable subsets")
    require(all(item in ids for items in manifest["subsets"].values() for item in items), "Unknown subset fixture")


def verify(root=FIXTURES):
    root = Path(root)
    manifest = read_json(safe_path(root, "manifest.json"))
    validate_manifest(manifest, root)
    expected, artifacts = build(original_bytes(root))
    require(canonical(manifest) == canonical(expected), "Manifest differs from pinned source/recipe metadata; regenerate candidates and review")
    for record in manifest["sources"] + manifest["fixtures"]:
        data = read_bytes(safe_path(root, record["path"]))
        require(sha(data) == record["sha256"] and len(data) == record["byteCount"], "Artifact hash/size mismatch: " + record["id"])
    for path, data in artifacts.items():
        require(read_bytes(safe_path(root, path)) == data, "Transformation reproduction mismatch: " + path)
    actual = set()
    for path in root.rglob("*"):
        require(not path.is_symlink(), "Symbolic link in corpus directory")
        if path.is_file() and path.suffix != ".md":
            actual.add(path.relative_to(root).as_posix())
    require(actual == {"manifest.json"} | {x["path"] for x in manifest["sources"] + manifest["fixtures"]}, "Unlisted or missing corpus artifact")
    return manifest


def new_output(path):
    path = path.resolve()
    require(not path.is_relative_to(FIXTURES.resolve()), "Candidate output cannot overwrite committed corpus")
    require(not path.exists() or not any(path.iterdir()), "Output must be new or empty")
    path.mkdir(parents=True, exist_ok=True)
    return path


def generate(source_root, output):
    originals = original_bytes(Path(source_root))
    manifest, artifacts = build(originals)
    output = new_output(output)
    for source in SOURCES:
        artifacts["originals/" + source["id"] + ".wav"] = originals[source["id"]]
    artifacts["manifest.json"] = canonical(manifest) + b"\n"
    for relative, data in artifacts.items():
        path = safe_path(output, relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return manifest


def acquire(output):
    output = new_output(output)
    (output / "originals").mkdir()
    for source in SOURCES:
        url = "https://data.mendeley.com/public-files/datasets/9dz247gnyb/files/" + source["fileID"] + "/file_downloaded"
        # The public host rejects Python's generic default UA; identify this
        # project client explicitly. No cookies, token, or private access is used.
        request = urllib.request.Request(url, headers={
            "User-Agent": "HDXLVoiceProcessing-Corpus/1.0 (https://github.com/plx/hdxl-voice-processing)"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(source["byteCount"] + 1)
        source_record(source, data)
        (output / "originals" / (source["id"] + ".wav")).write_bytes(data)
    return {"sourceIDs": [x["id"] for x in SOURCES], "datasetURL": DATASET_URL}


def prepare_long_stream(root, output):
    manifest = verify(root)
    record = next(x for x in manifest["fixtures"] if x["id"] == manifest["longStream"]["fixtureID"])
    data = read_bytes(safe_path(Path(root), record["path"]))
    payload = data[44:]
    count = manifest["longStream"]["sampleCount"]
    source_count = record["decoded"]["sampleCount"]
    repeated = (payload * ((count + source_count - 1) // source_count))[:count * 2]
    result = wav(repeated)
    output = new_output(output)
    (output / "long-stream.wav").write_bytes(result)
    report = {**manifest["longStream"], "inputSHA256": sha(data), "outputSHA256": sha(result),
              "byteCount": len(result), "continuityBoundarySamples": list(range(source_count, count, source_count)),
              "decoded": outcome(result)[1], "corpusManifestSHA256": sha(canonical(manifest) + b"\n")}
    (output / "long-stream.json").write_bytes(canonical(report) + b"\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("verify", "generate", "acquire", "prepare-long-stream"))
    parser.add_argument("--root", type=Path, default=FIXTURES)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.command != "verify":
            require(args.output is not None, "An explicit new output directory is required")
        if args.command == "verify":
            manifest = verify(args.root)
            result = {"corpusVersion": VERSION, "sourceCount": len(manifest["sources"]), "coverage": manifest["coverage"]}
        elif args.command == "generate":
            manifest = generate(args.root, args.output)
            result = {"corpusVersion": VERSION, "manifestSHA256": sha(canonical(manifest) + b"\n")}
        elif args.command == "acquire":
            result = acquire(args.output)
        else:
            result = prepare_long_stream(args.root, args.output)
        print(json.dumps(result, sort_keys=True))
    except (CorpusError, OSError, KeyError, TypeError, ZeroDivisionError, json.JSONDecodeError) as error:
        print("Corpus check failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
