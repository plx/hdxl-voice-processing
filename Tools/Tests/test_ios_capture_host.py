import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ios_host", Path(__file__).parents[1] / "Capture/ios_host.py")
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)


class IOSHostEvidenceTests(unittest.TestCase):
    def test_available_runtime_never_invokes_downloader(self):
        runtime = {"isAvailable": True, "version": "27.0",
                   "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"}
        with patch.object(HOST.ci, "capture", return_value=json.dumps({"runtimes": [runtime]})), \
                patch.object(HOST.ci, "run_command") as run:
            self.assertEqual(HOST.ensure_runtime(True, io.StringIO(), []), runtime)
            run.assert_not_called()

    def test_wrong_platform_version_or_unavailable_runtime_cannot_pass(self):
        runtimes = [{"isAvailable": True, "version": "27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0"},
                    {"isAvailable": True, "version": "26.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0"},
                    {"isAvailable": False, "version": "27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"}]
        with patch.object(HOST.ci, "capture", return_value=json.dumps({"runtimes": runtimes})), \
                patch.object(HOST.ci, "run_command") as run:
            with self.assertRaises(RuntimeError):
                HOST.ensure_runtime(False, io.StringIO(), [])
            run.assert_not_called()

    def test_install_requires_available_runtime_after_command(self):
        runtime = {"version": "27.0"}
        with patch.object(HOST, "installed_runtime", side_effect=[None, runtime]), \
                patch.object(HOST.ci, "run_command") as run:
            log, commands = io.StringIO(), []
            self.assertEqual(HOST.ensure_runtime(True, log, commands), runtime)
            run.assert_called_once_with(["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", "27.0",
                                         "-architectureVariant", "arm64"], log, commands)
        with patch.object(HOST, "installed_runtime", return_value=None), \
                patch.object(HOST.ci, "run_command"):
            with self.assertRaises(RuntimeError):
                HOST.ensure_runtime(True, io.StringIO(), [])

    def test_probe_requires_all_checks_and_no_unexpected_private_fields(self):
        valid = {"schemaVersion": 1, "status": "passed", "checks": HOST.CHECKS, "evidence": HOST.EVIDENCE}
        HOST.validate_probe(valid)
        for changed in ({**valid, "checks": []}, {**valid, "checks": HOST.CHECKS[:-1]},
                        {**valid, "status": "failed"}, {**valid, "routeUID": "private"}):
            with self.assertRaises(ValueError):
                HOST.validate_probe(changed)

    def test_execution_summary_rejects_skips_empty_and_wrong_runtime(self):
        valid = {"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                 "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                 "devicesAndConfigurations": [{"device": {"platform": "iOS Simulator", "osVersion": "27.0"}}],
                 "testFailures": [], "runtimeWarnings": []}
        HOST.validate_test_summary(valid)
        bad = []
        for key, value in (("passedTests", 0), ("skippedTests", 1), ("failedTests", 1),
                           ("totalTestCount", 0), ("runtimeWarnings", ["warning"]),
                           ("devicesAndConfigurations", [])):
            bad.append({**valid, key: value})
        wrong_runtime = copy.deepcopy(valid)
        wrong_runtime["devicesAndConfigurations"][0]["device"]["osVersion"] = "26.0"
        bad.append(wrong_runtime)
        for changed in bad:
            with self.assertRaises(ValueError):
                HOST.validate_test_summary(changed)
