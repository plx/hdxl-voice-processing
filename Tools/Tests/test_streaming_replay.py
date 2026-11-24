import copy
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

    def test_single_frame_uses_source_end_and_bounds_the_actual_enqueue(self):
        call = dict(sourceStart=0, frames=64, sourceHostNS=100, enteredNS=1_340_100,
                    returnedNS=1_340_160, admitted=True)
        drain = dict(sourceHostNS=100, frames=64, startedNS=1_340_110, dequeuedNS=1_340_125,
                     finishedNS=1_340_200, afterPublicationNS=1_340_230, depthAfter=0)
        frame = dict(lane="cpps", regionStart=0, windowEnd=64, acousticEndNS=1_333_433,
                     dependencyEndNS=1_333_433, effectiveDelaySeconds=.01, publishedNS=1_340_210,
                     observedNS=1_340_240, outcomes={"cpps": "insufficientData"})
        windows = dict(noCapacityLossFrames=1, omittedWindowPositions=0,
                       addedWindowPositionsAfterReset=0, withheldAtExplicitStop=1)
        trial = dict(profile="cpps", profileSHA256="stub", sampleRate=48000, pattern=[64], load="paced",
                     mode="disabled", operation="single", seconds=1, seed=7, consumedFrames=64, drainedBlocks=1,
                     emittedFrames=1, gapCount=0, resetCount=0, knownMissingFrames=0, unknownGaps=0, droppedFrames=0,
                     overflowChunks=0, queueHighWater=1, queueSlots=32, schedulerBytes=512, pcmBytes=1024,
                     fast={"highWater": 1, "capacity": 256}, slow={"highWater": 1}, paused={"highWater": 4},
                     stopReason="explicitStop", requirements=[{"lane": "cpps", "hopSeconds": .01}], resident=[],
                     processingNS=90, finalDrainNS=1_340_230, drains=[drain], ingress=dict(
                         offeredFrames=64, offered=1, firstOfferNS=1_340_100, explicitGapFrames=0,
                         retainedCallbacks=[call], admittedRegionCount=1, lastAdmittedRegion=[0,64],
                         admittedRegions=[[0,64]]), science=dict(records=[frame], equivalentNativeFrames=1,
                         sha256="stub", windows={"cpps": windows}))
        result = report.summarize(trial)
        self.assertEqual((result["enqueueToDequeueLowerNS"]["p50"], result["enqueueToDequeueUpperNS"]["p50"]), (0,25))
        self.assertEqual(result["lanes"]["cpps"]["acousticEndToObservationNS"]["p99"], 6807)
        self.assertEqual(result["lanes"]["cpps"]["outcomes"], {"cpps": {"insufficientData": 1}})
        for key, value in (("sourceHostNS", 101), ("frames", 32), ("dequeuedNS", 1_340_099)):
            broken = copy.deepcopy(trial)
            broken["drains"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                report.summarize(broken)
        gap = copy.deepcopy(trial)
        gap["ingress"]["lastAdmittedRegion"] = [20,84]
        gap["ingress"]["explicitGapFrames"] = 20
        with self.assertRaisesRegex(ValueError, "before the final admitted"):
            report.summarize(gap)
        soak = copy.deepcopy(trial) | {"operation": "soak", "drains": [], "science": None}
        soak["ingress"] = dict(soak["ingress"], retainedCallbacks=[], admittedRegions=[])
        for states in ({}, {"cpps": {"cpps": {"available": 1}}}):
            with self.subTest(soak=states), self.assertRaisesRegex(ValueError, "configured"):
                report.summarize(dict(soak, soakOutcomes=states))
        windows["omittedWindowPositions"] = 1
        with self.assertRaisesRegex(ValueError, "window positions"):
            report.summarize(trial)

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

        getter = 'movq "L_selector(sampleRate)"(%rip), %rsi\nmovq %rax, %rdi\ncallq _objc_msgSend'
        identified = bodies | {name: bodies[name] + "\n" + getter + "\ncallq *_objc_release@GOTPCREL(%rip)"}
        self.assertIn("_objc_msgSend$sampleRate", callback_audit.inspect_tap(identified, {"_offer"})["namedSDKBoundaries"])
        for changed in (getter.replace("sampleRate", "waitUntilDone"), getter.replace("%rsi", "%rax"),
                        "callq *_pthread_mutex_lock@GOTPCREL(%rip)"):
            with self.assertRaises(ValueError):
                callback_audit.inspect_tap(bodies | {closure: bodies[closure] + "\n" + changed}, {"_offer"})

    def test_trace_counts_detect_pairs_missing_at_both_ends(self):
        stages = {"FFT/33": [15, 16], "CPPSSmoothing/37": [19]}
        reference = {"fft/33": 2, "cppsSmoothing/37": 1}
        self.assertEqual(trace.reconcile_kernels(stages, reference)["fft/33"], 2)
        with self.assertRaisesRegex(trace.IncompleteRecording, "invocation counts"):
            trace.reconcile_kernels(dict(stages, **{"FFT/33": [15]}), reference)

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
