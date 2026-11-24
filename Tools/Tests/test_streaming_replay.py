from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Streaming import benchmark, callback_audit, report, trace


class StreamingReplayTests(unittest.TestCase):
    def test_nearest_rank_uses_individual_observations_including_outliers(self):
        samples = (value for value in [99, 1, 2, 3, 4])
        self.assertEqual(report.distribution(samples), dict(count=5, min=1, max=99, p50=3, p95=99, p99=99))
        self.assertEqual(report.distribution([]), dict(count=0))

    def test_mode_comparison_requires_every_pair_and_identical_validity(self):
        runs = [dict(repeat=rep, trials=[dict(profile=p, mode=m, scienceSHA256=p,
                    elapsedFirstOfferToLastDrainNS=30, totalWorkerNS=10)])
                for p in benchmark.PROFILES for rep in range(6) for m in benchmark.MODES]
        self.assertEqual(benchmark.check_overhead(runs)["full"]["sampled"]["medianWallDeltaNS"], 0)
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            benchmark.check_overhead(runs[1:])
        runs[-1]["trials"][0]["scienceSHA256"] = "different"
        with self.assertRaisesRegex(ValueError, "changed"):
            benchmark.check_overhead(runs)

    def test_matrix_covers_each_arrival_and_chunk_geometry_at_both_rates(self):
        for p in benchmark.PROFILES:
            cases = list(benchmark.cases(p))
            self.assertEqual(len(cases), 24)
            self.assertEqual({(rate, pattern, load) for _, rate, pattern, load, *_ in cases},
                             {(r, size, load) for r in (44100, 48000)
                              for size in ("64", "128", "256", "512", "1024", "mixed")
                              for load in ("throughput", "paced")})

    def test_native_callback_audit_rejects_indirect_calls_and_blocking_edges(self):
        borrow = next(sym for sym in callback_audit.SDK if "withUnsafe" in sym)
        name = "_PreparedCaptureTapC6acceptCtF"
        closure = "_PreparedCaptureTapC6acceptBufferListVGXEfU_"
        bodies = {name: f"bl {borrow}\nret", closure: "b.eq Lok\nbl _offer\nret"}
        info = callback_audit.inspect_tap(bodies, {"_offer"})
        self.assertEqual(info["handoffTargets"], ["_offer"])
        for op in ("bl _swift_allocObject", "b.eq _semaphore_wait", "blraa x8, x9", "callq *_table",
                   "bl _dispatch_sync", "bl _swift_task_create"):
            with self.subTest(op=op), self.assertRaisesRegex(ValueError, "Unaudited"):
                callback_audit.inspect_tap(bodies | {closure: bodies[closure] + "\n" + op}, {"_offer"})

    def test_trace_only_trusts_requested_process_and_approved_numeric_payloads(self):
        doc = {"processID": 42, "trials": [dict(drainedBlocks=2, gapCount=1, fast={"accepted": 2, "delivered": 2},
               slow={"delivered": 1}, paused={"delivered": 1}, science={"records": []})]}
        row = dict(process="StreamingReplayProbe (99)", name="CPP", category="worker",
                   identifier="1", time=2, message="unexpected free text")
        row["event-type"] = "Begin"
        with mock.patch.object(trace, "signpost_records", return_value=[row]):
            with self.assertRaises(trace.IncompleteRecording):
                trace.inspect(b"", doc)
            row["process"] = "StreamingReplayProbe (42)"
            with self.assertRaisesRegex(ValueError, "metadata"):
                trace.inspect(b"", doc)
            row.update(message="")
            row["event-type"] = "End"
            with self.assertRaisesRegex(trace.IncompleteRecording, "Unmatched"):
                trace.inspect(b"", doc)
