import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("calibration_generator", ROOT / "Tools/Calibration/generate.py")
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


class CalibrationFixtureTests(unittest.TestCase):
    def test_committed_bytes_and_independent_pcm_geometry(self):
        manifest = generator.verify(ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Calibration")
        outputs = generator.generate()
        self.assertEqual(len(manifest["takes"]), 16)
        self.assertFalse(manifest["containsHumanVoice"])
        self.assertEqual({x["task"] for x in manifest["takes"]}, set(generator.TASKS))
        self.assertEqual(len({x["sha256"] for x in manifest["takes"]}), 16)
        for take in manifest["takes"]:
            data = outputs[take["filename"]]
            self.assertEqual(data[:4], b"RIFF")
            self.assertEqual(data[8:16], b"WAVEfmt ")
            self.assertEqual(struct.unpack_from("<HHIIHH", data, 20), (1, 1, 16000, 32000, 2, 16))
            self.assertEqual(struct.unpack_from("<I", data, 4)[0] + 8, len(data))
            self.assertEqual(struct.unpack_from("<I", data, 40)[0], take["sampleCount"] * 2)
            self.assertEqual(take["sampleCount"], 6400)
            samples = struct.unpack("<6400h", data[44:])
            self.assertLess(max(abs(x) for x in samples), 32767)
            self.assertGreater(sum(x * x for x in samples), 0)
            if take["task"] != "sustainedVowel":
                self.assertEqual(samples[2000:2400], (0,) * 400)
        held_out = [x for x in manifest["takes"] if x["sessionID"] == manifest["evaluationSessionID"]]
        self.assertEqual(len(held_out), 4)
        self.assertTrue(all(x["task"] == "novelPassage" for x in held_out))
        self.assertTrue(any(x["instruction"] == "preferred" and x["listeningLabel"] == "usual" for x in manifest["takes"]))
        self.assertEqual({x["listeningLabel"] for x in manifest["takes"]}, {"usual", "preferred", "other", "uncertain"})

    def test_mutated_missing_extra_and_symlinked_fixtures_fail(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name)
            outputs = generator.generate()
            for filename, data in outputs.items():
                (path / filename).write_bytes(data)
            generator.verify(path)
            first = path / "take-01.wav"
            original = first.read_bytes()
            first.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
            with self.assertRaises(ValueError):
                generator.verify(path)
            first.unlink()
            with self.assertRaises(ValueError):
                generator.verify(path)
            first.write_bytes(original)
            (path / "unexpected.json").write_text("{}")
            with self.assertRaises(ValueError):
                generator.verify(path)
            (path / "unexpected.json").unlink()
            real = path / "real.md"
            real.write_bytes(original)
            first.unlink()
            first.symlink_to(real)
            with self.assertRaises(ValueError):
                generator.verify(path)


if __name__ == "__main__":
    unittest.main()
