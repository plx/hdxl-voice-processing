"""Catch denominator substitutions, case ambiguity and unsupported budget promotion."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Performance import budgets, denominators, prepare, records


class PerformanceContractTests(unittest.TestCase):
    def test_paired_input_maps_to_distinct_estimator_rows(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            def save(name, obj):
                (directory / name).write_text(json.dumps(obj))
            rows = [{"workload": {"name": "Tone"}, "algorithm": alg} for alg in ("SWIPEPrime", "YINFFT")]
            operations = {f"SWIPEComparison.{r['algorithm']}.Run.Tone": {} for r in rows}
            save("workloads.json", rows)
            save("environment.json", {"operations": {"Run": "one prepared utterance"}})
            save("distributions.json", operations)
            save("p99.json", {})
            result = records.index_operations(directory, "timing")
            self.assertEqual([r["caseIndex"] for r in result["operations"]], [0, 1])
            save("distributions.json", {next(iter(operations)): {}})
            with self.assertRaisesRegex(ValueError, "Missing measurements"):
                records.index_operations(directory, "timing")

    def test_smoke_percentile_remains_a_batch_measurement(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp)
            for filename, data in {
                "environment.json": {"frameworkScalingFactor": 1, "framesPerSmokeIteration": 1000,
                                     "samplesPerFrame": 1024, "commit": "sample"},
                "result.json": {"status": "passed", "mode": "timing"},
                "workload.json": {"mode": "timing", "framesPerBatch": 1000, "samplesPerFrame": 1024},
                "Current_run.json": [{"name": "Smoke.GainEnergy - Time (wall clock)", "value": 2, "unit": "ms"}],
            }.items():
                (p / filename).write_text(json.dumps(data))
            result = denominators.smoke(p)
            self.assertEqual(result["artifactBinding"], "legacy-unbound")
            self.assertEqual(result["averageNanosecondsPerFrameInP99Batch"], 2000)
            self.assertEqual(result["singleFrameLatencyDistribution"], "unmeasured")

    def test_scheduler_verifies_measurements_and_allows_empty_selection(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            name = "masked"
            op = "Schedule.Run." + name
            files = {
                "environment.json": {"frameworkScalingFactor": 1, "commit": "sample", "measurementMode": "timing",
                                     "operations": {"Run": "one utterance"}},
                "result.json": {"status": "passed", "mode": "timing"},
                "distributions.json": {op: {}},
                "workloads.json": [{"name": name, "inputDurationSeconds": 1, "analyzedDurationSeconds": 0,
                                    "inputSHA256": "sample", "digest": {}, "splitDigest": {}, "directDigest": {}}],
                "p99.json": {op + " - Time (wall clock)": 200, op + " - Time (total CPU)": 0},
            }
            for filename, value in files.items():
                (directory / filename).write_text(json.dumps(value))
            records.write_index(directory, "timing")
            result = denominators.schedule(directory, name)
            self.assertEqual(result["artifactBinding"], "digest-verified")
            self.assertEqual(result["analyzedSecondsPerWallSecondAtP99"], 0)
            self.assertEqual(result["inputSecondsPerWallSecondAtP99"], 5_000_000)
            files["p99.json"][op + " - Time (wall clock)"] = 800
            (directory / "p99.json").write_text(json.dumps(files["p99.json"]))
            with self.assertRaisesRegex(ValueError, "digest"):
                denominators.schedule(directory, name)

    def test_bundle_preserves_published_bytes_and_checks_semantic_values(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = root / "published.json"
            published = json.loads(prepare.MANIFEST.read_bytes())
            manifest.write_text(json.dumps(published, sort_keys=True))
            with patch.object(prepare, "MANIFEST", manifest):
                digest = prepare.prepare(root / "bundle")
                self.assertEqual((root / "bundle/manifest.json").read_bytes(), manifest.read_bytes())
                self.assertEqual(digest, records.sha(manifest))
                published["workloads"][0]["expectedFrameSequenceSHA256"] = "0" * 64
                manifest.write_text(json.dumps(published))
                with self.assertRaisesRegex(ValueError, "manifest differs"):
                    prepare.prepare(root / "altered")

    def test_reviewed_budget_evidence_units_and_percentile_order(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp)
            (p / "trials").write_bytes(b"unit-test evidence")
            record = dict.fromkeys(("deviceModel", "architecture", "osBuild", "profileID", "workloadID",
                                    "operation", "schedulingRationale", "dropoutPolicy", "backlogPolicy",
                                    "approvedBy", "reviewURL"), "test")
            record.update(schemaVersion=1, status="approved", approvedAtUTC="2026-01-01T00:00:00Z",
                          reviewURL="https://example.org/reviews/1",
                          change="initial", commit="a"*40, evidence=[{"file":"trials",
                          "sha256": hashlib.sha256(b"unit-test evidence").hexdigest()}],
                          limits={name: dict(unit=unit, value=1, bound="minimum" if name=="throughput" else "maximum")
                                  for name,unit in budgets.UNITS.items()})
            budgets.validate(record, p)
            with self.assertRaisesRegex(ValueError, "review URL"):
                budgets.validate(record | {"reviewURL": "test"}, p)
            previous = p / "first.json"
            previous.write_text(json.dumps(record))
            replacement = record | dict(change="replacement", changeReason="repeated trials",
                                        previousApprovalFile=previous.name, previousApprovalSHA256=records.sha(previous))
            budgets.validate(replacement, p)
            with self.assertRaisesRegex(ValueError, "scope"):
                budgets.validate(replacement | {"profileID": "other"}, p)
            with self.assertRaisesRegex(ValueError, "digest"):
                budgets.validate(replacement | {"previousApprovalSHA256": "0" * 64}, p)
            record["limits"]["processingP50"]["value"] = 2
            with self.assertRaisesRegex(ValueError, "percentile"):
                budgets.validate(record, p)
            record["limits"]["processingP50"]["value"] = 1
            (p / "trials").write_bytes(b"different")
            with self.assertRaisesRegex(ValueError, "digest"):
                budgets.validate(record, p)
