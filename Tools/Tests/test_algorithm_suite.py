import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from AlgorithmSuite import prepare, replay, trace


class AlgorithmSuiteTests(unittest.TestCase):
    def test_governed_regions_periodic_extension_and_cohort(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "bundle"
            prepare.prepare(directory)
            cases = {r["name"]: r for r in json.loads((directory / "manifest.json").read_bytes())["cases"]}
            self.assertEqual(len(cases), 15)
            self.assertEqual({r["sampleRate"] for r in cases.values()}, {16000, 44100, 48000})
            gap = cases["missing-intervals"]
            self.assertEqual([(r["start"], r["count"]) for r in gap["regions"]], [(0, 512), (768, 640), (1472, 576)])
            corpus = cases["corpus-long-stream-v1"]
            self.assertEqual(corpus["repeats"] * corpus["sampleCount"], 60 * corpus["sampleRate"])
            sustained = cases["harmonic-low-continuous-30s"]
            self.assertEqual(sustained["repeats"], 1)
            pcm = (directory / (sustained["pcmSHA256"] + ".pcm")).read_bytes()
            self.assertEqual(hashlib.sha256(pcm).hexdigest(), sustained["pcmSHA256"])
            self.assertEqual(len(pcm), sustained["sampleRate"] * 30 * 8)
            origin = (directory / (cases["harmonic-low"]["pcmSHA256"] + ".pcm")).read_bytes()
            self.assertEqual(pcm, (origin * (1 + len(pcm) // len(origin)))[:len(pcm)])
            with self.assertRaises(FileExistsError):
                prepare.prepare(directory)

    def test_frame_fingerprint_distinguishes_status_order_and_position(self):
        rows = [dict(sourceStart=0, value=0.0), dict(sourceStart=160)]
        digest = replay.lane_digest(rows)
        self.assertEqual((digest["available"], digest["unavailable"], digest["sum"]), (1, 1, 0.0))
        self.assertNotEqual(digest, replay.lane_digest(rows[::-1]))
        self.assertNotEqual(digest, replay.lane_digest([rows[0], dict(sourceStart=159)]))
        self.assertNotEqual(digest, replay.lane_digest([rows[0], dict(sourceStart=160, value=0.0)]))

    def test_trace_pairs_only_the_actual_worker_and_separates_shared_names(self):
        def row(name, kind, t, token, process="VoiceSuiteWorkloadCheck (123)"):
            return {"name": name, "category": "worker", "event-type": kind, "identifier": "1", "time": t,
                    "process": process, "message": f"session=1 epoch=0 span=1 profile={token} frame=2 samples=160"}
        rows = [row("Pitch", "Begin", 0, 38), row("Pitch", "End", 11, 38),
                row("Pitch", "Begin", 11, 44), row("Pitch", "End", 19, 44),
                row("BurgLPC", "Begin", 20, 46, process="Other (555)")]
        with mock.patch.object(trace, "signpost_records", return_value=rows):
            observed = trace.summarize(b"")
        self.assertEqual(set(observed), {"Pitch/38", "Pitch/44"})
        self.assertEqual(observed["Pitch/38"]["totalNS"], 11)
        self.assertEqual(observed["Pitch/44"]["totalNS"], 8)
        with mock.patch.object(trace, "signpost_records", return_value=rows[:1]):
            with self.assertRaisesRegex(ValueError, "Incomplete"):
                trace.summarize(b"")
