"""Failure injection for corpus timing identity, consumption and coverage gates."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parents[1] / "Corpus"
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("corpus_benchmark", HERE / "benchmark.py")
B = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(B)


class CorpusBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.manifest = B.read_json(B.FIXTURES / "manifest.json")
        manifest_hash = B.sha(B.canonical(self.manifest) + b"\n")
        self.prepared = {"corpusManifestSHA256": manifest_hash, "outputSHA256": "a" * 64,
                         "continuityBoundarySamples": list(range(88200, 2646000, 88200)),
                         "decoded": {"meanSquare": 0.125}}
        by_id = {x["id"]: x for x in self.manifest["fixtures"]}
        self.records = []
        for name, ids in B.SUBSETS.items():
            fixtures = [by_id[key] for key in ids]
            count = sum(x["decoded"]["sampleCount"] for x in fixtures if x["decoded"])
            byte_count = sum(x["byteCount"] for x in fixtures)
            energy = sum(x["decoded"]["meanSquare"] * x["decoded"]["sampleCount"] for x in fixtures if x["decoded"])
            hashes = [x["sha256"] for x in fixtures]
            reasons = [x["expectedInput"]["reason"] for x in fixtures if x["expectedInput"]["reason"]]
            if name == "corpus-long-stream/v1":
                count, byte_count, energy, hashes = 2646000, 5292044, 330750, ["a" * 64]
            self.records.append({
                "schemaVersion": 1, "workload": name, "fixtureIDs": ids, "inputSHA256": hashes,
                "corpusManifestSHA256": manifest_hash, "decodedSampleCount": count,
                "inputByteCount": byte_count, "decodedPCMBytes": count * 8, "sampleRate": 44100,
                "unavailableReasons": reasons, "algorithmPerformance": False,
                "longStreamNaturalContinuity": False, "frameLength": None, "hopLength": None,
                "allocations": "unavailable", "energyChecksums": [energy] * 10,
                "loadTrialsSeconds": [0.001] * 10, "decodeTrialsSeconds": [0.002] * 10,
            })

    def test_complete_reports_are_accepted_and_tails_not_overstated(self):
        self.assertTrue(B.validate(self.records, self.manifest, self.prepared))
        distribution = B.distribution([0.01 * n for n in range(10, 0, -1)])
        self.assertEqual(distribution["median"], 0.05)
        self.assertEqual(distribution["p95"], 0.1)

    def test_missing_duplicate_and_changed_identity_rejected(self):
        for records in (self.records[:-1], self.records + [self.records[0]],
                        [self.records[0]] * 4):
            with self.subTest(count=len(records)), self.assertRaises(ValueError):
                B.validate(records, self.manifest, self.prepared)
        records = copy.deepcopy(self.records)
        records[0]["inputSHA256"][0] = "0" * 64
        with self.assertRaisesRegex(ValueError, "identity"):
            B.validate(records, self.manifest, self.prepared)

    def test_negative_coverage_consumption_counts_and_timings_are_gated(self):
        for field, value in [("unavailableReasons", []), ("decodedPCMBytes", 1),
                             ("energyChecksums", [0] * 10), ("loadTrialsSeconds", [float("nan")] * 10),
                             ("decodeTrialsSeconds", [0.1] * 9), ("algorithmPerformance", True)]:
            records = copy.deepcopy(self.records)
            difficult = next(x for x in records if x["workload"] == "corpus-difficult/v1")
            difficult[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                B.validate(records, self.manifest, self.prepared)
        prepared = copy.deepcopy(self.prepared)
        prepared["continuityBoundarySamples"] = []
        with self.assertRaisesRegex(ValueError, "boundaries"):
            B.validate(self.records, self.manifest, prepared)


if __name__ == "__main__":
    unittest.main()
