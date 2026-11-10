"""Reject stale maximum support and corrupt framing benchmark geometry/identities."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Framing.workloads import expected_matrix, identity, validate_matrix


class FramingWorkloadTests(unittest.TestCase):
    def test_closed_matrix_and_maximum_payload(self):
        rows = expected_matrix()
        self.assertEqual(len(validate_matrix(rows)), 88)
        maximum = [row for row in rows if "requestedWindowSeconds" not in row]
        self.assertEqual(len(maximum), 6)
        for row in maximum:
            self.assertEqual(row["configuration"]["window"]["sampleCount"], 131072)
            self.assertEqual(row["expectedFrameCount"], 11)
            self.assertEqual(row["preparedBufferBytes"],
                             1572864 if row["configuration"]["window"]["precision"] == "float32" else 3145728)
        # The 220.5-sample hop rounds away from zero, rather than Python's nearest-even.
        half = next(row for row in rows if row["name"].startswith("float32.44100Hz.N882.H221."))
        self.assertEqual(half["configuration"]["hopLength"], 221)

    def test_rejects_old_maximum_even_with_consistent_derived_metadata(self):
        rows = expected_matrix()
        for row in rows:
            if "requestedWindowSeconds" in row:
                continue
            config = row["configuration"]
            window = config["window"]
            window["sampleCount"] = 65536
            row["name"] = row["name"].replace("N131072", "N65536")
            row["inputSampleCount"] = 65536 + 10 * config["hopLength"]
            row["inputDurationSeconds"] = row["inputSampleCount"] / window["sampleRate"]
            row["preparedBufferBytes"] //= 2
            row["framingIdentity"] = identity(config, "sample-grid-framing")
        with self.assertRaises(ValueError):
            validate_matrix(rows)

    def test_rejects_missing_duplicate_and_modified_rows(self):
        good = expected_matrix()
        corruptions = [good[:-1], good + [good[0]], good[:-1] + [good[0]], [None] + good[1:]]
        for field, value in (("inputSampleCount", 1), ("inputDurationSeconds", float("nan")),
                             ("expectedFrameCount", True), ("smallChunkSamples", 18),
                             ("primitiveOperationsPerIteration", 1), ("preparedBufferBytes", 0),
                             ("requestedWindowSeconds", 0.021), ("requestedHopSeconds", 0.003)):
            rows = copy.deepcopy(good); rows[0][field] = value; corruptions.append(rows)
        for field, value in (("hopLength", 31), ("firstFrameOffsetSamples", 1),
                             ("partialWindowPolicy", "emitUnavailable")):
            rows = copy.deepcopy(good); rows[0]["configuration"][field] = value; corruptions.append(rows)
        rows = copy.deepcopy(good); rows[0]["framingIdentity"]["sha256"] = "0" * 64; corruptions.append(rows)
        rows = copy.deepcopy(good); rows[0]["extra"] = 1; corruptions.append(rows)
        for index, rows in enumerate(corruptions):
            with self.subTest(index=index), self.assertRaises(ValueError):
                validate_matrix(rows)


if __name__ == "__main__":
    unittest.main()
