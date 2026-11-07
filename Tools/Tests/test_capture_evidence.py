import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("capture_benchmark", ROOT / "Tools/Capture/benchmark.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


def histogram(metric, maximum):
    return {"metric": {metric: {}}, "scalingFactor": 1,
            "statistics": {"histogram": {"_totalCount": 20, "maxValue": maximum, "counts": [20]}}}


def allocation_raw():
    rows = []
    for name in ("Capture.FirstOffer.example", benchmark.CONTROL):
        rows += [{"name": name, "target": "CaptureBenchmarks"}, [
            histogram(metric, 10 if metric == "wallClock" or name == benchmark.CONTROL else 0)
            for metric in ("wallClock", *benchmark.DIAGNOSTICS)
        ]]
    return {"results": rows}


class CaptureEvidenceTests(unittest.TestCase):
    names = {"Capture.FirstOffer.example"}

    def test_matrix_requires_every_format_size_and_failure_case(self):
        rows = []
        for encoding in ("float32", "float64"):
            for layout in ("planar", "interleaved"):
                for frames in (64, 4096):
                    for operation in ("Accepted", "UnknownClock", "Overflow", "Oversized", "ChangedFormat"):
                        rows.append({"name": f"Capture.{operation}.{encoding}-{layout}-c2-n{frames}",
                                     "configuration": dict(encoding=encoding, layout=layout, frames=frames, operation=operation),
                                     "operationsPerIteration": 1, "verified": True})
        self.assertEqual(len(benchmark.validate_workloads(rows)), 40)
        for variant in (rows[:-1], rows + rows[:1]):
            with self.assertRaises(ValueError):
                benchmark.validate_workloads(variant)
        rows[0]["verified"] = False
        with self.assertRaises(ValueError):
            benchmark.validate_workloads(rows)

    def test_validates_positive_controls_and_all_heap_histograms(self):
        self.assertEqual(len(benchmark.validate_raw(allocation_raw(), self.names, "allocation")), 2)
        for metric in benchmark.HEAP:
            raw = allocation_raw()
            next(row for row in raw["results"][1] if metric in row["metric"])["statistics"]["histogram"]["maxValue"] = 1
            with self.subTest(metric=metric), self.assertRaises(ValueError):
                benchmark.validate_raw(raw, self.names, "allocation")

    def test_unavailable_instrumentation_is_not_zero_allocation(self):
        for metric in benchmark.DIAGNOSTICS:
            raw = allocation_raw()
            next(row for row in raw["results"][3] if metric in row["metric"])["statistics"]["histogram"]["maxValue"] = 0
            with self.subTest(metric=metric), self.assertRaises(ValueError):
                benchmark.validate_raw(raw, self.names, "allocation")

    def test_rejects_partial_duplicate_and_undersampled_results(self):
        raw = allocation_raw()
        variants = [copy.deepcopy(raw) for _ in range(4)]
        variants[0]["results"].pop()
        variants[1]["results"][3].pop()
        variants[2]["results"][1].append(copy.deepcopy(variants[2]["results"][1][0]))
        variants[3]["results"][1][0]["statistics"]["histogram"]["_totalCount"] = 9
        for variant in variants:
            with self.assertRaises(ValueError):
                benchmark.validate_raw(variant, self.names, "allocation")

    def test_export_requires_finite_complete_typed_metrics(self):
        rows = [{"name": "Capture.FirstOffer.example - " + metric, "value": 10, "unit": "ns"}
                for metric in ("Time (wall clock)", "Time (total CPU)")]
        benchmark.validate_export(rows, self.names, "timing")
        for value in (float("nan"), -1, True):
            changed = copy.deepcopy(rows)
            changed[0]["value"] = value
            with self.assertRaises(ValueError):
                benchmark.validate_export(changed, self.names, "timing")
        with self.assertRaises(ValueError):
            benchmark.validate_export(rows[:1], self.names, "timing")


if __name__ == "__main__":
    unittest.main()
