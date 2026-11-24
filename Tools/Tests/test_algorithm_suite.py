import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from AlgorithmSuite import benchmark, compare, prepare, replay, trace
from Performance import records


class AlgorithmSuiteTests(unittest.TestCase):
    def test_comparison_binds_each_mode_and_requires_clean_sources(self):
        def write(path, value):
            path.write_text(json.dumps(value))

        def make(directory, mode, dirty=False):
            directory.mkdir(exist_ok=True)
            write(directory / "resolution.json", {})
            write(directory / "environment.json", dict(commit="abc", workingTreeDirty=dirty, python="3", sdks={},
                  architecture="arm64", hardwareModel="host", hostOSBuild="build", swift="swift", xcode="xcode",
                  toolchainPolicy="development", operations={"Run": "whole fixture"}, measurementMode=mode,
                  packageResolvedSHA256=records.sha(directory / "resolution.json"),
                  allocatorBackend="disabled" if mode == "timing" else "malloc-interposer"))
            rows = [dict(name=op + ".input", fixture=dict(name="input")) for op in benchmark.OPERATIONS]
            rows.append(dict(name="phase.firstOutput.input", fixture=dict(name="input"),
                             measurementBoundary="Time through the first usable sample"))
            quantities = {"wallClock": {"p50": 5}, "cpuTotal" if mode == "timing" else "mallocCountTotal": {"p50": 1}}
            values = {"VoiceSuite.Run." + row["name"]: quantities for row in rows}
            if mode == "allocation":
                values["Capability.VoiceSuiteAllocationARC"] = quantities
            write(directory / "workloads.json", rows)
            write(directory / "distributions.json", values)
            write(directory / "p99.json", {})
            digest = records.write_index(directory, mode)
            write(directory / "result.json", dict(status="passed", mode=mode, workloadManifestSHA256=digest))
            manifest = json.loads((directory / "workload-manifest.json").read_bytes())
            self.assertEqual(next(op["boundary"] for op in manifest["operations"] if ".phase." in op["id"]),
                             rows[-1]["measurementBoundary"])

        with tempfile.TemporaryDirectory() as temp:
            timing, allocation = (Path(temp) / mode for mode in ("timing", "allocation"))
            make(timing, "timing")
            make(allocation, "allocation")
            self.assertEqual(len(compare.compare(timing, allocation)["comparisons"]), 4)
            with (allocation / "distributions.json").open("a") as stream:
                stream.write(" ")
            with self.assertRaisesRegex(ValueError, "distributions.json"):
                compare.compare(timing, allocation)
            make(allocation, "allocation", dirty=True)
            make(timing, "timing", dirty=True)
            with self.assertRaisesRegex(ValueError, "clean"):
                compare.compare(timing, allocation)

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
        rows = [dict(sourceStart=0, value=0.0, status="voiced"),
                dict(sourceStart=160, status="unavailable", reason="insufficientData")]
        digest = replay.lane_digest(rows)
        self.assertEqual((digest["available"], digest["unavailable"], digest["sum"]), (1, 1, 0.0))
        self.assertNotEqual(digest, replay.lane_digest(rows[::-1]))
        for index, changes in ((1, dict(sourceStart=159)), (1, dict(value=0.0)), (1, dict(reason="excluded")),
                               (0, dict(status="uncertain"))):
            changed = rows.copy()
            changed[index] = dict(rows[index], **changes)
            self.assertNotEqual(digest["fingerprint"], replay.lane_digest(changed)["fingerprint"])

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
