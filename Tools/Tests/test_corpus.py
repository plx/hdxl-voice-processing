"""Licensed source, deterministic transformation, and negative coverage checks."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1] / "Corpus"
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location("voice_corpus", HERE / "corpus.py")
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)


class CorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = C.read_json(C.FIXTURES / "manifest.json")

    def test_complete_offline_reproduction_and_negative_coverage(self):
        with patch("urllib.request.urlopen", side_effect=AssertionError("Unexpected network")):
            manifest = C.verify()
        self.assertEqual(manifest["coverage"]["total"], 21)
        self.assertEqual(len(manifest["coverage"]["available"]), 17)
        unavailable = manifest["coverage"]["unavailable"]
        self.assertEqual([len(unavailable[x]) for x in ("invalidInput", "insufficientData", "unsupportedRange")], [2, 1, 1])
        self.assertEqual(len(manifest["sources"]), 3)
        self.assertEqual({x["task"] for x in manifest["fixtures"]}, {
            "sustained-vowel-a", "sustained-vowel-i", "scripted-all-voiced", "scripted-consonant-rich"})

    def test_missing_license_and_unapproved_annotation_fail(self):
        for mutate, message in [
            (lambda d: d["rights"].pop("license"), "license"),
            (lambda d: d["rights"]["consent"].update(status="unknown"), "consent"),
            (lambda d: d["annotations"].update(participantName="not-permitted"), "annotation"),
        ]:
            with self.subTest(message=message):
                value = copy.deepcopy(self.manifest)
                mutate(value)
                with self.assertRaisesRegex(C.CorpusError, message):
                    C.validate_manifest(value)

    def test_duplicate_identity_path_and_unknown_source_fail(self):
        changes = [("id", self.manifest["fixtures"][1]["id"], "Duplicate fixture"),
                   ("path", self.manifest["fixtures"][1]["path"], "Duplicate artifact"),
                   ("sourceID", "unlisted", "Unknown source")]
        for field, new, message in changes:
            value = copy.deepcopy(self.manifest)
            value["fixtures"][0][field] = new
            with self.subTest(field=field), self.assertRaisesRegex(C.CorpusError, message):
                C.validate_manifest(value)

    def test_bounds_rate_duration_and_broken_chain_fail(self):
        for case, message in [("bounds", "bounds"), ("rate", "rate"), ("duration", "duration"), ("chain", "chain")]:
            value = copy.deepcopy(self.manifest)
            record = value["fixtures"][0]
            if case == "bounds":
                record["sourceSupport"]["startSample"] = value["sources"][0]["sampleCount"]
            elif case == "rate":
                record["sourceSupport"]["sampleRate"] = 16000
            elif case == "duration":
                record["decoded"]["durationSeconds"] += 1
            else:
                record["transformations"][0]["inputSHA256"] = "0" * 64
            with self.subTest(case=case), self.assertRaisesRegex(C.CorpusError, message):
                C.validate_manifest(value)

    def test_coverage_cannot_hide_invalid_or_unsupported_cases(self):
        value = copy.deepcopy(self.manifest)
        value["coverage"]["unavailable"]["unsupportedRange"] = []
        with self.assertRaisesRegex(C.CorpusError, "Coverage"):
            C.validate_manifest(value)
        value = copy.deepcopy(self.manifest)
        value["subsets"]["corpus-difficult/v1"] = []
        with self.assertRaisesRegex(C.CorpusError, "subsets"):
            C.validate_manifest(value)

    def test_paths_reject_traversal_symlinks_and_unlisted_names(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ("../escape.wav", "/tmp/escape.wav", "a//b.wav", "./a.wav"):
                with self.subTest(name=name), self.assertRaises(C.CorpusError):
                    C.safe_path(root, name)
            (root / "link").symlink_to(root / "absent", target_is_directory=True)
            with self.assertRaisesRegex(C.CorpusError, "Symbolic"):
                C.safe_path(root, "link/recording.wav")

    def test_known_answer_integer_gain_clipping_and_truncation(self):
        original = C.wav(struct.pack("<6h", -32768, -257, -1, 0, 257, 32767))
        low, _ = C.apply_step(original, {"kind": "integer-gain", "numerator": 1, "denominator": 256})
        self.assertEqual(C.pcm16(low), [-128, -1, 0, 0, 1, 127])
        clipped, _ = C.apply_step(original, {"kind": "integer-gain", "numerator": 256, "denominator": 1})
        self.assertEqual(C.pcm16(clipped), [-32768, -32768, -256, 0, 32767, 32767])
        data, _ = C.apply_step(original, {"kind": "excerpt", "startSample": 1, "sampleCount": 3})
        self.assertEqual(C.pcm16(data), [-257, -1, 0])
        for start, count in [(5, 2), (True, 1), (-1, 1), (0, 0)]:
            with self.assertRaises(C.CorpusError):
                C.apply_step(original, {"kind": "excerpt", "startSample": start, "sampleCount": count})

    def test_noise_exact_reproduction_and_measured_energy_ratio(self):
        original = C.wav(struct.pack("<6h", -100, 200, -300, 400, -500, 600))
        step = {"kind": "integer-noise", "seed": 1, "amplitudeLSB": 10}
        data, report = C.apply_step(original, step)
        # Independent first six xorshift32 outputs for seed1: 270369,67634689,
        # 2647435461,307599695,2398689233,745495504; modulo21 minus10.
        expected = [x + n % 21 - 10 for x, n in zip([-100, 200, -300, 400, -500, 600],
                    [270369, 67634689, 2647435461, 307599695, 2398689233, 745495504])]
        self.assertEqual(C.pcm16(data), expected)
        self.assertEqual(report["finalState"], 745495504)
        self.assertEqual(report["inputSumSquaresLSB"], 910000)
        self.assertEqual((data, report), C.apply_step(original, step))

    def test_negative_waves_have_specific_input_reasons(self):
        source = C.wav(struct.pack("<4h", -100, 200, 0, 100))
        cases = [({"kind": "duplicate-channel"}, "unsupportedRange"),
                 ({"kind": "empty-payload"}, "insufficientData"),
                 ({"kind": "truncate-file", "removeBytes": 1}, "invalidInput"),
                 ({"kind": "float32-nan", "sampleIndex": 2}, "invalidInput")]
        for step, reason in cases:
            data, _ = C.apply_step(source, step)
            self.assertEqual(C.outcome(data), ({"status": "unavailable", "reason": reason}, None))
        self.assertEqual(C.outcome(C.wav(b"\0\0" * 4))[0]["status"], "available")

    def test_original_hash_change_is_rejected_before_use(self):
        source = C.SOURCES[0]
        data = bytearray(C.read_bytes(C.FIXTURES / "originals" / (source["id"] + ".wav")))
        data[-1] ^= 1
        with self.assertRaisesRegex(C.CorpusError, "Pinned original hash"):
            C.source_record(source, data)

    def test_duplicate_json_key_and_nonfinite_metadata_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "manifest.json"
            for content in ('{"id":1,"id":2}', '{"id":NaN}'):
                path.write_text(content)
                with self.assertRaises(C.CorpusError):
                    C.read_json(path)

    def test_candidates_cannot_replace_committed_or_nonempty_output(self):
        with self.assertRaisesRegex(C.CorpusError, "committed"):
            C.new_output(C.FIXTURES)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / "keep.txt").write_text("keep")
            with self.assertRaisesRegex(C.CorpusError, "new or empty"):
                C.new_output(path)
            self.assertEqual((path / "keep.txt").read_text(), "keep")

    def test_acquisition_identifies_client_and_rejects_changed_bytes(self):
        source = C.SOURCES[0]
        data = bytearray(C.read_bytes(C.FIXTURES / "originals" / (source["id"] + ".wav")))
        data[-1] ^= 1
        with tempfile.TemporaryDirectory() as temp, patch("urllib.request.urlopen", return_value=io.BytesIO(data)) as request:
            with self.assertRaisesRegex(C.CorpusError, "Pinned original hash"):
                C.acquire(Path(temp) / "candidate")
            self.assertTrue(request.call_args.args[0].get_header("User-agent").startswith("HDXLVoiceProcessing-Corpus/"))
            self.assertEqual(list((Path(temp) / "candidate/originals").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
