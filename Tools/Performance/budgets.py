"""Validate a proposed target budget or baseline change against its evidence bundle."""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import re

UNITS = {
    "sustainedCPU": "processCPUSecondsPerAudioSecond",
    "throughput": "audioSecondsPerWallSecond",
    "processingP50": "nanosecondsPerUnbatchedOperation",
    "processingP95": "nanosecondsPerUnbatchedOperation",
    "processingP99": "nanosecondsPerUnbatchedOperation",
    "resultAge": "nanosecondsFromAcquisition", "memoryCap": "bytesPeakRSS",
    "backlog": "queuedSampleFrames", "dropouts": "droppedBuffersPerTrial",
}


def validate(record, directory):
    if record.get("schemaVersion") != 1 or record.get("status") not in ("deferred", "approved"):
        raise ValueError("Unknown budget schema or status")
    if record["status"] == "deferred":
        if not record.get("followupIssue") or record.get("limits") is not None:
            raise ValueError("A deferred budget needs an evidence issue and no enforceable limits")
        return
    for key in ("deviceModel", "architecture", "osBuild", "profileID", "workloadID",
                "operation", "schedulingRationale", "dropoutPolicy", "backlogPolicy", "approvedBy", "reviewURL"):
        if not isinstance(record.get(key), str) or not record[key].strip():
            raise ValueError(f"Missing budget scope or approval: {key}")
    if not re.fullmatch(r"[0-9a-f]{40}", record["commit"]):
        raise ValueError("Expected a complete measured revision")
    date = datetime.datetime.fromisoformat(record["approvedAtUTC"])
    if date.utcoffset() != datetime.timedelta(0):
        raise ValueError("Approval timestamp must identify UTC")
    if record["change"] not in ("initial", "replacement"):
        raise ValueError("Unknown baseline change")
    artifacts = record["evidence"]
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("Approval requires measurement evidence")
    for artifact in artifacts:
        path = (directory / artifact["file"]).resolve()
        if (not path.is_relative_to(directory.resolve()) or not path.is_file()
                or hashlib.sha256(path.read_bytes()).hexdigest() != artifact["sha256"]):
            raise ValueError("Budget evidence missing or digest mismatch")
    if record["change"] == "replacement":
        previous = record.get("previousApprovalSHA256")
        if not isinstance(previous, str) or not re.fullmatch("[0-9a-f]{64}", previous) or not record.get("changeReason"):
            raise ValueError("Replacement requires its predecessor and reason")
    if set(record["limits"]) != UNITS.keys():
        raise ValueError("Incomplete budget metrics")
    limits = {}
    for name, unit in UNITS.items():
        limit = record["limits"][name]
        value = limit["value"]
        if (type(value) not in (int, float) or not math.isfinite(value) or value < 0
                or limit["unit"] != unit or limit["bound"] != ("minimum" if name == "throughput" else "maximum")):
            raise ValueError(f"Invalid limit: {name}")
        limits[name] = value
    if not limits["processingP50"] <= limits["processingP95"] <= limits["processingP99"]:
        raise ValueError("Inconsistent percentile limits")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    args = parser.parse_args()
    validate(json.loads(args.record.read_bytes()), args.record.parent)
