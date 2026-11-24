#!/usr/bin/env python3
"""Index exactly the case/operation combinations that passed in both benchmark modes."""

from collections import defaultdict
from hashlib import sha256
import json
from pathlib import Path
from zipfile import ZipFile


def catalog_family(archives):
    cases = {"timing": {}, "allocation": {}}
    evidence = []
    for archive, expected_sha in archives:
        if sha256(archive.read_bytes()).hexdigest() != expected_sha:
            raise ValueError(f"Archive content differs: {archive.name}")
        with ZipFile(archive) as z:
            for key in sorted(z.namelist()):
                if not key.endswith("/workload-manifest.json"):
                    continue
                root = key.removesuffix("workload-manifest.json")
                read = lambda name: json.loads(z.read(root + name))
                receipt, manifest = read("result.json"), read("workload-manifest.json")
                mode = manifest["mode"]
                if receipt["status"] != "passed" or receipt["mode"] != mode:
                    raise ValueError(f"Incomplete mode: {key}")
                for field in ("caseFile", "distributionFile", "environmentFile", "exportFile"):
                    if sha256(z.read(root + manifest[field])).hexdigest() != manifest[field + "SHA256"]:
                        raise ValueError(f"Unbound {field}: {key}")
                rows, measurements = read(manifest["caseFile"]), read(manifest["distributionFile"])
                ops = manifest["operations"]
                if len(ops) != len(measurements) or {o["id"] for o in ops} != measurements.keys():
                    raise ValueError(f"Operation coverage differs: {key}")
                for op in ops:
                    name = op["id"]
                    row = measurements[name]
                    if op["role"] == "instrumentationControl":
                        if mode != "allocation" or any(v["maximum"] <= 0 for v in row.values()):
                            raise ValueError(f"Missing instrumentation control: {key}")
                        continue
                    work = rows[op["caseIndex"]]
                    case = work.get("name") or work["workload"]["name"]
                    if not name.endswith("." + case) or name in cases[mode]:
                        raise ValueError(f"Duplicate or unrelated measured operation: {name}")
                    cases[mode][name] = case
                evidence.append(dict(archiveSHA256=expected_sha, mode=mode,
                                     workloadManifestSHA256=sha256(z.read(key)).hexdigest()))
    if not cases["timing"] or cases["timing"] != cases["allocation"]:
        raise ValueError("Clean timing and instrumented operation catalogs differ")
    by_case = defaultdict(list)
    for name, case in cases["timing"].items():
        by_case[case].append(name.removesuffix("." + case))
    groups = defaultdict(list)
    for case, operations in by_case.items():
        groups[tuple(sorted(operations))].append(case)
    return dict(caseCount=len(by_case), operationCount=len(cases["timing"]),
                operationGroups=[dict(operations=list(k), cases=sorted(v)) for k, v in sorted(groups.items())],
                modeReceipts=sorted(evidence, key=lambda e: (e["archiveSHA256"], e["mode"])))


def rebuild(catalog, cache):
    for family in catalog["families"]:
        archives = [(cache / (str(a["id"]) + ".zip"), a["sha256"]) for a in family["artifacts"]]
        family.update(catalog_family(archives))
    return catalog


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path, help="GitHub artifact ZIPs named by numeric artifact ID")
    parser.add_argument("--catalog", type=Path, default=Path(__file__).resolve().parents[2]
                        / "Documentation/Evidence/voice-algorithm-catalog.json")
    args = parser.parse_args()
    original = args.catalog.read_bytes()
    observed = rebuild(json.loads(original), args.cache)
    if observed != json.loads(original):
        raise ValueError("Versioned catalog differs from verified archives")
    print(f"Verified {len(observed['families'])} benchmark families")
