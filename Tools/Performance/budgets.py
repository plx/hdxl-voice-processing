"""Validate a proposed target budget or baseline change against its evidence bundle."""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import re
from urllib.parse import urlsplit

UNITS = {
    "sustainedCPU": "processCPUSecondsPerAudioSecond",
    "throughput": "audioSecondsPerWallSecond",
    "processingP50": "nanosecondsPerUnbatchedOperation",
    "processingP95": "nanosecondsPerUnbatchedOperation",
    "processingP99": "nanosecondsPerUnbatchedOperation",
    "resultAge": "nanosecondsFromAcquisition", "memoryCap": "bytesPeakRSS",
    "backlog": "queuedSampleFrames", "dropouts": "droppedBuffersPerTrial",
}


SCOPE = ("deviceModel", "architecture", "osBuild", "profileID", "workloadID", "operation")


def evidence_file(directory, name, digest):
    path = (directory / name).resolve()
    if (not path.is_relative_to(directory.resolve()) or not path.is_file()
            or hashlib.sha256(path.read_bytes()).hexdigest() != digest):
        raise ValueError("Budget evidence missing or digest mismatch")
    return path


def validate(record, directory):
    if record.get("schemaVersion") != 1 or record.get("status") not in ("deferred", "approved"):
        raise ValueError("Unknown budget schema or status")
    if record["status"] == "deferred":
        if not record.get("followupIssue") or record.get("limits") is not None:
            raise ValueError("A deferred budget needs an evidence issue and no enforceable limits")
        return
    for key in (*SCOPE, "schedulingRationale", "dropoutPolicy", "backlogPolicy", "approvedBy", "reviewURL"):
        if not isinstance(record.get(key), str) or not record[key].strip():
            raise ValueError(f"Missing budget scope or approval: {key}")
    url = urlsplit(record["reviewURL"])
    if url.scheme not in ("http", "https") or not url.hostname or any(c.isspace() for c in record["reviewURL"]):
        raise ValueError("Expected a review URL with an HTTP(S) scheme and host")
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
        evidence_file(directory, artifact["file"], artifact["sha256"])
    if record["change"] == "replacement":
        if not record.get("previousApprovalFile") or not record.get("changeReason", "").strip():
            raise ValueError("Replacement requires its predecessor and reason")
        path = evidence_file(directory, record["previousApprovalFile"], record.get("previousApprovalSHA256"))
        previous = json.loads(path.read_bytes())
        if previous.get("status") != "approved" or any(previous.get(key) != record[key] for key in SCOPE):
            raise ValueError("Predecessor approval has a different status or scope")
        validate(previous, path.parent)
        if datetime.datetime.fromisoformat(previous["approvedAtUTC"]) > date:
            raise ValueError("Predecessor approval postdates its replacement")
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
