import copy
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
                    path.write_text("Percentile\tValue\n" + "".join(f"{q}\t{500 + q}\n" for q in range(101)))
                    metrics.append(dict(metric={metric: {}}, scalingFactor=1, timeUnits="nanoseconds",
                                        statistics=dict(histogram=dict(_totalCount=12, maxValue=600, counts=[12]))))
                raw["results"].extend([dict(name=name, target=products.TARGET), metrics])
            data, p99, throughput = products.distributions(raw, root, "run", [case], "timing")
            self.assertEqual(len(p99), 2 * len(names))
            self.assertEqual(data[names[0]]["wallClock"]["p95"], 595)
            self.assertEqual({r["framesPerTrial"] for r in throughput}, {99, 100})
            raw["results"][-1][0]["statistics"]["histogram"]["_totalCount"] = 9
            with self.assertRaises(ValueError):
                products.distributions(raw, root, "run", [case], "timing")
            raw["results"] = raw["results"][:-2]
            with self.assertRaises(ValueError):
                products.distributions(raw, root, "run", [case], "timing")
