"""Exercise offline trace attribution, numerical references and failure journals."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from AlgorithmSuite import trace


class OfflineTraceTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.folder = Path(scratch.name)
        self.binary = self.folder / "VoiceSuiteWorkloadCheck"
        self.binary.write_bytes(b"synthetic binary")
        self.output = self.folder / "signposts.json"

    def run_trace(self, outcomes):
        outcomes = iter(outcomes)
        reference = {"fixture": "harmonic-low", "recipe": "synthetic", "results": [
            {"lanes": {lane: {"available": 1, "unavailable": 0} for lane in ("cpp", "cpps", "rollingCPPS")}}
        ]}

        def acquire(arguments, recording, report, journal, validate):
            outcome = next(outcomes)
            self.assertEqual(arguments[-1], report)
            self.assertEqual(arguments[1], "trace")
            payload = {"evidence": reference, "processID": 123}
            if outcome == "different-numbers":
                payload["evidence"] = {}
            if outcome == "wrong-process":
                payload["processID"] = 124
            report.write_text(json.dumps(payload))
            pid = validate(123)
            journal.mark("recorder-finalization")
            if outcome == "timeout":
                raise trace.CollectorTimeout("Recorder finalization timed out")
            recording.write_text(arguments[3])
            return pid

        def export(arguments, **options):
            self.assertEqual(arguments[:3], ["xcrun", "xctrace", "export"])
            arguments[-1].write_bytes(arguments[4].read_bytes())

        def spans(xml, pid):
            self.assertEqual(pid, 123)
            stages = trace.ENABLED if xml == b"cpps" else trace.ENABLED | trace.DISABLED
            return {stage: {"count": 1} for stage in stages}

        with mock.patch.object(sys, "argv", ["trace.py", str(self.binary), str(self.output)]), mock.patch.object(
            trace.ci, "environment", return_value={"commit": "revision", "xcode": "Xcode"}
        ), mock.patch.object(trace, "prepare"), mock.patch.object(
            trace.subprocess, "check_output", return_value=json.dumps(reference).encode()
        ), mock.patch.object(trace, "record_when_ready", side_effect=acquire), mock.patch.object(
            trace.subprocess, "run", side_effect=export
        ), mock.patch.object(trace, "summarize", side_effect=spans):
            trace.main()

    def journal(self):
        file, = self.folder.glob("signposts-attempts-*.json")
        raw = file.read_text()
        self.assertNotIn(str(self.folder), raw)
        return json.loads(raw)

    def test_bounded_retry_keeps_the_reference_and_both_profile_controls(self):
        self.run_trace(["timeout", "passed", "passed"])
        data = json.loads(self.output.read_bytes())
        self.assertEqual(set(data["profiles"]), {"cpps", "full"})
        self.assertEqual(set(data["profiles"]["cpps"]["spans"]), trace.ENABLED)
        self.assertEqual(set(data["profiles"]["full"]["spans"]), trace.ENABLED | trace.DISABLED)
        self.assertEqual(self.journal()["status"], "passed")
        self.assertEqual(len(data["profiles"]["cpps"]["discardedRecordings"]), 1)

    def test_exhausted_collector_keeps_phases_without_publishing_a_result(self):
        with self.assertRaisesRegex(trace.IncompleteRecording, "three attempts"):
            self.run_trace(["timeout"] * 3)
        journal = self.journal()
        self.assertEqual(journal["status"], "failed")
        self.assertEqual([(e["during"], e["reason"]) for e in journal["events"] if e["phase"] == "discarded"],
                         [("recorder-finalization", "timeout")] * 3)
        self.assertFalse(self.output.exists())

    def test_rejects_a_foreign_pid_before_retrying(self):
        self.assert_reference_failure("wrong-process")

    def test_rejects_numerical_mismatch_before_retrying(self):
        self.assert_reference_failure("different-numbers")

    def assert_reference_failure(self, outcome):
        with self.assertRaisesRegex(ValueError, "differ from the reference"):
            self.run_trace([outcome])
        journal = self.journal()
        self.assertEqual(journal["status"], "failed")
        self.assertEqual(journal["events"][-1]["during"], "reference-comparison")
        self.assertFalse(any(e["phase"] == "discarded" for e in journal["events"]))
        self.assertFalse(self.output.exists())
