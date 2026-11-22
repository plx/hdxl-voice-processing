import copy
import math
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from SpectralProducts import benchmark as products


class SpectralProductEvidenceTests(unittest.TestCase):
    def memory_rows(self):
        rows = []
        for second in range(60, 601, 60):
            measured = 1 + (second * 48000 - 3072) // 1536
            rows.append(dict(seconds=second, measuredFrames=measured, retainedFrames=64,
                             evictedFrames=measured - 64, liveHeapBytes=3_000_000))
        return rows

    def test_memory_requires_complete_work_and_a_bounded_live_heap(self):
        rows = self.memory_rows()
        products.validate_memory(rows)
        for field, value in (("evictedFrames", 0), ("retainedFrames", 65), ("liveHeapBytes", 32_000_000)):
            damaged = copy.deepcopy(rows)
            damaged[-1][field] = value
            with self.assertRaises(ValueError):
                products.validate_memory(damaged)
        with self.assertRaises(ValueError):
            products.validate_memory(rows[:-1])

    def test_generation_and_owned_copy_reject_per_bin_heap_allocations(self):
        products.validate_heap_allocations("Generate", 99, 0)
        with self.assertRaises(ValueError):
            products.validate_heap_allocations("Generate", 99, 99 * 257)
        for operation in ("Retain8", "Retain64", "Export"):
            products.validate_heap_allocations(operation, 99, 99)
            with self.assertRaises(ValueError):
                products.validate_heap_allocations(operation, 99, 25_542)

    def test_histogram_bucket_rounding_and_control_reliability(self):
        counts = [0] * 4097
        counts[3072] = 2  # 4096 through 4099
        counts[4096] = 1  # 8192 through 8199
        hist = dict(_totalCount=3, maxValue=8194, minNonZeroValue=4097, counts=counts,
                    subBucketHalfCountMagnitude=10, unitMagnitude=0)
        values = products.histogram_percentiles(hist)
        self.assertEqual((values[0], values[50], values[99], values[100]), (4097, 4099, 8194, 8194))
        products.validate_control(hist)
        with self.assertRaises(ValueError):
            products.validate_control(dict(counts=[29, 1], minNonZeroValue=1))

    def test_distributions_require_all_operations_and_actual_observations(self):
        case = dict(name="test", durationSeconds=1, expectedFrames=99, expectedCepstralFrames=100)
        names = [f"SpectralProducts.{operation}.test" for operation in products.BOUNDARIES]
        raw = dict(baselineName="run", results=[])
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in names:
                metrics = []
                for metric in ("wallClock", "cpuTotal"):
                    path = root / f"run.{products.TARGET}.{name}.{metric}.histogram.percentiles.tsv"
                    observations = list(range(500, 512))
                    values = [observations[max(0, math.ceil(q * len(observations) / 100) - 1)] for q in range(101)]
                    header = f"Percentile\t{products.METRICS[metric]} (ns) *\n"
                    path.write_text(header + "".join(f"{q}\t{x}\n" for q, x in enumerate(values)))
                    hist = dict(_totalCount=12, maxValue=511, minNonZeroValue=500, counts=[0] * 500 + [1] * 12,
                                subBucketHalfCountMagnitude=10, unitMagnitude=0)
                    metrics.append(dict(metric={metric: {}}, scalingFactor=1, timeUnits="nanoseconds",
                                        statistics=dict(histogram=hist)))
                raw["results"].extend([dict(name=name, target=products.TARGET), metrics])
            data, p99, throughput = products.distributions(raw, root, "run", [case], "timing")
            self.assertEqual(len(p99), 2 * len(names))
            self.assertEqual(data[names[0]]["wallClock"]["p95"], 511)
            self.assertEqual({r["framesPerTrial"] for r in throughput}, {99, 100})
            self.assertAlmostEqual(throughput[0]["framesPerSecondAtP99Latency"], 99e9 / 511)
            saved = path.read_text()
            path.write_text(header + "".join(f"{q}\t6000\n" for q in range(101)))
            with self.assertRaises(ValueError):
                products.distributions(raw, root, "run", [case], "timing")
            path.write_text(saved)
            raw["results"][-1][0]["statistics"]["histogram"]["_totalCount"] = 9
            with self.assertRaises(ValueError):
                products.distributions(raw, root, "run", [case], "timing")
            raw["results"] = raw["results"][:-2]
            with self.assertRaises(ValueError):
                products.distributions(raw, root, "run", [case], "timing")
