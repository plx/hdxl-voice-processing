"""A simulator receipt must establish the selected Watch workload and its evidence scope."""
import copy
import json
import tempfile
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Watch import probe


class WatchReplayTests(unittest.TestCase):
    def setUp(self):
        self.sample = {
            "schemaVersion": 1, "source": "synthetic-file", "environment": "watchOS Simulator",
            "captureDrops": "unobservable", "preflightFileCleanup": "absent", "status": "published",
            "events": [{"name": name} for name in ("started", "analysis-started", "published")],
            "result": {"frames": 16000, "sampleRate": 16000, "channels": 1, "windows": 10,
                       "fileFormatID": 1819304813, "profileSHA256": probe.REPLAY_PROFILE, "lastWindow": {"status": "finite", "finiteDecibels": -6.020599913}},
        }

    def test_accepts_known_replay_with_scene_events(self):
        self.sample["events"].insert(1, {"name": "scene-active"})
        probe.validate_replay(self.sample)

    def test_requires_simulator_without_microphone_or_measured_drops(self):
        for change in [{"environment": "watchOS device"}, {"source": "microphone-file"}, {"input": {}},
                       {"captureDrops": 0}, {"timing": {"resultReadySeconds": 0.1}}, {"privateFileCleanup": "failed"}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                probe.validate_replay(self.sample | change)

    def test_rejects_wrong_window_count_level_and_accidental_recording(self):
        for change in [{"profileSHA256": "a" * 64}, {"windows": 9}, {"frames": 15999}, {"channels": 2},
                       {"lastWindow": {"status": "finite", "finiteDecibels": 0.0}}]:
            trial = copy.deepcopy(self.sample)
            trial["result"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                probe.validate_replay(trial)
        self.sample["events"].insert(1, {"name": "permission-requested"})
        with self.assertRaises(ValueError):
            probe.validate_replay(self.sample)

    def test_failed_receipt_preserves_observations_and_omits_private_content(self):
        self.sample.update(status="analysis-failed", input={"uid": "private"}, machine="private")
        self.sample["events"].extend([{"name": "private"}, {"name": "analysis-error"}])
        observation = probe.failure_observation(self.sample)
        self.assertEqual("analysis-failed", observation["status"])
        self.assertIn("analysis-error", observation["events"])
        self.assertEqual(16000, observation["counts"]["frames"])
        self.assertNotIn("private", str(observation))

    def test_device_creation_failure_keeps_selected_runtime_in_evidence(self):
        runtime = {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "buildversion": "test-build"}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            with patch.object(probe, "runtime", return_value=runtime), patch.object(
                probe, "command", side_effect=RuntimeError("cannot create simulator")
            ), self.assertRaisesRegex(RuntimeError, "cannot create"):
                probe.replay(Path("Watch.app"), False, {"status": "failed"}, output)
            evidence = json.loads(output.read_bytes())
            self.assertEqual(evidence["simulator"]["runtimeBuild"], "test-build")
            self.assertEqual(evidence["simulator"]["deviceType"], probe.DEVICE_TYPE)
            self.assertEqual(evidence["status"], "failed")
