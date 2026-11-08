"""Negative controls for session performance receipts and independent framing."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("session_benchmark", ROOT / "Tools/Sessions/benchmark.py")
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


def population():
    records = []
    for count in BENCH.COUNTS:
        for phase in ("write", "read"):
            for trial in range(BENCH.TRIALS):
                audit = {"bytes": count * 160 + 1000, "maximumRecordPayloadBytes": 600, "sha256": "ab" * 32}
                report = {"schemaVersion": 1, "status": "passed", "syntheticOnly": True,
                    "dspOrCaptureExecuted": False, "phase": phase, "frames": count,
                    "sourceDurationSeconds": count / 100, "seconds": 1.0,
                    "peakResidentBytes": 50 * 1024 * 1024, "archiveBytes": audit["bytes"],
                    "framedRecords": count + 5, "measurementRecords": count,
                    "catalogEntries": 4, "encodedCatalogBytes": 1000,
                    "maximumRecordPayloadBytes": 600, "maximumIOChunkBytes": 600,
                    "embeddedMediaBytes": 0, "available": count - (count + 256) // 257,
                    "unavailable": (count + 256) // 257,
                    "lastTimestamp": BENCH.START + (count - 1) * 160 + 200, "profileSHA256": BENCH.PROFILE_SHA256}
                records.append({"trial": trial, "report": report, "archiveAudit": audit})
    return records


class SessionBenchmarkTests(unittest.TestCase):
    def test_expected_profile_is_bound_to_independent_recipe(self):
        spec = importlib.util.spec_from_file_location("wire_fixture", ROOT / "Tools/Sessions/generate_fixtures.py")
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        self.assertEqual(hashlib.sha256(fixture.canonical(fixture.levels())).hexdigest(), BENCH.PROFILE_SHA256)

    def test_complete_population_and_all_declared_negative_controls(self):
        records = population()
        self.assertEqual(set(BENCH.validate_population(records)), {"write", "read"})
        self.assertEqual(len(BENCH.negative_controls(records)), 10)

    def test_validation_rejects_inconsistent_bytes_booleans_and_profile_hashes(self):
        original = population()[0]
        for field, bad in [("frames", True), ("archiveBytes", 1), ("peakResidentBytes", 0),
                           ("maximumIOChunkBytes", 4097), ("encodedCatalogBytes", 65_537),
                           ("lastTimestamp", float(original["report"]["lastTimestamp"])),
                           ("profileSHA256", "x" * 64), ("sourceDurationSeconds", float("nan"))]:
            record = copy.deepcopy(original)
            record["report"][field] = bad
            with self.subTest(field=field), self.assertRaises(ValueError):
                BENCH.validate_report(record["report"], "write", BENCH.COUNTS[0], record["archiveAudit"])

    def test_streaming_frame_oracle_refuses_hash_order_truncation_and_trailing_bytes(self):
        # This is a framing-only container, not a typed scalar fixture. Typed
        # meaning is independently exercised by the native probe and its goldens.
        data = bytearray.fromhex("4844584c564f49434500010000000000")
        def append(kind, payload, ordinal):
            header = struct.pack("<B3xIQ", kind, len(payload), ordinal)
            data.extend(header + hashlib.sha256(header + payload).digest() + payload)
        for index, kind in enumerate([1, 2, 3, 4, 5, 5]):
            append(kind, b"{}", index)
        footer = {"precedingByteCount": len(data), "precedingRecordCount": 6,
                  "precedingSHA256": {"sha256": hashlib.sha256(data).hexdigest()},
                  "measurementCount": 2, "gapCount": 0, "catalogEntryCount": 4,
                  "mediaReferenceCount": 0, "embeddedMediaBytes": 0, "completion": "completed"}
        append(255, BENCH.canonical(footer), 6)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "framing.hvps"
            path.write_bytes(data)
            audit = BENCH.audit_archive(path, 2)
            self.assertEqual(audit["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(audit["bytes"], len(data))
            mutated = bytearray(data)
            mutated[24] = 1
            for bad in [data[:16], data[:-1], data + b"\0", mutated]:
                path.write_bytes(bad)
                with self.assertRaises(ValueError):
                    BENCH.audit_archive(path, 2)
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                BENCH.audit_archive(path, 3)
