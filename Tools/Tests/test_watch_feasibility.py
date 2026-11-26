"""A simulator receipt must establish the selected Watch workload and its evidence scope."""
import copy
import json
import subprocess
import tempfile
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Watch import probe


class WatchRuntimeTests(unittest.TestCase):
    available = {"identifier": probe.WATCH_RUNTIME, "version": "27.0", "buildversion": "24R362",
                 "isAvailable": True, "bundlePath": "/private/example"}

    def setUp(self):
        self.evidence = {}
        self.rows = []
        self.images = {}
        self.query_errors = []
        self.disk_errors = []
        self.operations = []
        self.action = lambda args: (0, b"")
        inventory = patch.object(probe, "command", side_effect=self.inventory)
        runner = patch.object(probe.subprocess, "run", side_effect=self.run_setup)
        sleep = patch.object(probe.time, "sleep")
        for mock in (inventory, runner, sleep):
            mock.start()
            self.addCleanup(mock.stop)

    def inventory(self, *args, timeout, stderr):
        self.assertGreater(timeout, 0)
        self.assertEqual(subprocess.PIPE, stderr)
        if args == ("xcrun", "simctl", "list", "runtimes", "--json"):
            if self.query_errors:
                raise self.query_errors.pop(0)
            return json.dumps({"runtimes": self.rows})
        self.assertEqual(("xcrun", "simctl", "runtime", "list", "-j"), args)
        if self.disk_errors:
            raise self.disk_errors.pop(0)
        return json.dumps(self.images)

    def run_setup(self, args, *, timeout, **kwargs):
        self.assertGreater(timeout, 0)
        self.operations.append(args)
        status, output = self.action(args)
        return subprocess.CompletedProcess(args, status, stdout=output)

    def test_available_runtime_needs_no_setup_and_redacts_paths(self):
        self.rows = [self.available]
        selected = probe.select_runtime(False, self.evidence)
        self.assertEqual("24R362", selected["buildversion"])
        self.assertEqual([], self.operations)
        self.assertNotIn("/private", json.dumps(self.evidence))

    def test_unavailable_pinned_runtime_and_available_wrong_version_cannot_start(self):
        self.rows = [self.available | {"isAvailable": False},
                     self.available | {"identifier": probe.WATCH_RUNTIME[:-1] + "2", "version": "27.2"}]
        self.images = {"private-id": {"platformIdentifier": "com.apple.platform.watchsimulator", "version": "27.0",
                                      "state": "Unmounted", "path": "/private/example"}}
        with self.assertRaisesRegex(RuntimeError, "--install-runtime"):
            probe.select_runtime(False, self.evidence)
        self.assertEqual([], self.operations)
        self.assertEqual([{"ready": False, "pinnedVersion": True}], self.evidence["initialDiskImages"])
        self.assertNotIn("private", json.dumps(self.evidence))

    def test_scanning_existing_image_can_restore_visibility_without_download(self):
        def remount(args):
            self.assertEqual(["xcrun", "simctl", "runtime", "scan-and-mount"], args)
            self.rows = [self.available]
            return 0, b""
        self.action = remount
        self.assertEqual(self.available["identifier"], probe.select_runtime(True, self.evidence)["identifier"])
        self.assertEqual(1, len(self.operations))

    def test_export_and_import_pinned_image_and_clean_scratch(self):
        for name in ("watchOS runtime.dmg", "watchsimulator_27.exportedBundle"):
            with self.subTest(name=name):
                self.rows = []
                self.operations.clear()
                def install(args):
                    if "-downloadPlatform" in args:
                        self.assertEqual(["watchOS", "-buildVersion", "27.0", "-architectureVariant", "arm64", "-exportPath"],
                                         args[2:-1])
                        asset = Path(args[-1]) / name
                        if asset.suffix == ".dmg":
                            asset.touch()
                        else:
                            asset.mkdir()
                            (asset / "contained.dmg").touch()
                    if "-importPlatform" in args:
                        self.assertEqual(Path(self.operations[1][-1]) / name, Path(args[-1]))
                        self.rows = [self.available]
                    return 0, b"/private/machine"
                self.action = install
                self.assertEqual("24R362", probe.select_runtime(True, self.evidence)["buildversion"])
                self.assertEqual(3, len(self.operations))
                self.assertFalse(Path(self.operations[1][-1]).exists())
                self.assertNotIn("private", json.dumps(self.evidence))

    def test_already_downloaded_only_succeeds_after_registration(self):
        def cached(args):
            if "-downloadPlatform" in args:
                self.rows = [self.available]
                return 70, b"watchOS 27.0 is already downloaded."
            return 0, b""
        self.action = cached
        self.assertEqual("24R362", probe.select_runtime(True, self.evidence)["buildversion"])
        self.assertEqual({"exitCode": 70, "alreadyDownloaded": True}, self.evidence["export"])
        self.assertEqual(2, len(self.operations))

    def test_unavailable_after_cached_image_error_is_a_failure(self):
        self.action = lambda args: (70, b"already downloaded /private/test")
        with self.assertRaisesRegex(RuntimeError, "Expected one"):
            probe.select_runtime(True, self.evidence)
        self.assertEqual([], self.evidence["afterExport"])
        self.assertEqual(0, self.evidence["export"]["assetCount"])
        self.assertEqual(2, len(self.operations))
        self.assertNotIn("private", json.dumps(self.evidence))

    def test_exit_70_can_still_provide_a_signed_bundle_for_import(self):
        def export(args):
            if "-downloadPlatform" in args:
                (Path(args[-1]) / "watch.exportedBundle").mkdir()
                return 70, b"watchOS 27.0 is already downloaded."
            if "-importPlatform" in args:
                self.assertTrue(Path(args[-1]).is_dir())
                self.rows = [self.available]
            return 0, b""
        self.action = export
        self.assertEqual("24R362", probe.select_runtime(True, self.evidence)["buildversion"])
        self.assertEqual(70, self.evidence["export"]["exitCode"])
        self.assertEqual(1, self.evidence["export"]["assetCount"])
        self.assertEqual({"exitCode": 0}, self.evidence["import"])

    def test_other_export_errors_never_import_a_partial_file(self):
        def export(args):
            if "-downloadPlatform" in args:
                (Path(args[-1]) / "incomplete.dmg").touch()
                return 1, b"transfer failed"
            return 0, b""
        self.action = export
        with self.assertRaisesRegex(RuntimeError, "could not export"):
            probe.select_runtime(True, self.evidence)
        self.assertNotIn("import", self.evidence)

    def test_transient_inventory_errors_during_registration_preserve_replay(self):
        def install(args):
            if "-downloadPlatform" in args:
                (Path(args[-1]) / "watch.dmg").touch()
            if "-importPlatform" in args:
                self.query_errors = [subprocess.TimeoutExpired(["simctl"], 20),
                                     subprocess.CalledProcessError(70, ["simctl"], stderr=b"/private/machine")]
                self.rows = [self.available]
            return 0, b""
        self.action = install
        self.assertEqual("24R362", probe.select_runtime(True, self.evidence)["buildversion"])
        self.assertEqual([{"stage": "afterImport", "attempt": 1, "timedOut": True},
                          {"stage": "afterImport", "attempt": 2, "exitCode": 70}], self.evidence["queryFailures"])
        self.assertEqual(3, len(self.operations))
        self.assertNotIn("private", json.dumps(self.evidence))

    def test_exhausted_inventory_reads_are_distinct_from_an_empty_inventory(self):
        self.query_errors = [subprocess.TimeoutExpired(["simctl"], 20)] * 3
        with self.assertRaisesRegex(RuntimeError, "could not list"):
            probe.select_runtime(False, self.evidence)
        self.assertIsNone(self.evidence["initial"])
        self.assertEqual(3, len(self.evidence["queryFailures"]))
        self.assertEqual([], self.operations)

    def test_unreadable_inventory_before_and_after_scan_prevents_download(self):
        self.query_errors = [subprocess.TimeoutExpired(["simctl"], 20)] * 7
        with self.assertRaisesRegex(RuntimeError, "could not list runtimes before export"):
            probe.select_runtime(True, self.evidence)
        self.assertEqual([["xcrun", "simctl", "runtime", "scan-and-mount"]], self.operations)
        self.assertIsNone(self.evidence["initial"])
        self.assertIsNone(self.evidence["afterScan"])
        self.assertEqual(7, len(self.evidence["queryFailures"]))

    def test_failure_diagnostics_retry_disk_image_queries(self):
        error = subprocess.CalledProcessError(1, ["simctl"], stderr=b"/private/machine")
        self.disk_errors = [error]
        def export(args):
            if "-downloadPlatform" in args:
                self.disk_errors = [error, subprocess.TimeoutExpired(["simctl"], 20)]
                self.images = {"private-id": {"platformIdentifier": "com.apple.platform.watchsimulator",
                                               "version": "27.0", "state": "Ready"}}
            return 1, b""
        self.action = export
        with self.assertRaisesRegex(RuntimeError, "could not export"):
            probe.select_runtime(True, self.evidence)
        self.assertEqual([], self.evidence["initialDiskImages"])
        self.assertEqual([{"ready": True, "pinnedVersion": True}], self.evidence["finalDiskImages"])
        self.assertEqual([{"stage": "initialDiskImages", "attempt": 1, "exitCode": 1},
                          {"stage": "finalDiskImages", "attempt": 1, "exitCode": 1},
                          {"stage": "finalDiskImages", "attempt": 2, "timedOut": True}], self.evidence["queryFailures"])
        self.assertNotIn("private", json.dumps(self.evidence))

    def test_provisioning_never_guesses_an_exported_asset(self):
        for count in (0, 2):
            with self.subTest(count=count):
                def export(args):
                    if "-downloadPlatform" in args:
                        for index in range(count):
                            (Path(args[-1]) / f"{index}.dmg").touch()
                    return 0, b""
                self.action = export
                with self.assertRaisesRegex(RuntimeError, "Expected one"):
                    probe.select_runtime(True, self.evidence)
                self.assertEqual(count, self.evidence["export"]["assetCount"])
                self.assertNotIn("import", self.evidence)

    def test_import_timeout_or_success_with_no_visible_runtime_fails(self):
        for timeout in (True, False):
            with self.subTest(timeout=timeout):
                def install(args):
                    if "-downloadPlatform" in args:
                        (Path(args[-1]) / "watch.dmg").touch()
                    if "-importPlatform" in args:
                        self.images = {"private-id": {"platformIdentifier": "com.apple.platform.watchsimulator",
                                                      "version": "27.0", "state": "Ready", "path": "/private/example"}}
                        if timeout:
                            raise subprocess.TimeoutExpired(args, 600)
                    return 0, b""
                self.action = install
                self.images = {}
                with self.assertRaisesRegex(RuntimeError, "after import"):
                    probe.select_runtime(True, self.evidence)
                self.assertEqual([], self.evidence["afterImport"])
                self.assertEqual({"timedOut": True} if timeout else {"exitCode": 0}, self.evidence["import"])
                self.assertEqual([], self.evidence["initialDiskImages"])
                self.assertEqual([{"ready": True, "pinnedVersion": True}], self.evidence["finalDiskImages"])
                self.assertNotIn("private", json.dumps(self.evidence))


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
