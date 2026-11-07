import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("capture_lifecycle", Path(__file__).parents[1] / "Capture/lifecycle.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


def trials():
    return [{**PROBE.FIXED, "encoding": e, "channels": c, "maximumFramesPerChunk": n,
             "slotCount": slots, "trial": t, "captureStorageBytes": c * n * slots * width,
             "profileSHA256": hashlib.sha256(f"{e}-{c}".encode()).hexdigest(),
             **{k: t + 1 for k in PROBE.PHASES}}
            for e, width in (("float32", 4), ("float64", 8)) for c in (1, 2)
            for n, slots in ((64, 4), (8192, 16)) for t in range(10)]


class LifecycleEvidenceTests(unittest.TestCase):
    def test_complete_matrix_retains_distribution_not_a_speed_threshold(self):
        rows = trials()
        summary = PROBE.validate_trials(rows)
        self.assertEqual(len(summary["groups"]), 8)
        for group in summary["groups"].values():
            for phase in group.values():
                self.assertEqual(phase, {"sampleCount": 10, "minimum": 1, "maximum": 10,
                                         "mean": 5.5, "p50": 5, "p95": 10, "p99": 10})
        rows[0][PROBE.PHASES[0]] = 10**15
        PROBE.validate_trials(rows)  # No universal machine-independent latency gate.

    def test_missing_duplicate_and_changed_workloads_are_rejected(self):
        valid = trials()
        for changed in (valid[:-1], valid + [valid[0]], [valid[0]] * 80):
            with self.assertRaises(ValueError):
                PROBE.validate_trials(changed)
        for key, value in (("trial", 10), ("slotCount", 8), ("channels", 3), ("encoding", "int16")):
            changed = copy.deepcopy(valid)
            changed[0][key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_trials(changed)

    def test_failed_reclamation_invalid_duration_and_private_fields_are_rejected(self):
        for key, value in (("retiredTransfers", 1), ("releasedObservers", 0), ("failures", 1),
                           ("captureStorageBytes", 1), ("deliveredFrames", 0),
                           (PROBE.PHASES[0], -1), (PROBE.PHASES[0], 0),
                           (PROBE.PHASES[0], True), (PROBE.PHASES[0], float("nan")),
                           (PROBE.PHASES[0], 2**64), ("deviceUID", "private")):
            changed = trials()
            changed[0][key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_trials(changed)

    def test_profile_identity_cannot_change_or_collapse_across_trials(self):
        for profile in ("private", "A" * 64, "0" * 64):
            changed = trials()
            changed[0]["profileSHA256"] = profile
            with self.assertRaises(ValueError):
                PROBE.validate_trials(changed)
        changed = trials()
        for row in changed:
            row["profileSHA256"] = "0" * 64
        with self.assertRaises(ValueError):
            PROBE.validate_trials(changed)

    def test_log_requires_one_fresh_record(self):
        record = PROBE.MARKER + json.dumps(trials())
        self.assertEqual(len(PROBE.parse_trials("ordinary compiler output\n" + record + "\n")), 80)
        for log in ("", record + "\n" + record, PROBE.MARKER + "[]"):
            with self.assertRaises(ValueError):
                PROBE.parse_trials(log)

    def test_wrong_test_skips_and_failures_cannot_certify_probe(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            report = [{"file": "test.xml", "testCases": 1}]
            for name, body in (("wrong()", ""), ("lifecycleResourceTrials()", "<skipped/>"),
                               ("lifecycleResourceTrials()", "<failure/>")):
                (output / "test.xml").write_text(f'<testsuite><testcase classname="HDXLVoiceProcessingAudioTests" name="{name}">{body}</testcase></testsuite>')
                with self.assertRaises(ValueError):
                    PROBE.validate_test_reports(output, report)
            (output / "test.xml").write_text('<testsuite><testcase classname="HDXLVoiceProcessingAudioTests" name="lifecycleResourceTrials()"/></testsuite>')
            PROBE.validate_test_reports(output, report)
