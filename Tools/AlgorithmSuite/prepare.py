"""Prepare governed voice-suite inputs. File decoding and hashing precede measurement."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
from Reference.common import read_pcm

FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures"


def load(path):
    return json.loads(path.read_bytes())


def prepare(destination):
    corpus = load(FIXTURES / "Corpus/manifest.json")
    records = {record["id"]: record for record in corpus["fixtures"]}
    cases = []
    payloads = {}

    def include(name, condition, path, expected_hash, *, precision="float64",
                regions=None, repeats=1, normalized_hash=None, expected_rate=None, expected_count=None, periodic_seconds=None):
        samples, info = read_pcm(path)
        if (info["artifactSHA256"] != expected_hash
                or normalized_hash and info["normalizedFloat64LESHA256"] != normalized_hash
                or expected_rate is not None and info["sampleRate"] != expected_rate
                or expected_count is not None and len(samples) != expected_count):
            raise ValueError(f"Fixture changed: {name}")
        transform = "repeat excerpt with new continuity epoch at each join" if repeats > 1 else "identity"
        if periodic_seconds is not None:
            # The governed low harmonic source has GCD fundamental Fs/256. Check the actual
            # decoded waveform before extending it in one uninterrupted phase-continuous epoch.
            period = samples[:256]
            if len(samples) % 256 or samples != period * (len(samples) // 256) or regions is not None:
                raise ValueError("Source is not exactly periodic")
            count = periodic_seconds * info["sampleRate"]
            samples = (period * ((count + 255) // 256))[:count]
            transform = "repeat exact 256-sample source period, truncate at 30 seconds"
        regions = regions if regions is not None else [(0, len(samples))]
        end = 0
        for start, size in regions:
            if start < end or size <= 0 or start + size > len(samples):
                raise ValueError(f"Invalid source region: {name}")
            end = start + size
        code = {"float64": "d", "float32": "f"}[precision]
        payload = struct.pack(f"<{len(samples)}{code}", *samples)
        digest = hashlib.sha256(payload).hexdigest()
        payloads[digest] = payload
        cases.append(dict(name=name, condition=condition, source=path.relative_to(ROOT).as_posix(),
                          sourceSHA256=expected_hash, transform=transform, pcmSHA256=digest, precision=precision,
                          sampleRate=info["sampleRate"], sampleCount=len(samples), repeats=repeats,
                          regions=[dict(start=start, count=count) for start, count in regions]))

    def speech(name, condition, precision="float64", repeats=1, label=None):
        record = records[name]
        decoded = record["decoded"]
        include(label or name, condition, FIXTURES / "Corpus" / record["path"], record["sha256"],
                precision=precision, repeats=repeats, normalized_hash=decoded["normalizedFloat64LESHA256"],
                expected_count=decoded["sampleCount"], expected_rate=decoded["sampleRate"])

    speech("corpus-bl01-vowel-a", "steady-vowel")
    speech("corpus-bl02-consonant-rich", "connected-speech", "float32")
    speech("corpus-bl03-all-voiced", "connected-speech")
    speech("corpus-bl01-noisy", "noisy-speech")
    speech("corpus-bl01-silence", "silence", "float32")
    long = corpus["longStream"]
    source = records[long["fixtureID"]]["decoded"]
    repeats, tail = divmod(long["sampleCount"], source["sampleCount"])
    if tail or long["sampleRate"] != source["sampleRate"] or repeats < 2:
        raise ValueError("Unexpected long-stream recipe")
    speech(long["fixtureID"], "long-stream", repeats=repeats, label="corpus-long-stream-v1")

    for name, condition in (("harmonic-low", "low-f0"), ("harmonic-high", "high-f0"),
                            ("noise-seed-seven", "aperiodic"), ("missing-intervals", "boundary"),
                            ("filtered-harmonics", "resonant"), ("inharmonic", "inharmonic")):
        directory = FIXTURES / "Synthetic"
        record = load(directory / (name + ".json"))
        artifact = record["artifact"]
        regions = [(r["startSample"], r["sampleCount"]) for r in record["selection"] if r["included"]]
        include(name, condition, directory / artifact["file"], artifact["sha256"],
                normalized_hash=artifact["normalizedFloat64LESHA256"], regions=regions,
                expected_rate=record["format"]["sampleRate"], expected_count=record["recipe"]["sampleCount"])
        if name == "harmonic-low":
            include("harmonic-low-continuous-30s", "long-continuous", directory / artifact["file"], artifact["sha256"],
                    normalized_hash=artifact["normalizedFloat64LESHA256"], periodic_seconds=30,
                    expected_rate=16000, expected_count=4096)
    for hz, precision in ((80, "float64"), (600, "float32")):
        name = f"gaussian-48000-{hz}-{precision}"
        directory = FIXTURES / "Pulses"
        record = load(directory / (name + ".json"))
        include(name, "low-f0" if hz == 80 else "high-f0", directory / (name + ".wav"),
                record["reference"]["inputSHA256"], precision=precision,
                expected_count=record["case"]["sampleCount"], expected_rate=record["case"]["sampleRate"])
    if destination.exists():
        raise FileExistsError(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        bundle = Path(temp) / "bundle"
        bundle.mkdir()
        for digest, payload in payloads.items():
            (bundle / (digest + ".pcm")).write_bytes(payload)
        (bundle / "manifest.json").write_text(json.dumps(dict(schemaVersion=1, cases=cases), indent=2) + "\n")
        bundle.rename(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    prepare(parser.parse_args().destination)
