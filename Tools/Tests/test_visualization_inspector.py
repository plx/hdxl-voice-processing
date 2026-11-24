import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Visualization.inspector import MODES, summarize


class InspectorEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.rows = [dict(mode=mode, profileSHA256="a"*64, frames=240, captured=n, retainedFrames=kept,
                          retainedCurveBytes=kept*4304, retainedMetadataBytes=kept*8,
                          peakRSSBeforeBytes=128, peakRSSAfterBytes=128+kept*32,
                          frameNanoseconds=[30+i]*240, captureNanoseconds=[8]*n, pitchChecksumHz=4000)
                     for i, (mode, (n, kept)) in enumerate(MODES.items())]

    def test_matched_reference_and_incremental_payload(self):
        report = summarize(self.rows)
        self.assertEqual(report["sampled"]["meanFrameDeltaFromProcessorNs"], 3)
        self.assertEqual(report["disabled"]["peakRSSGrowthDeltaFromProcessorBytes"], 0)
        self.assertEqual(report["selected"]["medianCaptureNs"], 8)
        self.assertIsNone(report["disabled"]["medianCaptureNs"])

    def test_missing_work_and_unmatched_observations_are_rejected(self):
        for change in ({"profileSHA256": "b"*64}, {"pitchChecksumHz": 3200}, {"captureNanoseconds": []},
                       {"retainedFrames": 60}, {"peakRSSAfterBytes": 0}, {"retainedMetadataBytes": 0},
                       {"retainedMetadataBytes": float("nan")}, {"retainedCurveBytes": 1}, {"retainedMetadataBytes": True},
                       {"retainedMetadataBytes": 0.25}, {"frameNanoseconds": [0]*240}):
            with self.subTest(change=next(iter(change))):
                rows = copy.deepcopy(self.rows)
                rows[-1].update(change)
                with self.assertRaises(ValueError):
                    summarize(rows)


    def test_nested_timers_must_match_the_selected_frame(self):
        for mode, index in (("selected", 120), ("sampled", 8)):
            rows = copy.deepcopy(self.rows)
            row = next(r for r in rows if r["mode"] == mode)
            row["frameNanoseconds"][index] = 7
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                summarize(rows)
