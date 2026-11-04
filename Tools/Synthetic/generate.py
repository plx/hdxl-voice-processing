#!/usr/bin/env python3
"""Generate fresh, reviewable synthetic candidates; never update committed goldens."""
import argparse
from pathlib import Path
import tempfile
import uuid

from catalog import recipes, expectations, sequence_cases, algebra_cases, COVERAGE
from sequences import statistics
from synthetic import (ROOT, canonical, sha256, write_json, require, render, wave, pcm_bytes,
                       selection, mix_noise, transfer, validate_recipe, integer)

SOURCES = ("synthetic.py", "sequences.py", "catalog.py", "generate.py")
FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Synthetic"


def implementation():
    sources = {"Tools/Synthetic/" + name: sha256((Path(__file__).parent / name).read_bytes()) for name in SOURCES}
    return {"identifier": {"name": "independent-synthetic-sources", "version": 1},
            "sources": sources, "sha256": sha256(canonical(sources)),
            "precision": "binary64; separately rounded arithmetic; no FMA",
            "oscillator": "rational turns; symmetry-reduced sine Taylor through x^25; exact cardinal points",
            "noise": "SplitMix64; top 53 bits * 2^-52 - 1; uniform [-1,1)",
            "filter": "cascade y[n]=g*x[n]-a1*y[n-1]-a2*y[n-2]; r=exp(-pi*B/fs); a1=-2*r*cos(2*pi*F/fs); a2=r*r; g=1+a1+a2",
            "polePrecision": "Decimal 80-digit exp and fixed 70-digit pi, rounded to binary64",
            "clipping": "no hidden scaling; reject overrange unless explicit hard clipping [-1,1]"}


def materialize(recipe):
    if "mixture" not in recipe:
        samples, renderer = render(recipe)
        return samples, recipe, {"finalState": renderer.snapshot(), "sections": renderer.sections,
                                "pulses": renderer.pulse_metadata, "mixture": None}
    require(set(recipe) == {"schemaVersion", "identifier", "mixture"}, "Unknown mixture recipe fields")
    integer(recipe["schemaVersion"], 1, 1, "mixture schema")
    mixture = recipe["mixture"]
    require(type(mixture) is dict and set(mixture) == {"source", "noise", "snrDB"}, "Invalid mixture")
    source, noise = mixture["source"], mixture["noise"]
    validate_recipe(source)
    validate_recipe(noise)
    # Reuse strict identifier validation and prohibit masked/filtered noise ambiguity.
    validate_recipe({**source, "identifier": recipe["identifier"]})
    require(source["sampleRate"] == noise["sampleRate"] and source["sampleCount"] == noise["sampleCount"], "Mixture support mismatch")
    require(not source["missingIntervals"] and not noise["missingIntervals"], "Mixture requires complete support")
    require(noise["source"]["kind"] == "noise", "Mixture requires declared noise source")
    x, xr = render(source)
    n, nr = render(noise)
    samples, details = mix_noise(x, n, mixture["snrDB"])
    details.update({"sourcePCM_SHA256": sha256(pcm_bytes(x)), "noisePCM_SHA256": sha256(pcm_bytes(n)),
                    "sourceFinalState": xr.snapshot(), "noiseFinalState": nr.snapshot()})
    return samples, source, {"finalState": None, "sections": [], "pulses": None, "mixture": details}


def fixture(recipe, engine):
    samples, base, diagnostics = materialize(recipe)
    name = recipe["identifier"]["name"]
    pcm = pcm_bytes(samples)
    wav = wave(samples, base["sampleRate"])
    segments = selection(len(samples), base["missingIntervals"])
    settings_hash = sha256(canonical(recipe))
    source = {"epoch": {"streamID": str(uuid.UUID(settings_hash[:32])).upper(), "sequence": 0},
              "startSample": 0, "sampleCount": len(samples), "sampleRate": base["sampleRate"]}
    pulse_stats = None
    if base["source"]["kind"] == "pulses":
        pulse_stats = {"periods": statistics(base["source"]["periodsSeconds"], "period"),
                       "amplitudes": statistics(base["source"]["amplitudes"], "amplitude")}
    response = []
    if diagnostics["sections"] and base["source"]["kind"] == "harmonics":
        for component in base["source"]["components"]:
            h = transfer(diagnostics["sections"], component["frequencyHz"], base["sampleRate"]) * base["gain"]
            response.append({"frequencyHz": component["frequencyHz"], "real": h.real, "imaginary": h.imag,
                             "steadyStateAmplitude": abs(h) * component["amplitude"]})
    definition = {"schemaVersion": 1, "identifier": recipe["identifier"], "generatorSHA256": engine["sha256"],
        "recipe": recipe, "recipeIdentity": {"identifier": recipe["identifier"], "sha256": settings_hash},
        "format": {"sampleRate": base["sampleRate"], "channelCount": 1, "encoding": "float64", "layout": "interleaved"},
        "timing": {"source": source, "includedSampleCount": sum(s["sampleCount"] for s in segments if s["included"]),
                   "sourceStartSeconds": 0, "hostStartNanoseconds": None, "completedHostNanoseconds": None,
                   "effectiveDelaySeconds": 0},
        "timingScope": "source generation support; no analysis result/delay implied; causal filter phase is frequency dependent",
        "durationSeconds": len(samples) / base["sampleRate"], "selection": segments,
        "artifact": {"file": name + ".wav", "sha256": sha256(wav), "byteCount": len(wav),
                     "normalizedFloat64LESHA256": sha256(pcm)},
        "renderDiagnostics": diagnostics, "directPulseStatistics": pulse_stats,
        "steadyStateTransfer": response,
        "transferScope": "algebraic discrete all-pole model; zero-state transients remain in PCM; filtered-harmonics projection discards first 4000 samples",
        "expectations": expectations().get(name, [])}
    definition["fixtureIdentity"] = sha256(b"hdxl-synthetic-v1\n" + canonical(definition))
    return wav, definition


def artifacts():
    engine = implementation()
    result, entries = {}, []
    for recipe in recipes():
        wav, manifest = fixture(recipe, engine)
        name = manifest["identifier"]["name"]
        require(name + ".wav" not in result, "Duplicate fixture name")
        result[name + ".wav"] = wav
        result[name + ".json"] = canonical(manifest) + b"\n"
        entries.append({"id": name, "manifest": name + ".json", "fixtureIdentity": manifest["fixtureIdentity"]})
    for name, value in (("sequences", sequence_cases()), ("algebra", algebra_cases())):
        result[name + ".json"] = canonical(value) + b"\n"
    known = {e["id"] for e in entries} | set(sequence_cases()["cases"]) | set(algebra_cases()["cases"])
    coverage = [{"planningID": plan, "issue": issue, "analyticOrInvariant": valid, "difficultOrUndefined": hard,
                 "scope": scope} for plan, issue, valid, hard, scope in COVERAGE]
    require(len(coverage) == 18 and all(c["analyticOrInvariant"] and c["difficultOrUndefined"]
            and set(c["analyticOrInvariant"] + c["difficultOrUndefined"]) <= known for c in coverage), "Incomplete coverage")
    catalog = {"schemaVersion": 1, "generator": engine, "cases": entries, "coverage": coverage,
               "artifacts": {name: sha256(data) for name, data in sorted(result.items())},
               "consumerContract": "developer/test data only; production comparisons belong to each algorithm leaf"}
    catalog["catalogIdentity"] = sha256(b"hdxl-synthetic-catalog-v1\n" + canonical(catalog))
    result["catalog.json"] = canonical(catalog) + b"\n"
    return result


def fresh_output(path):
    path = Path(path).resolve()
    require(path.is_relative_to((ROOT / ".build").resolve()) and not path.exists(), "Use a fresh candidate directory under repository .build")
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def generate(output):
    output = fresh_output(output)
    contents = artifacts()
    with tempfile.TemporaryDirectory(prefix="synthetic-", dir=output.parent) as temporary:
        staging = Path(temporary) / "candidate"
        staging.mkdir()
        for name, data in contents.items():
            (staging / name).write_bytes(data)
        staging.rename(output)
    print(f"Generated {len(contents)} artifacts ({sum(map(len, contents.values()))} bytes) in {output.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    generate(parser.parse_args().output)
