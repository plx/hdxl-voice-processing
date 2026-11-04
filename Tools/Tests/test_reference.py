"""Offline reference integrity and adversarial protocol tests; never launches Praat."""
import copy
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

REFERENCE = Path(__file__).resolve().parents[1] / "Reference"
sys.path.insert(0, str(REFERENCE))
import cpps
import voice
from common import ReferenceError, ReferenceFailure, UnsupportedInput, canonical, digest, load_json, number, outcome, pcm_wave, read_pcm
from fixtures import primitive_golden
from profiles import cpps_profile, validate_cpps_profile
from run import assemble, generate
from verify import GOLDENS, compare, compare_outcomes, compare_values, validate, verify_catalog


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.source = read_pcm(GOLDENS / "saw-120ms.wav")[1]
        self.raw = (GOLDENS / "cpps-saw/reference.raw.txt").read_text()
        self.manifest = load_json(GOLDENS / "cpps-saw/reference.json")
        self.lock = load_json(REFERENCE / "toolchain.json")

    def test_complete_offline_catalog(self):
        self.assertEqual(len(verify_catalog()), 2)

    def test_reference_metadata_drift_invalidates_identity(self):
        original = assemble(cpps_profile(), self.source, self.lock, self.raw, True)
        for change in ("input", "version", "profile"):
            source, lock, profile = copy.deepcopy(self.source), copy.deepcopy(self.lock), cpps_profile()
            if change == "input":
                source["artifactSHA256"] = "a" * 64
            elif change == "version":
                lock["version"] = "changed"
            else:
                profile["algorithmSettings"]["fit"]["text"] = "different"
            candidate = assemble(profile, source, lock, self.raw, True)
            self.assertNotEqual(original["referenceIdentity"], candidate["referenceIdentity"])
            self.assertEqual(compare(original, candidate), "identityMismatch")
        with self.assertRaises(ReferenceError):
            validate_cpps_profile(profile)

    def test_comparison_statuses_are_distinct(self):
        changed = copy.deepcopy(self.manifest)
        changed["result"]["outcome"]["estimate"]["value"] += 1
        self.assertEqual(compare(self.manifest, changed), "referenceDisagreement")
        self.assertEqual(compare_outcomes(outcome(0), {"status": "unavailable", "reason": "unsupportedRange"}), "unsupportedInput")
        self.assertEqual(compare_outcomes(outcome(None), outcome(None)), "matchingUnavailable")
        self.assertEqual(compare_outcomes(outcome(None), outcome(0)), "referenceDisagreement")
        self.assertFalse(compare_values({"frameCount": 1}, {"frameCount": 1.000000001}))
        self.assertTrue(compare_values(0, 1e-12))
        self.assertTrue(compare_values(1, 1 + 1e-12))
        self.assertFalse(compare_values(True, 1))
        self.assertFalse(compare_values(float("nan"), float("nan")))

    def test_profile_rejects_boolean_number_type_confusion(self):
        edits = (
            lambda p: p.update(schemaVersion=True),
            lambda p: p["identifier"].update(version=True),
            lambda p: p["channels"].update(channelIndex=False),
            lambda p: p["algorithmSettings"]["subtractTrendBeforeSmoothing"].update(boolean=0),
        )
        for edit in edits:
            profile = cpps_profile()
            edit(profile)
            with self.assertRaises(ReferenceError):
                validate_cpps_profile(profile)

    def test_praat_binary64_frame_boundaries_after_resampling(self):
        for count, expected in ((1600, 1), (1632, 2), (1760, 5), (1920, 11), (2048, 14), (2400, 25), (3200, 51), (8000, 201)):
            self.assertEqual(cpps.frame_count(count, 16000), expected)

    def test_malformed_empty_truncated_duplicate_and_wrong_axes(self):
        lines = self.raw.splitlines()
        corruptions = ["", "reference failed", "\n".join(lines[:-1]),
                       self.raw.replace("input\t16000\t1920", "input\t48000\t1920"),
                       self.raw.replace("axes\t11\t0.05\t0.002", "axes\t11\t800\t32"),
                       self.raw.replace("frame\traw\t1\t", "frame\traw\t2\t", 1),
                       "\n".join([*lines[:-2], lines[-1]]),
                       self.raw.replace("cell\traw\t1\t1\t", "cell\traw\t999\t1\t", 1)]
        for raw in corruptions:
            with self.subTest(raw=raw[:60]), self.assertRaises(ReferenceFailure):
                cpps.parse(raw, self.source, True)

    def test_undefined_is_never_zero_or_nan(self):
        self.assertIsNone(number("--undefined--"))
        self.assertEqual(number("-0"), 0)
        for token in ("nan", "NaN", "inf", "-Infinity", "1,25", "", "error"):
            with self.subTest(token=token), self.assertRaises(ReferenceFailure):
                number(token)
        self.assertNotEqual(outcome(0), outcome(None))
        with self.assertRaises(ReferenceError):
            canonical({"x": float("inf")})

    def test_pcm_round_trip_and_rejects_bad_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "pcm.wav"
            path.write_bytes(pcm_wave([0, -1, 1, 0.25], 16000))
            values, source = read_pcm(path)
            self.assertEqual(values, [0, -1, 1, 0.25])
            self.assertEqual(source["sampleCount"], 4)
            self.assertEqual(source["normalizedFloat64LESHA256"], digest(struct.pack("<4d", *values)))
            original = path.read_bytes()
            for data in (b"", original[:-1], original + b"x", original[:44] + struct.pack("<I", 99) + original[48:],
                         original[:20] + struct.pack("<H", 2) + original[22:]):
                path.write_bytes(data)
                with self.assertRaises(UnsupportedInput):
                    read_pcm(path)
        for values in ([], [float("nan")], [True], [1.01]):
            with self.assertRaises(UnsupportedInput):
                pcm_wave(values, 16000)

    def test_auxiliary_units_times_and_incomplete_records(self):
        source = {"sampleRate": 16000, "sampleCount": 8000}
        head = "begin\tperturbation\ninput\t16000\t8000\ncount\t1\npulse\t1\t0.1\n"
        scalars = "".join(f"scalar\t{k}\t{u}\t0.01\n" for k, u in voice.UNITS.items() if k != "harmonicToNoiseRatio")
        raw = head + scalars + "end\tperturbation\n"
        result = voice.parse(raw, source, "perturbation")
        self.assertEqual(result["scalars"]["jitterLocal"]["outcome"]["estimate"]["value"], 0.01)
        self.assertEqual(result["scalars"]["jitterAbsolute"]["measurement"]["unit"], "seconds")
        for broken in (raw.replace("fraction", "percent", 1), raw.replace("\t0.1\n", "\t1600\n", 1),
                       raw.replace("scalar\tjitterLocal\tfraction\t0.01\n", ""), raw + "unexpected"):
            with self.assertRaises(ReferenceFailure):
                voice.parse(broken, source, "perturbation")

    def test_silent_hnr_preserves_unavailable(self):
        fixture = validate(GOLDENS / "hnr-silence", GOLDENS / "silence-500ms.wav", "hnr-cc", False)
        hnr = fixture["data"]["scalars"]["harmonicToNoiseRatio"]
        self.assertEqual(hnr["outcome"]["status"], "unavailable")
        self.assertTrue(all(row[1] is None for row in fixture["data"]["rows"]))

    def test_failed_reference_never_writes_candidate(self):
        build = REFERENCE.parents[1] / ".build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=build) as temporary:
            output = Path(temporary) / "candidate"
            with patch("run.verify_tool", return_value=Path("/unused/praat")), \
                 patch("run.subprocess.run") as command:
                command.return_value.returncode = 1
                command.return_value.stderr = "reference failure"
                command.return_value.stdout = ""
                with self.assertRaises(ReferenceFailure):
                    generate(GOLDENS / "saw-120ms.wav", REFERENCE / "Profiles/cpps-murton-praat7.json", Path("unused"), output)
            self.assertFalse(output.exists())

    def test_cpps_limits_are_rejected_before_tool_launch(self):
        build = REFERENCE.parents[1] / ".build"
        build.mkdir(exist_ok=True)
        for count, export in ((61 * 16000, False), (4800, True)):
            with tempfile.TemporaryDirectory(dir=build) as temporary:
                output = Path(temporary) / "candidate"
                source = {**self.source, "sampleCount": count}
                with patch("run.read_pcm", return_value=([0] * count, source)), \
                     patch("run.verify_tool") as verify_tool, patch("run.subprocess.run") as command:
                    with self.assertRaises(UnsupportedInput) as failure:
                        generate(GOLDENS / "saw-120ms.wav", REFERENCE / "Profiles/cpps-murton-praat7.json",
                                 Path("unused"), output, export)
                    self.assertEqual(failure.exception.reason, "unsupportedRange")
                    verify_tool.assert_not_called()
                    command.assert_not_called()
                self.assertFalse(output.exists())

    def test_changed_pcm_and_manifest_are_rejected_offline(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "changed.wav"
            values, _ = read_pcm(GOLDENS / "saw-120ms.wav")
            values[10] = 0.25
            path.write_bytes(pcm_wave(values, 16000))
            with self.assertRaises(ReferenceError):
                validate(GOLDENS / "cpps-saw", path)

    def test_pcm16_and_float32_normalize_to_exact_double_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "pcm.wav"
            for encoding, bits, code, values in ((1, 16, "h", [-32768, 8192, 0]), (3, 32, "f", [-1, 0.25, 0])):
                data = struct.pack("<3" + code, *values)
                fmt = struct.pack("<HHIIHH", encoding, 1, 16000, 16000 * bits // 8, bits // 8, bits)
                chunks = b"fmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(data)) + data
                path.write_bytes(b"RIFF" + struct.pack("<I", len(chunks) + 4) + b"WAVE" + chunks)
                normalized, _ = read_pcm(path)
                self.assertEqual(normalized, [-1, 0.25, 0])

    def test_analytic_golden_has_distinct_input_and_reference_hashes(self):
        golden = primitive_golden()
        self.assertEqual(len({v["normalizedFloat64LESHA256"] for v in golden["vectors"]}), 6)
        self.assertEqual(golden["vectors"][4]["dftImaginary"][2], -2)
        self.assertEqual(golden["vectors"][-1]["rms"], 0)
