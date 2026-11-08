import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("capture_delivery", Path(__file__).parents[1] / "Capture/delivery.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


def trials():
    """Independent small workload satisfying the evidence contract, not recorded timing."""
    rows = []
    for profile in ("levels", "full"):
        for mode_index, mode in enumerate(("disabled", "sampled", "detailed")):
            for overload in (False, True):
                for trial in range(3):
                    pattern = "pcm-overload" if overload else "display-coalescing"
                    raw = []
                    for burst in range(16):
                        for depth in range(4, 0, -1):
                            raw.append(dict(pcmDepthBefore=depth, pcmDepthAfter=depth - 1,
                                            dequeuedBlocks=1, emittedResults=2, consumedSourceFrames=2048,
                                            cumulativeDroppedFrames=(burst + 1) * 8192 if overload else 0,
                                            slowBufferedResults=1, workerCallNanoseconds=100 + 10 * mode_index + trial,
                                            blockStampToFirstResultNanoseconds=200))
                        if overload and burst < 15:
                            raw.append(dict(pcmDepthBefore=0, pcmDepthAfter=0, dequeuedBlocks=0,
                                            emittedResults=3, consumedSourceFrames=0,
                                            cumulativeDroppedFrames=(burst + 1) * 8192,
                                            slowBufferedResults=1, workerCallNanoseconds=100 + 10 * mode_index + trial))
                    raw.append(dict(pcmDepthBefore=0, pcmDepthAfter=0, dequeuedBlocks=0,
                                    emittedResults=2 if overload else 1, consumedSourceFrames=0,
                                    cumulativeDroppedFrames=131072 if overload else 0,
                                    slowBufferedResults=1, workerCallNanoseconds=100 + 10 * mode_index + trial))
                    if mode != "disabled":
                        for observation in raw:
                            observation.update(processingNanoseconds=50, workerToPublicationNanoseconds=10)
                            if observation["dequeuedBlocks"]:
                                observation["captureBlockStartToWorkerNanoseconds"] = 150
                    publications = sum(r["emittedResults"] for r in raw) + 4
                    rows.append(dict(
                        profile=profile, mode=mode, pattern=pattern, trial=trial,
                        profileSHA256=hashlib.sha256(profile.encode()).hexdigest(),
                        scientificSHA256=hashlib.sha256((profile + pattern).encode()).hexdigest(),
                        sampleRate=44100, chunkFrames=2048, slotCount=4, bursts=16,
                        offeredChunks=128 if overload else 64, acceptedChunks=64,
                        overflowChunks=64 if overload else 0, droppedPCMFrames=131072 if overload else 0,
                        pcmHighWaterSlots=4, emittedFrames=publications - (51 if overload else 5),
                        availableCPPSEstimates=32 if profile == "full" else 0,
                        gapEvents=16 if overload else 0, knownMissingFrames=131072 if overload else 0,
                        unknownExtentGaps=0, resets=15 if overload else 0, publications=publications,
                        fastDelivered=publications, fastCoalesced=0, slowDelivered=5,
                        slowCoalesced=publications - 5, slowHighWater=1, strictDelivered=8,
                        strictRejected=1, strictHighWater=8, strictErrors=1, completions=1,
                        activeSubscribersAfterFinish=0, processingSamples=len(raw) if mode != "disabled" else 0,
                        captureLatencySamples=64 if mode != "disabled" else 0,
                        publicationLatencySamples=len(raw) if mode != "disabled" else 0,
                        workerCallTotalNanoseconds=sum(r["workerCallNanoseconds"] for r in raw),
                        publicationTotalNanoseconds=publications * (3 + mode_index),
                        publicationNanoseconds=[3 + mode_index] * publications,
                        fastSubscriberLagNanoseconds=[0] * publications,
                        slowSubscriberLagNanoseconds=[200] * 5, drains=raw))
    return rows


class DeliveryEvidenceTests(unittest.TestCase):
    def test_matrix_distributions_and_paired_modes_retain_measured_scope(self):
        summary = PROBE.validate_trials(trials())
        self.assertEqual(len(summary["groups"]), 12)
        self.assertEqual(len(summary["pairedModeDifferencesNanoseconds"]), 8)
        disabled = summary["groups"]["levels/disabled/display-coalescing"]
        self.assertEqual(disabled["processingNanoseconds"], {"unit": "nanoseconds", "sampleCount": 0})
        self.assertEqual(disabled["workerCallNanoseconds"]["sampleCount"], 195)
        self.assertEqual(disabled["workerCallNanoseconds"]["p50"], 101)
        self.assertEqual(disabled["workerCallNanoseconds"]["p99"], 102)
        self.assertEqual(disabled["fastSubscriberLagNanoseconds"]["minimum"], 0)
        pair = summary["pairedModeDifferencesNanoseconds"]["full/pcm-overload/detailed-minus-disabled"]
        self.assertEqual(pair["workerCallTotalNanoseconds"], [1600] * 3)
        # Measured slowdown is evidence, not a machine-independent pass threshold.
        rows = trials()
        rows[0]["drains"][0]["workerCallNanoseconds"] += 10**15
        rows[0]["workerCallTotalNanoseconds"] += 10**15
        PROBE.validate_trials(rows)

    def test_matrix_cannot_omit_or_duplicate_trials(self):
        rows = trials()
        for changed in (rows[:-1], rows + [rows[0]], [rows[0]] * 36):
            with self.assertRaises(ValueError):
                PROBE.validate_trials(changed)
        rows[0]["mode"] = "unknown"
        with self.assertRaises(ValueError):
            PROBE.validate_trials(rows)

    def test_mode_changes_to_scientific_output_are_rejected(self):
        for key, value in (("scientificSHA256", "0" * 64), ("profileSHA256", "0" * 64),
                           ("emittedFrames", 100), ("availableCPPSEstimates", 0)):
            rows = trials()
            row = next(r for r in rows if r["profile"] == "full" and r["mode"] == "detailed")
            row[key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_trials(rows)

    def test_pcm_loss_and_coalescing_cannot_substitute_for_each_other(self):
        for key, value in (("droppedPCMFrames", 0), ("knownMissingFrames", 0), ("gapEvents", 0),
                           ("slowCoalesced", 0), ("strictErrors", 0), ("strictRejected", 0),
                           ("fastDelivered", 1), ("activeSubscribersAfterFinish", 1)):
            rows = trials()
            next(r for r in rows if r["pattern"] == "pcm-overload")[key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_trials(rows)

    def test_disabled_or_missing_timing_cannot_be_fabricated_as_zero(self):
        for mode, key, value in (("disabled", "processingNanoseconds", 0),
                                 ("disabled", "captureBlockStartToWorkerNanoseconds", 0),
                                 ("sampled", "processingNanoseconds", None),
                                 ("sampled", "captureBlockStartToWorkerNanoseconds", None)):
            rows = trials()
            observation = next(r for r in rows if r["mode"] == mode)["drains"][0]
            if value is None:
                observation.pop(key)
            else:
                observation[key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_trials(rows)

    def test_raw_queue_time_and_loss_observations_must_be_consistent(self):
        for key, value in (("pcmDepthBefore", 5), ("pcmDepthAfter", 4), ("dequeuedBlocks", 2),
                           ("consumedSourceFrames", 2049), ("emittedResults", 257),
                           ("slowBufferedResults", 2), ("workerCallNanoseconds", 0),
                           ("processingNanoseconds", 1000), ("captureBlockStartToWorkerNanoseconds", 201),
                           ("cumulativeDroppedFrames", 0)):
            rows = trials()
            row = next(r for r in rows if r["mode"] == "sampled" and r["pattern"] == "pcm-overload")
            row["drains"][0][key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_trials(rows)
        rows = trials()
        rows[0]["drains"].pop()
        with self.assertRaises(ValueError):
            PROBE.validate_trials(rows)

    def test_invalid_numbers_private_fields_and_inconsistent_totals_are_rejected(self):
        for key, value in (("publicationTotalNanoseconds", 1), ("workerCallTotalNanoseconds", 1),
                           ("trial", True), ("trial", -1), ("trial", float("nan")),
                           ("trial", 2**64), ("deviceUID", "private"), ("audioSamples", [0.25])):
            rows = trials()
            rows[0][key] = value
            with self.assertRaises(ValueError):
                PROBE.validate_trials(rows)
        rows = trials()
        rows[0]["drains"][0]["audioSamples"] = [0.25]
        with self.assertRaises(ValueError):
            PROBE.validate_trials(rows)

    def test_timing_arrays_cannot_be_missing_or_invalid(self):
        for key in ("publicationNanoseconds", "fastSubscriberLagNanoseconds", "slowSubscriberLagNanoseconds"):
            for change in ([], [-1], [float("inf")], [True]):
                rows = trials()
                rows[0][key] = change
                with self.assertRaises(ValueError):
                    PROBE.validate_trials(rows)

    def test_log_requires_one_fresh_record(self):
        record = PROBE.MARKER + json.dumps(trials())
        self.assertEqual(len(PROBE.parse_trials("compiler output\n" + record + "\n")), 36)
        for log in ("", record + "\n" + record, PROBE.MARKER + "[]"):
            with self.assertRaises(ValueError):
                PROBE.parse_trials(log)

    def test_test_report_requires_exact_identity_and_success(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            reports = [{"file": "test.xml", "testCases": 1}]
            valid = '<testcase classname="HDXLVoiceProcessingAudioTests" name="captureDeliveryEvidenceTrials()"/>'
            for case in (valid.replace("captureDeliveryEvidenceTrials", "wrong"),
                         valid.replace("HDXLVoiceProcessingAudioTests", "wrong"),
                         *(valid.replace("/>", f"><{tag}/></testcase>") for tag in ("skipped", "failure", "error")),
                         valid + valid):
                (output / "test.xml").write_text(f"<testsuite>{case}</testsuite>")
                with self.assertRaises(ValueError):
                    PROBE.validate_test_reports(output, reports)
            (output / "test.xml").write_text(f"<testsuite>{valid}</testsuite>")
            PROBE.validate_test_reports(output, reports)
            for invalid in ([], reports + reports, [{"file": "test.xml", "testCases": 0}]):
                with self.assertRaises(ValueError):
                    PROBE.validate_test_reports(output, invalid)
