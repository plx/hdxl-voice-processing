"""Artifact tampering must not turn missing/invalid visualization evidence green."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("visualization_benchmark",
    Path(__file__).resolve().parents[1] / "Visualization/benchmark.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


def population():
    samples = []
    for phase, count in sorted(benchmark.WORKLOADS):
        observed = phase == "mainActorPublicationWithObserver"
        iterations = 1000 if observed else 100
        samples.append({"phase": phase, "count": count, "iterations": iterations, "warmups": 3,
                        "consumedCount": count * iterations, "observerInvalidations": iterations if observed else 0,
                        "minimumNanoseconds": 10, "medianNanoseconds": 20,
                        "p95Nanoseconds": 30, "maximumNanoseconds": 40})
    return [{"trial": trial, "report": {"schemaVersion": 1, "status": "passed", "syntheticOnly": True,
             "dspCaptureOrRenderingExecuted": False, "profileSHA256": "1" * 64, "samples": copy.deepcopy(samples)}}
            for trial in range(benchmark.TRIALS)]


class VisualizationEvidenceTests(unittest.TestCase):
    def test_full_population_and_mutated_evidence(self):
        records = population()
        self.assertEqual(len(benchmark.validate_population(records)), 8)
        self.assertEqual(len(benchmark.negative_controls(records)), 11)

    def test_noninteger_or_nonfinite_timings_fail(self):
        for value in (True, float("nan"), float("inf"), -1, 1.5):
            with self.subTest(value=value), self.assertRaises(ValueError):
                records = population()
                records[0]["report"]["samples"][0]["minimumNanoseconds"] = value
                benchmark.validate_population(records)

    def test_sample_fields_and_iterations_are_required(self):
        for change in (lambda s: s.pop("count"), lambda s: s.update(iterations=1),
                       lambda s: s.update(extra="unexpected"), lambda s: s.update(warmups=0)):
            with self.assertRaises(ValueError):
                records = population()
                change(records[0]["report"]["samples"][0])
                benchmark.validate_population(records)


if __name__ == "__main__":
    unittest.main()
