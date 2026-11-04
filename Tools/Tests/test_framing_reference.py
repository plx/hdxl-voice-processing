"""Independent window anchors and malformed reference-output rejection."""
import importlib.util
import copy
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("framing_reference", ROOT / "Tools/Framing/reference.py")
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class FramingReferenceTests(unittest.TestCase):
    def test_archived_output_matches_decimal_oracle_and_wrapper_identity(self):
        fixture = json.loads(reference.OUTPUT.read_text())
        self.assertEqual(fixture["scriptSHA256"], reference.digest(reference.HERE / "gaussian.praat"))
        self.assertEqual(fixture["generatorSHA256"], reference.digest(reference.HERE / "reference.py"))
        self.assertEqual([case["sampleCount"] for case in fixture["cases"]], list(reference.COUNTS))
        for case in fixture["cases"]:
            self.assertEqual(reference.parse_output(case["rawOutput"], case["sampleCount"], case["sampleRate"]), case["values"])
            self.assertEqual(reference.mathematical_coefficients(case["sampleCount"]), case["decimalOracle"])
            for value, expected in zip(case["values"], case["decimalOracle"]):
                self.assertAlmostEqual(value, expected, delta=5e-15)
        self.assertEqual(reference.mathematical_coefficients(1), [1])
        self.assertEqual(reference.mathematical_coefficients(3)[1], 1)

    def test_wrong_dimensions_indices_and_nonfinite_values_fail(self):
        good = "gaussian2\t2\t48000\n1\t0.5\n2\t0.5\n"
        for bad in ["", good.replace("gaussian2", "hann"), good.replace("48000", "16000"),
                    good.replace("2\t0.5", "1\t0.5"), good.replace("0.5", "nan"),
                    good + "3\t0.5\n", good.replace("2\t0.5\n", "")]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                reference.parse_output(bad, 2, 48000)

    def test_regeneration_compares_numbers_with_declared_tolerance_and_exact_identity(self):
        original = json.loads(reference.OUTPUT.read_text())
        reference.verify(original, original)
        changed = copy.deepcopy(original)
        value = changed["cases"][1]["values"][0] + 1e-16
        changed["cases"][1]["values"][0] = value
        lines = changed["cases"][1]["rawOutput"].splitlines()
        lines[1] = f"1\t{value:.17e}"
        changed["cases"][1]["rawOutput"] = "\n".join(lines) + "\n"
        reference.verify(changed, original)
        changed["cases"][1]["values"][0] += 1e-8
        lines[1] = f"1\t{changed['cases'][1]['values'][0]:.17e}"
        changed["cases"][1]["rawOutput"] = "\n".join(lines) + "\n"
        with self.assertRaisesRegex(ValueError, "beyond tolerance"):
            reference.verify(changed, original)
        changed = copy.deepcopy(original)
        changed["tool"]["version"] = "other"
        with self.assertRaises(ValueError):
            reference.verify(changed, original)
