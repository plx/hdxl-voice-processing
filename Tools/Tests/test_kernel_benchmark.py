import csv
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_every_owned_copy_must_allocate_even_in_the_lowest_observation(self):
        self.record["workload"]["operation"] = "ownedWindow"
        raw = self.capture("allocation")
        measurement = next(m for m in raw["results"][1] if "mallocCountTotal" in m["metric"])
        histogram = measurement["statistics"]["histogram"]
        histogram.update(maxValue=12, minNonZeroValue=8, counts=[0, 20])
        self.checked(raw, "allocation")
        for minimum, counts in ((7, [0, 20]), (8, [1, 19])):
            with self.subTest(minimum=minimum, counts=counts):
                histogram.update(minNonZeroValue=minimum, counts=counts)
                with self.assertRaisesRegex(ValueError, "owned allocations"):
                    self.checked(raw, "allocation")

    def test_full_percentile_exports_are_preserved_without_host_paths(self):
        self.capture("timing")
        target = self.directory / "framework-percentiles.tar.gz"
        kernels.archive_percentiles(self.directory, target)
        with tarfile.open(target) as archive:
            self.assertEqual(set(archive.getnames()), {p.name for p in self.directory.glob("*.tsv")})
            for m in archive.getmembers():
                self.assertEqual(archive.extractfile(m).read(), (self.directory / m.name).read_bytes())
                self.assertEqual((m.uname, m.gname), ("", ""))

    def test_dirty_build_sources_and_dependency_changes_invalidate_a_pair(self):
        root = self.directory

        def git(*args):
            subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)

        git("init", "--quiet")
        lock = root / "Benchmarks/Package.resolved"
        lock.parent.mkdir()
        lock.write_text("pinned")
        git("add", "Benchmarks/Package.resolved")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial")
        source = root / "Sources/Kernel.swift"
        source.parent.mkdir()
        source.write_text("first")
        with patch.object(kernels.ci, "capture", return_value="test toolchain"):
            identity = kernels.build_identity(root)
            kernels.verify_identity(identity, root)
            source.write_text("second")
            with self.assertRaisesRegex(ValueError, "Build inputs"):
                kernels.verify_identity(identity, root)
            source.write_text("first")
            lock.write_text("changed")
            with self.assertRaisesRegex(ValueError, "Build inputs"):
                kernels.verify_identity(identity, root)

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
        self.assertEqual(float(row["operationsPerSecondInP50Batch"]), 8 * 1e9 / 100)
        self.assertEqual(float(row["unitsPerSecondInP50Batch"]), 17 * 8 * 1e9 / 100)
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
        xml.write_text(xml.read_text().replace("PreparedCPP.fit()", "PreparedCPP.fitForBenchmark()"))
        with self.assertRaisesRegex(ValueError, "No target-process sampled stack"):
            summarize(xml, "backgroundFit")
