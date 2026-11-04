"""Failure injection for matrix, units, allocation capabilities, and histogram maxima."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("framing_benchmark", ROOT / "Tools/Framing/benchmark.py")
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


def capture(mode):
    names = [f"Framing.{operation}.case" for operation in benchmark.OPERATIONS]
    metrics = ["wallClock", "cpuTotal"] if mode == "timing" else ["wallClock", *benchmark.DIAGNOSTICS]
    if mode == "allocation":
        names += [benchmark.CONTROL]
    rows = []
    for name in names:
        values = []
        for metric in metrics:
            maximum = 1 if name == benchmark.CONTROL or name.startswith("Framing.Prepare.") or metric == "wallClock" else 0
            values.append({"metric": {metric: {}}, "scalingFactor": 1,
                           "statistics": {"histogram": {"_totalCount": 10, "maxValue": maximum,
                                                        "counts": [10]}}})
        rows += [{"name": name, "target": "FramingBenchmarks"}, values]
    return {"results": rows}


class FramingBenchmarkTests(unittest.TestCase):
    def test_steady_state_zero_requires_every_positive_control(self):
        raw = capture("allocation")
        self.assertEqual(len(benchmark.validate_raw(raw, [{"name": "case"}], "allocation")), 6)
        for metric in benchmark.DIAGNOSTICS:
            broken = copy.deepcopy(raw)
            for row in broken["results"][-1]:
                if metric in row["metric"]:
                    row["statistics"]["histogram"]["maxValue"] = 0
            with self.subTest(metric=metric), self.assertRaisesRegex(ValueError, "Unavailable"):
                benchmark.validate_raw(broken, [{"name": "case"}], "allocation")

    def test_even_one_allocation_in_any_steady_state_distribution_fails(self):
        for operation in benchmark.OPERATIONS[1:]:
            for metric in benchmark.ALLOCATIONS:
                raw = capture("allocation")
                index = 2 * benchmark.OPERATIONS.index(operation) + 1
                for row in raw["results"][index]:
                    if metric in row["metric"]:
                        row["statistics"]["histogram"]["maxValue"] = 1
                with self.subTest(operation=operation, metric=metric), self.assertRaisesRegex(ValueError, "Steady-state"):
                    benchmark.validate_raw(raw, [{"name": "case"}], "allocation")

    def test_missing_duplicate_metrics_empty_histogram_and_scaling_fail(self):
        good = capture("timing")
        bad = []
        value = copy.deepcopy(good); value["results"].pop(); bad.append(value)
        value = copy.deepcopy(good); value["results"][2] = value["results"][0]; bad.append(value)
        value = copy.deepcopy(good); value["results"][1].pop(); bad.append(value)
        value = copy.deepcopy(good); value["results"][1][0]["scalingFactor"] = 100; bad.append(value)
        value = copy.deepcopy(good); value["results"][1][0]["statistics"]["histogram"]["_totalCount"] = 0; bad.append(value)
        value = copy.deepcopy(good); value["results"][1][0]["statistics"]["histogram"]["counts"] = [9]; bad.append(value)
        for raw in bad:
            with self.assertRaises(ValueError):
                benchmark.validate_raw(raw, [{"name": "case"}], "timing")

    def test_export_unit_missing_duplicate_and_nonfinite_values_fail(self):
        good = [{"name": f"case - {metric}", "value": 3, "unit": "ns"}
                for metric in ("Time (wall clock)", "Time (total CPU)")]
        self.assertEqual(len(benchmark.validate_export(good, ["case"], "timing")), 2)
        for rows in [good[:1], good + good, [{**good[0], "unit": "ms"}, good[1]],
                     [{**good[0], "value": float("nan")}, good[1]],
                     [{**good[0], "value": -1}, good[1]]]:
            with self.assertRaises(ValueError):
                benchmark.validate_export(rows, ["case"], "timing")
