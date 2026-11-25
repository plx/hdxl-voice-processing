"""Check the recorder lifecycle independently of the host's Instruments service."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Streaming import trace


class TraceAcquisitionTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.directory = Path(folder.name)
        self.output = self.directory / "signposts.json"
        self.environment = {"commit": "candidate", "xcode": "Xcode under test"}
        self.build = {"binarySHA256": "a" * 64}

    def run_recorder(self, timeout):
        journal = trace.AcquisitionJournal(self.output, self.environment, self.build)
        report = self.directory / "trial.json"
        ready = self.directory / "recorder-started"
        recorder = mock.MagicMock()
        recorder.poll.return_value = None

        def publish_after_start(_):
            self.assertTrue(ready.exists())
            report.write_text("{}")

        def stop(sig):
            self.assertEqual(sig, signal.SIGINT)
            self.assertTrue(report.is_file() and ready.exists())

        def finalize(timeout):
            self.assertEqual(timeout, 120)
            recorder.poll.return_value = 0
            return 0

        recorder.send_signal.side_effect = stop
        recorder.wait.side_effect = subprocess.TimeoutExpired("recorder", 120) if timeout else finalize
        with mock.patch.object(trace.ctypes, "CDLL") as library, mock.patch.object(
            trace.select, "select", return_value=([1], [], [])
        ), mock.patch.object(trace.os, "read", return_value=bytes(4)), mock.patch.object(
            trace.time, "sleep", side_effect=publish_after_start
        ), mock.patch.object(trace.subprocess, "Popen") as launch:
            library.return_value.notify_register_file_descriptor.return_value = 0
            launch.return_value.__enter__.return_value = recorder
            if timeout:
                with self.assertRaisesRegex(trace.CollectorTimeout, "finalization"):
                    trace.record_when_ready([], self.directory / "test.trace", report, journal)
                recorder.kill.assert_called_once_with()
            else:
                trace.record_when_ready([], self.directory / "test.trace", report, journal)
                recorder.kill.assert_not_called()
            recorder.send_signal.assert_called_once_with(signal.SIGINT)
            library.return_value.notify_cancel.assert_called_once()
        self.assertFalse(ready.exists())
        self.assertEqual([e["phase"] for e in journal.data["events"]][-3:],
                         ["recorder-startup", "measured-workload", "recorder-finalization"])

    def test_graceful_stop_follows_atomic_workload_report(self):
        self.run_recorder(False)

    def test_stalled_finalization_releases_target_and_reaps_owned_recorder(self):
        self.run_recorder(True)

    def simulate(self, outcomes):
        fake_binary = self.directory / "probe"
        def run(args, **unused):
            if args[0] == fake_binary:
                args[-1].write_text(json.dumps({"trials": [{"science": {"sha256": "reference"}}]}))
            else:
                self.assertEqual(args[:3], ["xcrun", "xctrace", "export"])
                args[-1].write_text("<trace/>")

        def record(args, output, report, journal):
            outcome = next(outcomes)
            journal.mark("recorder-finalization")
            if outcome == "timeout":
                raise trace.CollectorTimeout("Recorder finalization timed out")
            report.write_text(json.dumps({"trials": [{"science": {"sha256": outcome}}]}))

        with mock.patch.object(trace.ci, "environment", return_value=dict(self.environment)), mock.patch.object(
            trace.ci, "capture", return_value="test"
        ), mock.patch.object(trace, "verified_binary", return_value=(fake_binary, self.build)), mock.patch.object(
            trace.subprocess, "run", side_effect=run
        ), mock.patch.object(trace, "record_when_ready", side_effect=record), mock.patch.object(
            trace, "inspect", return_value={"completeIntervals": 8}
        ), mock.patch.object(trace, "summarize", return_value={}), mock.patch.object(
            sys, "argv", ["trace.py", "build.json", str(self.output)]
        ):
            trace.main()

    def read_journal(self):
        file, = self.directory.glob("signposts-attempts-*.json")
        contents = file.read_text()
        self.assertNotIn(str(self.directory), contents)
        return json.loads(contents)

    def test_timeout_then_validated_retry_preserves_scientific_result(self):
        self.simulate(iter(["timeout", "reference", "reference", "reference"]))
        result = json.loads(self.output.read_bytes())
        self.assertEqual(result["recordings"]["paced"]["discardedRecordings"], ["Recorder finalization timed out"])
        self.assertEqual(set(result["recordings"]), {"paced", "burst", "full"})
        self.assertEqual(self.read_journal()["status"], "passed")

    def test_exhaustion_preserves_three_failures_without_publishing_result(self):
        with self.assertRaisesRegex(trace.IncompleteRecording, "three recordings"):
            self.simulate(iter(["timeout"] * 3))
        journal = self.read_journal()
        self.assertEqual(journal["status"], "failed")
        failures = [(e["during"], e["reason"]) for e in journal["events"] if e["phase"] == "discarded"]
        self.assertEqual(failures, [("recorder-finalization", "timeout")] * 3)
        self.assertFalse(self.output.exists())

    def test_numerical_mismatch_fails_without_retry(self):
        with self.assertRaisesRegex(ValueError, "numerical"):
            self.simulate(iter(["different"]))
        journal = self.read_journal()
        self.assertEqual([e["phase"] for e in journal["events"]].count("attempt"), 1)
        self.assertFalse(any(e["phase"] == "discarded" for e in journal["events"]))
        self.assertEqual(journal["status"], "failed")
        self.assertFalse(self.output.exists())
