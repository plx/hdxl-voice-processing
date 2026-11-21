"""Catch denominator substitutions, case ambiguity and unsupported budget promotion."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Performance import budgets, denominators, records


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
            self.assertEqual(result["averageNanosecondsPerFrameInP99Batch"], 2000)
            self.assertEqual(result["singleFrameLatencyDistribution"], "unmeasured")

    def test_reviewed_budget_evidence_units_and_percentile_order(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp)
            (p / "trials").write_bytes(b"unit-test evidence")
            record = dict.fromkeys(("deviceModel", "architecture", "osBuild", "profileID", "workloadID",
                                    "operation", "schedulingRationale", "dropoutPolicy", "backlogPolicy",
                                    "approvedBy", "reviewURL"), "test")
            record.update(schemaVersion=1, status="approved", approvedAtUTC="2026-01-01T00:00:00Z",
                          change="initial", commit="a"*40, evidence=[{"file":"trials",
                          "sha256": hashlib.sha256(b"unit-test evidence").hexdigest()}],
                          limits={name: dict(unit=unit, value=1, bound="minimum" if name=="throughput" else "maximum")
                                  for name,unit in budgets.UNITS.items()})
            budgets.validate(record, p)
            record["limits"]["processingP50"]["value"] = 2
            with self.assertRaisesRegex(ValueError, "percentile"):
                budgets.validate(record, p)
            record["limits"]["processingP50"]["value"] = 1
            (p / "trials").write_bytes(b"different")
            with self.assertRaisesRegex(ValueError, "digest"):
                budgets.validate(record, p)
