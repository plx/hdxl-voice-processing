import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("calibration_evidence", ROOT / "Tools/Calibration/evidence.py")
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class CalibrationEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.manifest = evidence.generator.verify(evidence.FIXTURES)

    def test_independent_assignments_keep_complete_later_session_held_out(self):
        assignments = [evidence.expected_assignment(take, self.manifest) for take in self.manifest["takes"]]
        for role, expected in (("fitting", [2, 4, 7, 8, 9, 10, 11]),
                               ("recordingEvaluation", [1, 3, 5, 6, 12]),
                               ("sessionEvaluation", [13, 14, 15, 16])):
            self.assertEqual([a["takeID"] for a in assignments if a["role"] == role],
                             [evidence.generator.identifier(i) for i in expected])
        self.assertEqual(len({a["recordingGroup"]["sha256"] for a in assignments}), 16)

    def test_pass_validation_rejects_unverified_bytes_unbounded_chunks_and_fake_cache_hits(self):
        record = {"seconds": 1, "analyzed": 16, "reused": 0, "decodedSamples": 102400,
                  "snapshotBytes": 205504, "maximumSnapshotChunkBytes": 12844,
                  "maximumDecodedChunkSamples": 257, "maximumPreparedBufferBytes": 286070,
                  "maximumReservedScalarBytes": 1200000, "maximumRetainedScalarCount": 174,
                  "peakResidentBytes": 40 * 1024 * 1024}
        evidence.validate_pass(record, self.manifest, False)
        for key, bad in (("seconds", float("nan")), ("seconds", True), ("analyzed", 15),
                         ("snapshotBytes", 0), ("decodedSamples", 0), ("maximumDecodedChunkSamples", 65537),
                         ("maximumReservedScalarBytes", 1200001), ("peakResidentBytes", 0)):
            changed = dict(record, **{key: bad})
            with self.subTest(key=key), self.assertRaises(ValueError):
                evidence.validate_pass(changed, self.manifest, False)
        cached = dict(record, analyzed=0, reused=16, decodedSamples=0, maximumDecodedChunkSamples=0,
                      maximumPreparedBufferBytes=0, maximumReservedScalarBytes=0, maximumRetainedScalarCount=0)
        evidence.validate_pass(cached, self.manifest, True)
        for key in ("decodedSamples", "maximumPreparedBufferBytes", "maximumReservedScalarBytes", "maximumRetainedScalarCount"):
            with self.subTest(cache=key), self.assertRaises(ValueError):
                evidence.validate_pass(dict(cached, **{key: 1}), self.manifest, True)

    def test_summary_rejects_imputation_unknown_reasons_and_nonfinite_quantiles(self):
        value = {"metric": "rms", "availableCount": 2, "unavailable": {"silence": 1}, "warnings": {},
                 "minimum": 1, "lowerQuartile": 1, "median": 1, "upperQuartile": 2, "maximum": 2}
        evidence.validate_summary(value)
        for key, bad in (("availableCount", True), ("unavailable", {"invented": 1}),
                         ("warnings", {"clipping": 3}), ("median", float("inf")),
                         ("maximum", 0), ("availableCount", 0)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                evidence.validate_summary(dict(value, **{key: bad}))

    def test_distribution_requires_real_complete_samples(self):
        self.assertEqual(evidence.distribution(list(range(1, 11)))["median"], 5)
        for bad in ([1] * 9, [1] * 9 + [float("nan")], [1] * 9 + [0], [True] * 10):
            with self.assertRaises(ValueError):
                evidence.distribution(bad)


if __name__ == "__main__":
    unittest.main()
