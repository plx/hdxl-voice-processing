import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("personal_feedback", Path(__file__).parents[1] / "PersonalTargets/feedback.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


def evidence():
    """Small independent contract fixture; the numbers are not measured evidence."""
    rows = []
    for rate in (4, 40, 1000):
        for subscribers in (0, 64):
            for mode_index, mode in enumerate(("disabled", "sampled", "detailed")):
                for trial in range(3):
                    samples = 256 * (16000 // rate)
                    rows.append(dict(rateHz=rate, subscribers=subscribers, mode=mode, trial=trial,
                        targetSHA256="a" * 64, configurationSHA256="b" * 64,
                        outputSHA256=hashlib.sha256(str(rate).encode()).hexdigest(),
                        updateNanoseconds=[100 + mode_index * 10 + trial] * 256,
                        sourceSamples=samples, qualifiedSamples=samples, matchingSamples=samples // 2,
                        acceptedIntervals=256, stateChanges=8, finalState="departedTarget",
                        fastDelivered=258 if subscribers else 0, fastHighWater=1 if subscribers else 0,
                        strictDelivered=4 if subscribers else 0, strictHighWater=4 if subscribers else 0,
                        strictErrors=1 if subscribers else 0, displayDelivered=62 if subscribers else 0,
                        displayCoalesced=62 * 257 if subscribers else 0, displayHighWater=1 if subscribers else 0,
                        activeAfterFinish=0))
    return dict(preparations=[dict(rateHz=r, nanoseconds=[1000] * 256) for r in (4, 40, 1000)], trials=rows)


class PersonalFeedbackEvidenceTests(unittest.TestCase):
    def test_complete_matrix_and_distributions(self):
        report = evidence()
        summary = PROBE.validate_report(report)
        self.assertEqual(len(summary["updateGroups"]), 18)
        self.assertEqual(len(summary["preparationGroups"]), 3)
        self.assertEqual(len(summary["pairedModeTotalDifferencesNanoseconds"]), 12)
        group = summary["updateGroups"]["4Hz/0-observers/disabled"]
        self.assertEqual((group["count"], group["p50"], group["p99"]), (768, 101, 102))
        self.assertEqual(summary["pairedModeTotalDifferencesNanoseconds"]["1000Hz/64-observers/detailed-minus-disabled"], [5120] * 3)
        report["trials"][0]["updateNanoseconds"][0] = 10**15
        PROBE.validate_report(report)  # Host-specific cost is retained, not an arbitrary speed gate.

    def test_missing_duplicate_and_unknown_workloads_rejected(self):
        original = evidence()
        for key, value in (("trials", original["trials"][:-1]), ("trials", [original["trials"][0]] * 54),
                           ("preparations", original["preparations"][:-1]),
                           ("preparations", [original["preparations"][0]] * 3)):
            report = copy.deepcopy(original)
            report[key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_report(report)
        for key, value in (("rateHz", 5), ("mode", "unknown"), ("subscribers", 63), ("trial", 3)):
            report = evidence()
            report["trials"][0][key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_report(report)

    def test_outputs_coverage_and_identity_cannot_change_with_observers_or_modes(self):
        for key, value in (("outputSHA256", "0" * 64), ("targetSHA256", "0" * 64),
                           ("configurationSHA256", "0" * 64), ("stateChanges", 1),
                           ("sourceSamples", 0), ("qualifiedSamples", 0), ("matchingSamples", 0),
                           ("acceptedIntervals", 255), ("finalState", "onTarget")):
            report = evidence()
            report["trials"][-1][key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_report(report)

    def test_resource_and_delivery_failures_rejected(self):
        for key in ("fastDelivered", "fastHighWater", "strictDelivered", "strictHighWater", "strictErrors",
                    "displayDelivered", "displayCoalesced", "displayHighWater", "activeAfterFinish"):
            report = evidence()
            report["trials"][-1][key] += 1
            with self.assertRaises(ValueError):
                PROBE.validate_report(report)

    def test_private_fields_missing_raw_times_and_invalid_numbers_rejected(self):
        for key, value in (("audio", [0.1]), ("routeUID", "private"), ("trial", True), ("trial", -1),
                           ("trial", 2**64), ("stateChanges", float("nan")),
                           ("updateNanoseconds", []), ("updateNanoseconds", [0] * 256),
                           ("updateNanoseconds", [True] * 256), ("updateNanoseconds", [float("inf")] * 256)):
            report = evidence()
            report["trials"][0][key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_report(report)
        report = evidence()
        report["preparations"][0]["nanoseconds"] = []
        with self.assertRaises(ValueError):
            PROBE.validate_report(report)

    def test_log_requires_one_fresh_record(self):
        record = PROBE.MARKER + json.dumps(evidence())
        self.assertEqual(len(PROBE.parse_report("compiler output\n" + record)["trials"]), 54)
        for log in ("", record + "\n" + record, PROBE.MARKER + "{}"):
            with self.assertRaises(ValueError):
                PROBE.parse_report(log)

    def test_exact_successful_test_inventory_required(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            reports = [{"file": "tests.xml", "testCases": 1}]
            case = '<testcase classname="HDXLVoiceProcessingTests" name="feedbackPerformanceEvidenceTrials()"/>'
            for changed in (case.replace("feedbackPerformanceEvidenceTrials", "wrong"),
                            case.replace("HDXLVoiceProcessingTests", "wrong"), case + case,
                            *(case.replace("/>", f"><{tag}/></testcase>") for tag in ("failure", "error", "skipped"))):
                (output / "tests.xml").write_text(f"<testsuite>{changed}</testsuite>")
                with self.assertRaises(ValueError):
                    PROBE.validate_test_reports(output, reports)
            (output / "tests.xml").write_text(f"<testsuite>{case}</testsuite>")
            PROBE.validate_test_reports(output, reports)
            for invalid in ([], reports + reports, [{"file": "tests.xml", "testCases": 0}]):
                with self.assertRaises(ValueError):
                    PROBE.validate_test_reports(output, invalid)
