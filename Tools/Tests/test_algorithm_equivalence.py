"""Mutation checks for the PCM evidence reader, independent of a Swift toolchain."""
import base64
from copy import deepcopy
import json
from pathlib import Path
import struct
import sys
from tempfile import TemporaryDirectory
import unittest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from Equivalence import compare, inputs, regressions


class AlgorithmEquivalenceTests(unittest.TestCase):
    def test_governed_inputs_have_explicit_outcomes_and_exact_common_pcm(self):
        with TemporaryDirectory() as folder:
            dest = Path(folder) / "pcm"
            manifest = inputs.prepare(dest)
            by_name = {}
            for item in manifest["cases"]:
                by_name.setdefault(item["pair"], {})[item["representation"]] = item
            excluded = {r["name"]: r["reason"] for r in manifest["unavailable"]}
            catalog = json.loads((inputs.FIXTURES / "Synthetic/catalog.json").read_bytes())
            corpus = json.loads((inputs.FIXTURES / "Corpus/manifest.json").read_bytes())
            for row in [*catalog["cases"], *corpus["fixtures"]]:
                name = row["id"]
                self.assertNotEqual(name in excluded, name in by_name, name)
            self.assertEqual(excluded["empty"], "insufficientData")
            self.assertIn("missingAcquisition", excluded.values())
            self.assertEqual(by_name["short-120ms"]["float32"]["sampleCount"], 1920)
            for seed in ("noise-seed-seven", "noise-seed-zero"):
                self.assertEqual(by_name[seed]["float32"]["condition"], "aperiodic")
            self.assertEqual(by_name["inharmonic"]["float64"]["condition"], "inharmonic")
            pair = by_name["off-bin-tone"]
            def pcm(label):
                return (dest / (pair[label]["pcmSHA256"] + ".pcm")).read_bytes()
            self.assertEqual(b"".join(struct.pack("<d", x) for x, in struct.iter_unpack("<f", pcm("float32"))), pcm("widened"))
            self.assertNotEqual(pcm("widened"), pcm("float64"))

    def test_source_position_reason_and_zero_are_independent(self):
        reference = dict(values={"rms": [dict(sample=5, value=0), dict(sample=10, reason="insufficientData")]})
        self.assertEqual(compare.distribution(reference, reference, 16000)["rms"]["available"]["count"], 1)
        for change in (dict(sample=6, value=0), dict(sample=5, reason="insufficientData"), dict(sample=5, value=1e-15)):
            edited = deepcopy(reference)
            edited["values"]["rms"][0] = change
            with self.assertRaises(ValueError):
                compare.distribution(reference, edited, 16000)
        shifted = dict(values={"rms": [dict(sample=6, value=3)]})
        delta = compare.distribution(reference, shifted, 16000, different_input=True)["rms"]
        self.assertEqual(delta["absent -> available"]["count"], 1)
        self.assertEqual(delta["available -> absent"]["count"], 1)

    def test_precision_fails_if_candidate_or_support_changes_at_fixed_scalar(self):
        obs = dict(values={}, support={"yin": [dict(selectedCandidate=2)]}, descriptors={}, nativeUnits={},
                   candidates={"yin": [dict(count=3)]}, landmarks=[], spectra={}, cycleAmplitudes=[], completions=[])
        report = dict(reference=dict(conformance=obs, perturbationCoverage=[]), fixture=dict(sampleRate=16000))
        compare.precision(report, report)
        for key in ("support", "candidates", "landmarks", "cycleAmplitudes", "completions"):
            altered = deepcopy(report)
            altered["reference"]["conformance"][key] = ["changed"]
            with self.assertRaisesRegex(ValueError, key):
                compare.precision(report, altered)

    def test_every_spectral_bin_is_finite_and_checked_in_its_own_row(self):
        def bins(a, b):
            return dict(rows=[dict(start=0, count=2, status="measured"), dict(start=8, count=2, status="measured")],
                        values=base64.b64encode(struct.pack("<4d", 10, 1, a, b)).decode())
        original = bins(1e-20, 2e-20)
        self.assertEqual(compare.spectral_difference(original, original, transform_length=64)["bins"], 4)
        for values in ((2e-20, 1e-20), (1e-20, float("nan")), (-1e-20, 2e-20)):
            with self.assertRaises(ValueError):
                compare.spectral_difference(original, bins(*values), transform_length=64)
        measured = compare.spectral_difference(original, bins(1e-20, 1e-10))
        self.assertEqual((measured["worstSourceSample"], measured["worstBin"], measured["bins"]), (8, 1, 4))
        self.assertAlmostEqual(measured["maxAbsoluteError"], 1e-10-2e-20, delta=1e-25)
        missing = deepcopy(original)
        missing["rows"][0]["start"] = 1
        with self.assertRaisesRegex(ValueError, "source index"):
            compare.spectral_difference(original, missing, transform_length=64)

    def test_only_rolling_end_cursor_can_use_first_missing_sample(self):
        spans = [(0, 1536), (1537, 2559)]
        self.assertFalse(compare.sample_is_acquired("rms", 1536, spans))
        self.assertTrue(compare.sample_is_acquired("rms", 1537, spans))
        self.assertTrue(compare.sample_is_acquired("rollingCPPS", 1536, spans))

    def test_tracked_selection_must_index_the_current_borrowed_candidates(self):
        frame = dict(epoch=0, selectedCandidate=0, trackedCandidate=1)
        frames = {"yin.fundamentalFrequency": [frame]}
        candidates = {"yin": [dict(epoch=0, frame=0, count=2)]}
        compare.validate_candidates(candidates, frames, "core", False)
        frame["trackedCandidate"] = 2
        with self.assertRaisesRegex(ValueError, "candidate index"):
            compare.validate_candidates(candidates, frames, "core", False)

    def test_rounding_can_change_voicing_history_and_export_confidence_on_same_window(self):
        a = dict(epoch=0, windowStart=160, windowCount=800, dependencyStart=160, dependencyCount=800,
                 eligible=800, effectiveDelaySeconds=0.025, outcome=dict(status="unavailable", reason="unvoiced"))
        b = dict(a, dependencyStart=0, dependencyCount=960, eligible=960, effectiveDelaySeconds=0.035,
                 outcome=dict(status="available", estimate=dict(value=250, confidence=0.94)))
        left, right = (dict(support={"yin.trackedFundamentalFrequency": [row]}) for row in (a,b))
        differences = compare.quantized_support(left, right)["yin.trackedFundamentalFrequency"][0]["changes"]
        self.assertEqual(differences["dependencyCount"], {"native":800, "rounded":960})
        self.assertEqual(differences["outcome"]["rounded"]["estimate"]["confidence"], 0.94)
        b["windowStart"] += 1
        with self.assertRaisesRegex(ValueError, "observation window"):
            compare.quantized_support(left, right)

    def test_pulse_alignment_reports_insertions_amplitudes_and_shifted_support(self):
        def sequence(times, levels):
            return dict(landmarks=[dict(epoch=0, sourceStart=0, index=i, timeSeconds=t) for i,t in enumerate(times)],
                        cycleAmplitudes=[dict(pulse=i, rms=v) for i,v in enumerate(levels)])
        original = sequence([0.01, 0.03, 0.04], [0.1, 0.2, 0.3])
        rounded = sequence([0.01, 0.02, 0.030001, 0.04], [0.1, 0.4, 0.25, 0.3])
        diff = compare.pulse_changes(original, rounded, 16000, 0.02)
        self.assertEqual((diff["matched"], len(diff["nativeOnly"]), len(diff["roundedOnly"])), (3, 0, 1))
        self.assertEqual(diff["roundedOnly"][0]["landmark"]["timeSeconds"], 0.02)
        self.assertAlmostEqual(diff["changed"][0]["rmsDelta"], 0.05)
        self.assertAlmostEqual(diff["changed"][0]["timeDeltaSeconds"], 1e-6)

    def test_independent_transforms_and_shared_compositions_retain_exact_observations(self):
        full = dict(values={"cpp": "a", "rms": "b"}, support={}, candidates={}, completions={"cpps":"same"}, spectralRows=3, outputSHA256="abc")
        bundles = dict(cpps=dict(full, values={"cpp":"a"}, spectralRows=0), core=dict(full, spectralRows=0),
                       full=full, separateSpectra=dict(full, spectralRows=6))
        compare.check_compositions(bundles)
        for label, update in (("cpps", dict(values={"cpp":"changed"})), ("core", dict(spectralRows=1)),
                              ("cpps", dict(completions={"cpps":"different"})),
                              ("separateSpectra", dict(outputSHA256="def")), ("separateSpectra", dict(spectralRows=3))):
            altered = deepcopy(bundles)
            altered[label].update(update)
            with self.assertRaises(ValueError):
                compare.check_compositions(altered)

    def test_report_from_another_target_or_input_is_rejected(self):
        fixture = dict(name="source", pcmSHA256="a" * 64)
        execution = dict(platform="macOS", architecture="arm64", operatingSystem="27.0")
        report = dict(fixture=fixture, execution=execution)
        with self.assertRaisesRegex(ValueError, "identity"):
            compare.validate(report, dict(fixture, pcmSHA256="b" * 64), "full", "macOS", "arm64")
        for target in (("macOS", "x86_64"), ("iOS Simulator", "arm64")):
            with self.assertRaisesRegex(ValueError, "platform or architecture"):
                compare.validate(report, fixture, "full", *target)

    def test_missing_skipped_and_duplicated_native_regressions_fail(self):
        names = [n for group in regressions.CASES.values() for n in group]
        rows = [f'<testcase name="{n}()" classname="HDXLVoiceProcessingTests.Profile"/>' for n in names]
        def xml(cases):
            return "<testsuite>" + "".join(cases) + "</testsuite>"
        self.assertEqual(sum(map(len, regressions.index([xml(rows)]).values())), len(names))
        for altered in (rows[:-1], rows + rows[:1], [rows[0].replace("/>", "><skipped/></testcase>"), *rows[1:]]):
            with self.assertRaisesRegex(ValueError, "unsuccessful conformance regression"):
                regressions.index([xml(altered)])
