"""A simulator receipt must establish the selected Watch workload and its evidence scope."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Watch import probe


class WatchReplayTests(unittest.TestCase):
    def setUp(self):
        self.sample = {
            "schemaVersion": 1, "source": "synthetic-file", "environment": "watchOS Simulator",
            "captureDrops": "unobservable", "status": "published",
            "events": [{"name": name} for name in ("started", "analysis-started", "published")],
            "result": {"frames": 16000, "sampleRate": 16000, "channels": 1, "windows": 10,
                       "profileSHA256": "a" * 64, "lastWindow": {"status": "finite", "finiteDecibels": -6.020599913}},
        }

    def test_accepts_known_replay_with_scene_events(self):
        self.sample["events"].insert(1, {"name": "scene-active"})
        probe.validate_replay(self.sample)

    def test_requires_simulator_without_microphone_or_measured_drops(self):
        for change in [{"environment": "watchOS device"}, {"source": "microphone-file"}, {"input": {}},
                       {"captureDrops": 0}, {"recorderStopToResultReadySeconds": 0.1}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                probe.validate_replay(self.sample | change)

    def test_rejects_wrong_window_count_level_and_accidental_recording(self):
        for change in [{"windows": 9}, {"frames": 15999}, {"channels": 2},
                       {"lastWindow": {"status": "finite", "finiteDecibels": 0.0}}]:
            trial = copy.deepcopy(self.sample)
            trial["result"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                probe.validate_replay(trial)
        self.sample["events"].insert(1, {"name": "permission-requested"})
        with self.assertRaises(ValueError):
            probe.validate_replay(self.sample)
