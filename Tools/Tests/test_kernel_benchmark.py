import csv
import tempfile
import unittest
from pathlib import Path

from Tools.Kernels import benchmark as kernels
from Tools.Kernels.profile import summarize


class KernelEvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.record = {
            "name": "windowCopy.small",
            "operationsPerBatch": 8,
            "workload": {"operation": "windowCopy", "sourceRate": 16_000, "inputSamples": 17},
        }
        self.name = "Kernel.windowCopy.small"

    def capture(self, mode):
        raw = {"baselineName": "run", "results": []}
        names = [(self.name + " (batch: 8)", {"batch": "8"})]
        if mode == "allocation":
            names.append((kernels.CONTROL, {}))
        for name, tags in names:
            measurements = []
            metrics = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *kernels.DIAGNOSTICS}
            for metric in sorted(metrics):
                maximum = 0 if name != kernels.CONTROL and metric in kernels.HEAP else 200
                measurements.append(
                    dict(
                        metric={metric: {}},
                        scalingFactor=1,
                        timeUnits="nanoseconds",
                        tags=tags.copy(),
                        statistics=dict(histogram=dict(_totalCount=20, maxValue=maximum, counts=[20])),
                    )
                )
                path = (
                    self.directory
                    / f"run.{kernels.TARGET}.{name}.{metric}.histogram.percentiles.tsv".replace(" ", "_")
                )
                path.write_text(
                    "Percentile\tmetric\n" + "".join(f"{i}\t{2 * i if maximum else 0}\n" for i in range(101))
                )
            raw["results"].extend([dict(name=name, target=kernels.TARGET), measurements])
        return raw

    def checked(self, raw, mode):
        return kernels.distributions(raw, [self.record], mode, self.directory, "run")

    def test_calibrated_batch_tag_and_unscaled_export(self):
        raw = self.capture("timing")
        dist, p99 = self.checked(raw, "timing")
        self.assertEqual(dist[self.name]["wallClock"]["p50"], 100)
        self.assertEqual(p99[self.name + " - Time (wall clock)"], 198)
        raw["results"][1][0]["tags"]["batch"] = "4"
        with self.assertRaises(ValueError):
            self.checked(raw, "timing")
        raw = self.capture("timing")
        raw["results"][1][0]["scalingFactor"] = 8
        with self.assertRaises(ValueError):
            self.checked(raw, "timing")

    def test_warm_allocation_and_silent_backend_are_rejected(self):
        for index, maximum in ((1, 1), (3, 0)):
            with self.subTest(index=index):
                raw = self.capture("allocation")
                row = next(m for m in raw["results"][index] if "mallocCountTotal" in m["metric"])
                row["statistics"]["histogram"]["maxValue"] = maximum
                with self.assertRaises(ValueError):
                    self.checked(raw, "allocation")

    def test_normalization_keeps_batch_tail_and_input_denominator(self):
        t, _ = self.checked(self.capture("timing"), "timing")
        a, _ = self.checked(self.capture("allocation"), "allocation")
        path = self.directory / "rows.csv"
        kernels.table(path, [self.record], t, a)
        with path.open() as source:
            (row,) = csv.DictReader(source)
        self.assertEqual(int(row["batchP99ns"]), 198)
        self.assertEqual(float(row["meanNsPerOperationInP50Batch"]), 100 / 8)
        self.assertEqual(float(row["meanNsPerUnitInP50Batch"]), 100 / (8 * 17))
        self.assertEqual(kernels.unit({"operation": "fftPrepare"}), (None, None))
        self.assertEqual(kernels.unit({"operation": "ringOverlap", "hop": 32}), ("new ingress sample", 32))

    def test_instruments_references_count_samples_and_exclude_other_processes(self):
        xml = self.directory / "trace.xml"
        xml.write_text("""<trace><row><process id="1" fmt="KernelWorkloadCheck (7)"/><tagged-backtrace id="2">
        <frame id="3" name="PreparedCPP.fit()"><binary id="4" name="KernelWorkloadCheck"/></frame></tagged-backtrace></row>
        <row><process ref="1"/><tagged-backtrace ref="2"/></row>
        <row><process fmt="unrelated (8)"/><tagged-backtrace ref="2"/></row></trace>""")
        result = summarize(xml, "backgroundFit")
        self.assertEqual((result["sampledStacks"], result["attributedStacks"]), (2, 2))
        with self.assertRaises(ValueError):
            summarize(xml, "logPower")
