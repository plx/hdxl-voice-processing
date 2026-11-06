import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Tools/Transport" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


audit = load("transport_audit", "audit_callback.py")
benchmark = load("transport_benchmark", "benchmark.py")


def function(name, body):
    return f"; -- Begin function {name}\n_{name}:\n{body}\n; -- End function\n"


def assembly():
    offer = "$sAudioPCMTransferC5offer33_hash"
    return (
        function("$sAudioPCMTransferC16offerInterleaved_args", f"\tbl _{offer}\n\tret")
        + function("$sAudioPCMTransferC11offerPlanar_args", f"\tbl _{offer}\n\tret")
        + function(offer, "Lentry:\n\tcasa w0, w1, [x2]\n\tldclrl w0, w1, [x2]\n"
                         "\tldsetal w0, w1, [x2]\n\tstlr x0, [x1]\n\tbl _memmove\n\tret")
    )


class CallbackAuditTests(unittest.TestCase):
    def test_accepts_expected_bounded_shape(self):
        functions, result = audit.audit(assembly(), "arm64")
        self.assertEqual(len(functions), 3)
        self.assertTrue(result["nativeSingleAttemptAdmission"])

    def test_rejects_runtime_allocation_and_indirect_calls(self):
        for replacement in ("bl _swift_allocObject", "blr x16", "braa x16, x17", "blraa x16, x17", "b _swift_release", "bl _pthread_mutex_lock"):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                audit.audit(assembly().replace("bl _memmove", replacement), "arm64")

    def test_rejects_cas_retry_and_exclusive_loop_instructions(self):
        for replacement in ("b.ne Lentry", "ldaxr w0, [x1]", "casa w0, w1, [x2]"):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                audit.audit(assembly().replace("bl _memmove", replacement), "arm64")

    def test_rejects_missing_or_duplicate_entry(self):
        with self.assertRaises(ValueError):
            audit.audit(assembly().replace("C11offerPlanar_", "C11renamed_"), "arm64")
        with self.assertRaises(ValueError):
            audit.audit(assembly() + function("$sOtherC11offerPlanar_args", "ret"), "arm64")


def histogram(metric, maximum):
    return {"metric": {metric: {}}, "scalingFactor": 1,
            "statistics": {"histogram": {"_totalCount": 20, "maxValue": maximum, "counts": [20]}}}


def allocation_raw():
    rows = []
    for name in ("Transport.FirstOffer.example", benchmark.CONTROL):
        rows += [{"name": name, "target": "TransportBenchmarks"}, [
            histogram(metric, 10 if metric == "wallClock" or name == benchmark.CONTROL else 0)
            for metric in ("wallClock", *benchmark.DIAGNOSTICS)
        ]]
    return {"results": rows}


class TransportEvidenceTests(unittest.TestCase):
    names = {"Transport.FirstOffer.example"}

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
        rows = [{"name": "Transport.FirstOffer.example - " + metric, "value": 10, "unit": "ns"}
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
