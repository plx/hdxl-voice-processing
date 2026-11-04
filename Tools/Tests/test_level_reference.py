import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("level_reference", Path(__file__).resolve().parents[1] / "Levels/reference.py")
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class LevelReferenceTests(unittest.TestCase):
    def test_inventory_has_all_rates_precisions_and_exact_input_identities(self):
        fixture = json.loads(reference.GOLDEN.read_text())
        self.assertEqual(fixture["reference"]["revision"], reference.REVISION)
        self.assertEqual(fixture["reference"]["sourceSHA256"], reference.SOURCE_SHA256)
        self.assertEqual(fixture["generatorSHA256"], reference.sha(Path(reference.__file__).read_bytes()))
        self.assertEqual(len(fixture["cases"]), 240)
        seen = set()
        for row in fixture["cases"]:
            key = (row["sampleRate"], row["inputPrecision"], row["name"])
            self.assertNotIn(key, seen)
            seen.add(key)
            fmt = "<f" if row["inputPrecision"] == "float32" else "<d"
            self.assertEqual(reference.sha(b"".join(struct.pack(fmt, x) for x in row["input"])), row["inputSHA256"])
            self.assertEqual(len(row["input"]), 512)
            self.assertEqual(len(row["windows"]), 7)
            if row["name"] == "tiny-sine":
                self.assertGreater(row["referenceScale"], 0)
                self.assertGreater(row["windows"][0]["unweightedNormalizedMeanSquare"], 0)
        self.assertEqual({key[0] for key in seen}, set(reference.RATES))
        self.assertEqual({key[1] for key in seen}, {"float32", "float64"})

    def test_decimal_filter_has_independent_hand_computed_cascade_answer(self):
        stage = {"b": [1., 1., 0.], "a": [1., 0., 0.]}
        self.assertEqual(reference.decimal_filter([1., 2., 3.], [stage]), [1, 3, 5])
        self.assertEqual(reference.decimal_filter([1., 2., 3.], [stage, stage]), [1, 4, 8])
        tiny = reference.decimal_filter([1e-300, 0.], [stage])
        self.assertEqual(tiny[0], tiny[1])
        self.assertGreater(tiny[0] * tiny[0], 0)

    def test_tampered_external_source_is_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "loudness.py").write_text("raise AssertionError('must not execute')")
            (root / "LICENSE").write_text("unexpected")
            with self.assertRaises(reference.ReferenceError):
                reference.reference_coefficients(root)

    def test_reference_comparison_cannot_hide_tiny_signal_or_schema_errors(self):
        reference.compare({"tiny": 1e-300}, {"tiny": 1e-300})
        for actual, expected in ((0., 1e-300), (1., True), ([1], [1, 2]),
                                 ({"extra": 1}, {}), (float("nan"), 0.)):
            with self.subTest(actual=actual, expected=expected), self.assertRaises(reference.ReferenceError):
                reference.compare(actual, expected)


if __name__ == "__main__":
    unittest.main()
