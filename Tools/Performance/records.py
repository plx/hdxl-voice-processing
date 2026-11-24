"""Join native case receipts to measured operations without losing their denominators."""
import hashlib
import json
import re
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def system_state():
    """Sample before building/measuring. Store only enumerated power/thermal observations."""
    source = "unavailable"
    try:
        description = subprocess.check_output(["pmset", "-g", "batt"], text=True,
                                              stderr=subprocess.DEVNULL, timeout=5)
        match = re.search(r"^Now drawing from '(AC Power|Battery Power|UPS Power)'", description, re.M)
        if match:
            source = match[1]
    except (OSError, subprocess.SubprocessError):
        pass
    state, low_power = "unavailable", None
    try:
        report = subprocess.check_output([
            "xcrun", "swift", "-e", "import Foundation; let p = ProcessInfo.processInfo; "
            "print(p.thermalState.rawValue, p.isLowPowerModeEnabled)"],
            text=True, stderr=subprocess.DEVNULL, timeout=30)
        thermal, low = report.strip().split()
        state = {"0": "nominal", "1": "fair", "2": "serious", "3": "critical"}.get(thermal, "unavailable")
        low_power = {"true": True, "false": False}[low]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        pass
    return dict(powerSource=source, thermalState=state, lowPowerMode=low_power,
                observation="single preflight sample", sustainedThermalState="unmeasured")


def compilation_settings(pif_path, target):
    """Read SwiftPM's selected Release build settings for the library and its consumer."""
    if pif_path is None or not pif_path.is_file():
        return {"status": "unavailable", "reason": "SwiftPM did not emit manifest.pif"}
    graph = json.loads(pif_path.read_bytes())
    targets = {x["signature"]: x["contents"] for x in graph if x["type"] == "target"}
    relevant = ("SWIFT_OPTIMIZATION_LEVEL", "SWIFT_COMPILATION_MODE", "BUILD_LIBRARY_FOR_DISTRIBUTION",
                "OTHER_SWIFT_FLAGS", "SWIFT_VERSION")
    records = []
    for node in graph:
        if node["type"] != "project":
            continue
        project = node["contents"]
        for signature in project["targets"]:
            module = targets[signature]
            if module.get("name") not in ("HDXLVoiceProcessing", target):
                continue
            def settings(item):
                release = next(c["buildSettings"] for c in item["buildConfigurations"] if c["name"] == "Release")
                return {key: release[key] for key in relevant if key in release}
            records.append(dict(module=module["name"], targetGUID=module["guid"],
                                project=project["projectName"], projectSettings=settings(project),
                                targetSettings=settings(module)))
    return dict(status="recorded" if records else "unavailable", source="SwiftPM Release PIF settings",
                consumerBoundary="separate SwiftPM modules using the public library product",
                modules=records)


def index_operations(directory, mode):
    cases_file = directory / "workloads.json"
    distribution_file = directory / "distributions.json"
    rows = json.loads(cases_file.read_bytes())
    distributions = json.loads(distribution_file.read_bytes())
    env = json.loads((directory / "environment.json").read_bytes())
    # A SWIPE comparison uses one named input with two independent algorithm rows.
    names = {}
    for i, row in enumerate(rows):
        name = row.get("name") or row["workload"]["name"]
        identity = (name, row.get("algorithm"))
        if identity in names:
            raise ValueError(f"Duplicate workload identity: {identity}")
        names[identity] = i
    entries, used = [], set()
    for op in sorted(distributions):
        if op.startswith("Capability."):
            if mode != "allocation":
                raise ValueError(f"Allocation control in {mode}: {op}")
            entries.append(dict(id=op, role="instrumentationControl", caseIndex=None))
            continue
        matches = [i for (name, algorithm), i in names.items()
                   if (op == name or op.endswith("." + name)) and (not algorithm or algorithm in op.split("."))]
        if len(matches) != 1:
            raise ValueError(f"Operation must identify exactly one workload: {op}")
        index = matches[0]
        used.add(index)
        fields = op.split(".")
        role = fields[2] if fields[0] == "SWIPEComparison" else fields[1]
        boundary_key = ("Sequential4/Concurrent4" if fields[0] == "Fourier"
                        and role.startswith(("Sequential4", "Concurrent4")) else role)
        boundary = (rows[index].get("measurementBoundary") or env.get("operations", {}).get(boundary_key)
                    or env.get("measurement"))
        if not boundary:
            raise ValueError(f"Missing timing boundary for {op}")
        entries.append(dict(id=op, role=role, caseIndex=index, boundary=boundary))
    if used != set(range(len(rows))):
        raise ValueError("Missing measurements for declared workloads")
    return dict(schemaVersion=1, mode=mode, denominator="one recorded outer iteration",
                caseFile="workloads.json", caseFileSHA256=sha(cases_file),
                environmentFile="environment.json", environmentFileSHA256=sha(directory / "environment.json"),
                distributionFile="distributions.json", distributionFileSHA256=sha(distribution_file),
                exportFile="p99.json", exportFileSHA256=sha(directory / "p99.json"),
                operations=entries)


def write_index(directory, mode):
    record = index_operations(directory, mode)
    path = directory / "workload-manifest.json"
    path.write_text(json.dumps(record, indent=2, allow_nan=False) + "\n")
    return sha(path)
