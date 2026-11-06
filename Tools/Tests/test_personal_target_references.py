import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


profile = module("target_profile_reference", "Tools/PersonalTargets/profile_reference.py")
fitting = module("target_fitting_reference", "Tools/PersonalTargets/fitting_reference.py")
FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets"


class PersonalTargetReferenceTests(unittest.TestCase):
    def test_exact_profile_references_have_independent_sources_and_finite_boundaries(self):
        result = profile.verify(FIXTURES / "Profile")
        self.assertEqual(len(result["cases"]), 14)
        self.assertEqual(sum(x["boundary"] for x in result["cases"]), 10)
        self.assertEqual(sum(x["cppsReference"] is not None for x in result["cases"]), 8)
        self.assertEqual(result["cases"][0]["expected"]["cpps"], [])
        self.assertEqual(result["cases"][1]["expected"]["cpps"], [None])
        self.assertEqual(result["yinProfile"]["differenceBackend"], "fft")

    def test_reference_values_counts_metadata_and_raw_outputs_cannot_drift(self):
        with tempfile.TemporaryDirectory() as name:
            destination = Path(name) / "Profile"
            shutil.copytree(FIXTURES / "Profile", destination)
            path = destination / "profile-reference.json"
            original = path.read_bytes()
            manifest = json.loads(original)
            for change in ["budget", "profile", "missing", "value", "unavailable"]:
                value = copy.deepcopy(manifest)
                if change == "budget":
                    value["comparisonBudgetsAbsolute"]["cpps"] *= 100
                elif change == "profile":
                    value["yinProfile"]["hopLength"] += 1
                elif change == "missing":
                    value["cases"].pop()
                elif change == "value":
                    value["cases"][10]["expected"]["cpps"][0] += .01
                else:
                    value["cases"][1]["expected"]["cpps"] = [0]
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError, msg=change):
                    profile.verify(destination)
            path.write_bytes(original)
            raw = destination / manifest["cases"][10]["cppsReference"]["rawPath"]
            raw.write_text(raw.read_text().replace("begin\tcpps-v1", "begin\twrong", 1))
            with self.assertRaises(ValueError):
                profile.verify(destination)

    def test_fitting_oracle_has_known_geometry_and_numerically_inverted_score_bounds(self):
        expected = fitting.canonical(fitting.generate()) + b"\n"
        self.assertEqual((FIXTURES / "fitting-reference.json").read_bytes(), expected)
        cases = fitting.generate()["cases"]
        self.assertEqual(len(cases), 9)
        first = cases[0]
        self.assertEqual(first["preferredInterval"], {"lower": 10, "upper": 10})
        self.assertEqual(first["reports"]["sessionEvaluation"]["counts"]["totalGroups"], 32)
        self.assertEqual(first["reports"]["sessionEvaluation"]["counts"]["balancedAccuracy"], 1)
        self.assertFalse(next(x for x in cases if x["name"] == "heldout-outside")["activated"])
        self.assertAlmostEqual(fitting.wilson(4, 4)["lower"], .5101091635454027, places=14)
        self.assertEqual(fitting.wilson(0, 4)["lower"], 0)
        self.assertEqual(fitting.wilson(4, 4)["upper"], 1)
        self.assertIsNone(fitting.wilson(0, 0))


if __name__ == "__main__":
    unittest.main()
