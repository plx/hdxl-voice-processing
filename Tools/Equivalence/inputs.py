"""Build paired typed PCM from the governed corpus and synthetic catalogs, offline."""
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
sys.path.insert(0, str(ROOT / "Tools/Corpus"))
from Corpus.corpus import outcome as corpus_outcome
from Reference.common import read_pcm, UnsupportedInput

FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures"


def read(path):
    return json.loads(path.read_bytes())


def prepare(destination):
    destination.mkdir(parents=True, exist_ok=False)
    cases, excluded = [], []

    def include(name, group, audio, expected_hash, condition, *, selection=None,
                limit=None, repeats=1, transform="identity", expected_pcm=None):
        if sha256(audio.read_bytes()).hexdigest() != expected_hash:
            raise ValueError(f"Fixture content differs: {name}")
        samples, info = read_pcm(audio)
        if expected_pcm and info["normalizedFloat64LESHA256"] != expected_pcm:
            raise ValueError(f"Decoded PCM differs: {name}")
        if limit is not None:
            if not 0 < limit <= len(samples):
                raise ValueError("Excerpt exceeds source")
            samples = samples[:limit]
        regions = selection if selection is not None else [(0, len(samples))]
        if not regions:
            excluded.append(dict(name=name, group=group, reason="missingAcquisition",
                                 sourceSHA256=expected_hash, sourceSamples=len(samples)))
            return
        narrow = struct.pack(f"<{len(samples)}f", *samples)
        wide = struct.pack(f"<{len(samples)}d", *samples)
        widened = struct.pack(f"<{len(samples)}d", *[s[0] for s in struct.iter_unpack("<f", narrow)])
        encodings = [("float32", "float32", narrow), ("float64", "float64", wide)]
        if widened != wide:
            encodings.append(("widened", "float64", widened))
        for label, precision, payload in encodings:
            digest = sha256(payload).hexdigest()
            path = destination / (digest + ".pcm")
            if not path.exists():
                path.write_bytes(payload)
            cases.append(dict(name=name + "." + label, pair=name, group=group, representation=label,
                              condition=condition, precision=precision, pcmSHA256=digest,
                              source=audio.relative_to(ROOT).as_posix(), sourceSHA256=expected_hash,
                              sampleRate=info["sampleRate"], sampleCount=len(samples), repeats=repeats,
                              transform=transform, regions=[dict(start=s, count=n) for s, n in regions]))

    catalog = read(FIXTURES / "Corpus/manifest.json")
    for row in catalog["fixtures"]:
        name = row["id"]
        audio = FIXTURES / "Corpus" / row["path"]
        data = audio.read_bytes()
        actual, decoded = corpus_outcome(data)
        if sha256(data).hexdigest() != row["sha256"] or (actual, decoded) != (row["expectedInput"], row["decoded"]):
            raise ValueError(f"Corpus outcome differs: {name}")
        if actual["status"] != "available":
            excluded.append(dict(name=name, group="corpus", reason=actual["reason"], sourceSHA256=row["sha256"]))
            continue
        extra = dict(expected_pcm=decoded["normalizedFloat64LESHA256"])
        condition = "connected-speech" if row["task"] in ("all-voiced", "consonant-rich") or "voiced" in name or "consonant" in name else "steady-vowel"
        if name.endswith("noisy"):
            condition = "noisy-speech"
        regions = None
        if name.endswith("dropout"):
            gap = row["transformations"][-1]["parameters"]
            start, count = gap["startSample"], gap["sampleCount"]
            regions = [(0, start), (start + count, decoded["sampleCount"] - start - count)]
        include(name, "corpus", audio, row["sha256"], condition, selection=regions, **extra)
        if name == catalog["longStream"]["fixtureID"]:
            repeats, remainder = divmod(catalog["longStream"]["sampleCount"], decoded["sampleCount"])
            if remainder:
                raise ValueError("Long-stream source requires a partial final epoch")
            include("corpus-long-stream", "duration", audio, row["sha256"], "long-stream",
                    repeats=repeats, transform="repeat complete excerpt in separate epochs", **extra)

    directory = FIXTURES / "Synthetic"
    for row in read(directory / "catalog.json")["cases"]:
        item = read(directory / row["manifest"])
        name = row["id"]
        artifact = item["artifact"]
        audio = directory / artifact["file"]
        if item["fixtureIdentity"] != row["fixtureIdentity"]:
            raise ValueError(f"Synthetic catalog identity differs: {name}")
        if name == "empty":
            try:
                read_pcm(audio)
            except UnsupportedInput as error:
                if str(error) != "insufficientData" or sha256(audio.read_bytes()).hexdigest() != artifact["sha256"]:
                    raise
            else:
                raise ValueError("Empty input unexpectedly accepted")
            excluded.append(dict(name=name, group="synthetic", reason="insufficientData", sourceSHA256=artifact["sha256"]))
            continue
        regions = [(r["startSample"], r["sampleCount"]) for r in item["selection"] if r["included"]]
        extra = dict(expected_pcm=artifact["normalizedFloat64LESHA256"])
        condition = "boundary" if len(regions) != 1 else "synthetic"
        include(name, "synthetic", audio, artifact["sha256"], condition, selection=regions, **extra)
        if name == "harmonic-low":
            # Make a one-sample interruption exactly on the 256-sample pitch period,
            # and a second gap longer than the 50 ms pitch analysis window.
            for label, gap in (("pulse-boundary-gap", 1), ("long-gap", 1024)):
                include(label, "edges", audio, artifact["sha256"], "boundary", **extra,
                        selection=[(0, 1536), (1536 + gap, 4096 - 1536 - gap)],
                        transform=f"omit {gap} acquired samples at offset 1536")
            include("short-120ms", "edges", audio, artifact["sha256"], "short", limit=1920,
                    transform="first 1920 samples at 16 kHz", **extra)

    if len({row["name"] for row in cases}) != len(cases):
        raise ValueError("Duplicate workload name")
    manifest = dict(schemaVersion=1, cases=cases, unavailable=excluded)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    print(len(prepare(parser.parse_args().destination)["cases"]), "typed workloads")
