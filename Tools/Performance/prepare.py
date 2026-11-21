"""Prepare immutable, portable YIN inputs outside the measured interval."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/YIN"
MANIFEST = ROOT / "Configuration/portable-workloads-v1.json"
sys.path.insert(0, str(ROOT / "Tools"))
from Reference.common import read_pcm
from YIN import oracle as yin

CASES = ("tone-80", "tone-123.45", "tone-650", "float32-tone", "grid-48000-0.01-50",
         "speech-bl01-vowel-a", "speech-bl02-consonant-rich", "silence", "noise", "octave-jump")
STATES = ("voiced", "uncertain", "unvoiced", "unavailable")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, allow_nan=False) + "\n").encode()


def counts(frames):
    statuses = Counter(frame["status"] for frame in frames)
    if statuses.keys() - set(STATES):
        raise ValueError(f"Unexpected reference status {statuses}")
    valid = statuses["voiced"] + statuses["uncertain"]
    return dict(processed=len(frames), available=valid, unavailable=len(frames) - valid,
                byStatus={s: statuses[s] for s in STATES})


def workload(fixture, variant, payloads):
    record = json.loads((FIXTURES / (fixture + ".json")).read_text())
    source, metadata, profile = record["source"], record["input"], record["profile"]
    path = (FIXTURES / metadata["localPath"] if metadata["localPath"] else ROOT / source["path"])
    samples, wav = read_pcm(path)
    start = source.get("startSample", 0)
    samples = samples[start:start + metadata["sampleCount"]]
    if (wav["sampleRate"] != profile["sampleRate"] or
            (metadata["localPath"] and wav["artifactSHA256"] != metadata["encodedInputSHA256"]) or
            sha(struct.pack(f"<{len(samples)}d", *samples)) != metadata["normalizedFloat64LESHA256"]):
        raise ValueError(f"Fixture input changed: {fixture}")

    spans = [(0, len(samples))]
    frames = record["frames"]
    if variant == "clipped":
        samples = [max(-1.0, min(1.0, 8 * x)) for x in samples]
        frames = yin.stream(samples, profile)
    elif variant == "gap":
        # Omit one hop from the middle and finish each observed region independently.
        middle = len(samples) // 2
        spans = [(0, middle), (middle + profile["hopLength"], len(samples))]
        frames = [f | {"startSample": begin + f["startSample"]}
                  for begin, end in spans for f in yin.stream(samples[begin:end], profile)]
    code = {"float32": "f", "float64": "d"}[profile["inputPrecision"]]
    payload = struct.pack(f"<{len(samples)}{code}", *samples)
    digest = sha(payload)
    payloads[digest] = payload
    identifier = fixture if variant is None else f"{fixture}-{variant}"
    sequence = "".join(f"{f['startSample']},{f['observedSampleCount']},{f['status']},"
                       f"{int(f['selectedCandidateIndex'] is not None)}\n" for f in frames)
    return dict(id="yin/" + identifier + "/v1", fixture=fixture, transform=variant or "identity",
                pcmSHA256=digest, sourceWAVSHA256=wav["artifactSHA256"], sourceStartSample=start,
                sampleCount=len(samples), sampleRate=profile["sampleRate"], channelLayout="mono",
                encoding=profile["inputPrecision"] + "LE", utteranceSeconds=len(samples) / profile["sampleRate"],
                segments=[dict(startSample=b, sampleCount=e-b) for b,e in spans],
                profile=profile, profileSHA256=record["profileSHA256"],
                windowSamples=yin.geometry(profile)[-1], fftLength=None,
                availabilityPolicy="voicedOrUncertain", expected=counts(frames),
                expectedFrameSequenceSHA256=sha(sequence.encode("ascii")))


def catalog():
    payloads = {}
    rows = [workload(fixture, None, payloads) for fixture in CASES]
    rows += [workload("tone-123.45", kind, payloads) for kind in ("clipped", "gap")]
    return dict(schemaVersion=1, algorithm="rawYIN", workloads=rows), payloads


def prepare(destination):
    manifest, payloads = catalog()
    content = MANIFEST.read_bytes()
    if manifest != json.loads(content):
        raise ValueError("Generated manifest differs from the versioned workload definition")
    if destination.exists():
        raise FileExistsError(f"Select a new output directory: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        bundle = Path(temp) / "bundle"
        bundle.mkdir()
        for digest, data in payloads.items():
            (bundle / (digest + ".pcm")).write_bytes(data)
        (bundle / "manifest.json").write_bytes(content)
        bundle.rename(destination)
    return sha(content)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    print(prepare(parser.parse_args().destination))
