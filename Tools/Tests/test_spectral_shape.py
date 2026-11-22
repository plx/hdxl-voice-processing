import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from SpectralShape.benchmark import BOUNDARIES, comparisons, throughput


class SpectralShapeEvidenceTests(unittest.TestCase):
    def test_frame_and_sliding_snapshot_denominators(self):
        case = dict(name="fixture", durationSeconds=8, expectedFrames=255)
        wall = dict(p50=1000, p99=2000)
        for op in BOUNDARIES:
            row = throughput(op, case, wall)
            count = 2 if "LTAS" in op else 255
            self.assertEqual(row["spectraPerTrial"], count)
            self.assertEqual(row["spectraPerSecondAtP99Latency"], count * 1e9 / 2000)

    def test_matched_differences_keep_signed_values_and_actual_units(self):
        case = dict(name="fixture", expectedFrames=100)
        values = dict(FFT=2000, FFTAndShape=1900, SharedFrame=3000, SeparateFrame=3200,
                      SharedLTAS=20, SeparateLTAS=50)
        data = {f"SpectralShape.{op}.fixture": {k: dict(p50=v) for k in
                ("wallClock", "mallocCountTotal", "mallocBytesCount")} for op, v in values.items()}
        self.assertEqual([r["differenceOfTrialMediansPerSpectrum"] for r in comparisons(data, [case], "timing")],
                         [-1, 2, 15])
        self.assertEqual({r["metric"] for r in comparisons(data, [case], "allocation")},
                         {"mallocCountTotal", "mallocBytesCount"})
