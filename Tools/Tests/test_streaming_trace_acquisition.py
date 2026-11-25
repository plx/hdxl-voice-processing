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
import trace_acquisition


class TraceAcquisitionTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.directory = Path(folder.name)
        self.output = self.directory / "signposts.json"
        self.environment = {"commit": "candidate", "xcode": "Xcode under test", "workingTreeDirty": False}
        self.build = {"binarySHA256": "a" * 64}

    def document(self, trial):
        return {"schemaVersion": 1, "processID": 123, "trials": [trial]}

    def run_recorder(self, timeout):
        journal = trace.AcquisitionJournal(self.output, self.environment, self.build["binarySHA256"])
        report = self.directory / "trial.json"
        ready = self.directory / "recorder-started"
        target, recorder = mock.MagicMock(), mock.MagicMock()
        for child in (target, recorder):
            child.poll.return_value = None
            child.__enter__.return_value = child
        target.pid = 123
        baseline = {"science": {"sha256": "reference"}}
        expected = {"profile": "cpps"}

        def publish_after_start(_):
            self.assertTrue(ready.exists())
            report.write_text(json.dumps(self.document(dict(baseline, **expected))))

        def finalize(timeout):
            self.assertTrue(ready.exists() and report.is_file())
            self.assertEqual(timeout, 120)
            recorder.poll.return_value = 0
            return 0

        def exit_target(timeout):
            self.assertFalse(ready.exists())
            self.assertEqual(recorder.poll(), 0)
            target.poll.return_value = 0
            return 0

        target.wait.side_effect = exit_target
        recorder.wait.side_effect = subprocess.TimeoutExpired("recorder", 120) if timeout else finalize
        with mock.patch.object(trace_acquisition.ctypes, "CDLL") as library, mock.patch.object(
            trace_acquisition.select, "select", return_value=([1], [], [])
        ), mock.patch.object(trace_acquisition.os, "read", return_value=bytes(4)), mock.patch.object(
            trace_acquisition.time, "sleep", side_effect=publish_after_start
        ), mock.patch.object(trace, "summarize", return_value={}), mock.patch.object(
            trace.subprocess, "Popen", side_effect=[target, recorder]
        ) as launch:
            library.return_value.notify_register_file_descriptor.return_value = 0
            def verify(pid):
                return trace.read_completed_trial(report, expected, pid, baseline, journal)
            args = (["probe"], self.directory / "test.trace", report, journal, verify)
            if timeout:
                with self.assertRaisesRegex(trace.CollectorTimeout, "finalization"):
                    trace.record_when_ready(*args)
                recorder.kill.assert_called_once_with()
                target.kill.assert_called_once_with()
            else:
                trace.record_when_ready(*args)
                recorder.kill.assert_not_called()
                target.kill.assert_not_called()
                target.wait.assert_called_once_with(timeout=10)
            self.assertEqual(launch.call_args_list[1].args[0][-2:], ["--attach", "123"])
            recorder.send_signal.assert_called_once_with(signal.SIGINT)
            library.return_value.notify_cancel.assert_called_once()
        self.assertFalse(ready.exists())

    def test_graceful_stop_follows_atomic_workload_report(self):
        self.run_recorder(False)

    def test_stalled_finalization_releases_target_and_reaps_owned_recorder(self):
        self.run_recorder(True)

    def simulate(self, outcomes, invalid_workload=False):
        fake_binary = self.directory / "probe"
        def run(args, **unused):
            if args[0] == fake_binary:
                trial = dict(profile=args[1], sampleRate=int(args[2]), pattern=[int(args[3])], load=args[4],
                             mode=args[5], seconds=int(args[6]), seed=int(args[7]), operation=args[8],
                             queueSlots=32, science={"sha256": "reference"})
                args[-1].write_text(json.dumps(self.document(trial)))
            else:
                self.assertEqual(args[:3], ["xcrun", "xctrace", "export"])
                args[-1].write_text("<trace/>")

        def record(args, output, report, journal, validate_report):
            outcome = next(outcomes)
            if outcome == "interrupt":
                journal.mark("recorder-startup")
                raise KeyboardInterrupt
            value = {"timeout": "reference", "mismatched-timeout": "different"}.get(outcome, outcome)
            trial = dict(profile=args[1], sampleRate=int(args[2]), pattern=[int(args[3])], load=args[4],
                         mode=args[5], seconds=int(args[6]), seed=int(args[7]), operation=args[8],
                         queueSlots=32, science={"sha256": value})
            document = self.document(trial)
            if outcome == "wrong-workload":
                document["trials"][0]["load"] = "throughput"
            if outcome == "two-trials":
                document["trials"] *= 2
            report.write_text(json.dumps(document))
            completed = validate_report(123)
            journal.mark("recorder-finalization")
            if outcome.endswith("timeout"):
                raise trace.CollectorTimeout("Recorder finalization timed out")
            return completed

        with mock.patch.object(trace.ci, "environment", return_value=dict(self.environment)), mock.patch.object(
            trace.ci, "capture", return_value="test"
        ), mock.patch.object(trace, "verified_binary", return_value=(fake_binary, self.build)), mock.patch.object(
            trace.subprocess, "run", side_effect=run
        ), mock.patch.object(trace, "record_when_ready", side_effect=record), mock.patch.object(
            trace, "inspect", return_value={"completeIntervals": 8}
        ), mock.patch.object(trace, "summarize", return_value={}, side_effect=ValueError("invalid workload") if invalid_workload else None
        ), mock.patch.object(
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

    def test_timeout_cannot_hide_a_published_numerical_mismatch(self):
        with self.assertRaisesRegex(ValueError, "numerical"):
            self.simulate(iter(["mismatched-timeout", "reference"]))
        events = self.read_journal()["events"]
        self.assertEqual(events[-1]["during"], "reference-comparison")
        self.assertFalse(any(e["phase"] in {"discarded", "validated"} for e in events))

    def test_invalid_workload_is_never_marked_validated(self):
        with self.assertRaisesRegex(ValueError, "invalid workload"):
            self.simulate(iter(["reference"]), invalid_workload=True)
        events = self.read_journal()["events"]
        self.assertEqual(events[-1]["during"], "workload-validation")
        self.assertFalse(any(e["phase"] == "validated" for e in events))

    def test_mislabeled_workload_and_extra_trials_fail_before_retry(self):
        for outcome in ("wrong-workload", "two-trials"):
            with self.subTest(outcome=outcome), self.assertRaisesRegex(ValueError, "requested process and workload"):
                self.simulate(iter([outcome]))

    def test_interrupt_preserves_phase_and_terminal_outcome(self):
        with self.assertRaises(KeyboardInterrupt):
            self.simulate(iter(["interrupt"]))
        journal = self.read_journal()
        self.assertEqual(journal["status"], "interrupted")
        self.assertEqual(journal["events"][-1]["during"], "recorder-startup")

    def test_unignored_journal_preserves_other_provenance_changes(self):
        subprocess.run(["git", "init", "--quiet", self.directory], check=True)
        journal = trace.AcquisitionJournal(self.output, self.environment, self.build["binarySHA256"])
        def environment(_):
            return {"workingTreeDirty": True}
        with mock.patch.object(trace, "ROOT", self.directory.resolve()), mock.patch.object(
            trace.ci, "environment", side_effect=environment
        ):
            self.assertFalse(trace.verification_environment(journal)["workingTreeDirty"])
            (self.directory / "other-source.swift").touch()
            self.assertTrue(trace.verification_environment(journal)["workingTreeDirty"])

    def test_numerical_mismatch_fails_without_retry(self):
        with self.assertRaisesRegex(ValueError, "numerical"):
            self.simulate(iter(["different"]))
        journal = self.read_journal()
        self.assertEqual([e["phase"] for e in journal["events"]].count("attempt"), 1)
        self.assertFalse(any(e["phase"] == "discarded" for e in journal["events"]))
        self.assertEqual(journal["status"], "failed")
        self.assertFalse(self.output.exists())
