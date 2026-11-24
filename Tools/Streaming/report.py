"""Validate source, handoff, worker and subscriber records from one native replay."""

from bisect import bisect_left
from collections import Counter, defaultdict
from math import ceil


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {"count": 0}
    return {"count": len(ordered), "min": ordered[0], "max": ordered[-1],
            **{f"p{p}": ordered[ceil(p * len(ordered) / 100) - 1] for p in (50, 95, 99)}}


def summarize(t):
    ingress = t["ingress"]
    rate = t["sampleRate"]
    paced = t["load"] == "paced"
    duration = t["finalDrainNS"] - ingress["firstOfferNS"]
    if duration <= 0 or t["consumedFrames"] + t["droppedFrames"] != ingress["offeredFrames"]:
        raise ValueError("Invalid wall time or input denominator")
    if t["operation"] != "soak" and t["consumedFrames"] != sum(end - start for start, end in ingress["admittedRegions"]):
        raise ValueError("Accepted source regions differ from the consumed input")
    if t["queueHighWater"] > t["queueSlots"] or t["schedulerBytes"] <= 0:
        raise ValueError("Worker or queue storage invalid")
    if t["fast"]["highWater"] > t["fast"]["capacity"] or t["slow"]["highWater"] > 2 or t["paused"]["highWater"] != 4:
        raise ValueError("Invalid subscriber mailbox high-water")
    if t["load"] != "paced" and t["knownMissingFrames"] != t["droppedFrames"] + ingress["explicitGapFrames"]:
        raise ValueError("Controlled source gap or overflow was not delivered")
    consumed_seconds = t["consumedFrames"] / rate
    common = {k: t[k] for k in ("profile", "profileSHA256", "sampleRate", "pattern", "load", "mode", "operation",
                                "seconds", "seed", "consumedFrames", "drainedBlocks", "emittedFrames", "gapCount",
                                "resetCount", "knownMissingFrames", "unknownGaps", "droppedFrames", "overflowChunks",
                                "queueHighWater", "queueSlots", "schedulerBytes", "pcmBytes", "fast", "slow", "paused",
                                "stopReason", "requirements", "resident")}
    common.update(offeredFrames=ingress["offeredFrames"], offeredCallbacks=ingress["offered"],
                  explicitGapFrames=ingress["explicitGapFrames"], admittedRegionCount=ingress["admittedRegionCount"],
                  admittedRegions=ingress["admittedRegions"],
                  elapsedFirstOfferToLastDrainNS=duration, totalWorkerNS=t["processingNS"],
                  workerSecondsPerAdmittedSecond=t["processingNS"] / 1e9 / consumed_seconds,
                  throughputRealtimeFactor=(consumed_seconds * 1e9 / duration if t["load"] == "throughput" else None),
                  pendingFinalTileFrames=(ingress["lastAdmittedRegion"][1]-ingress["lastAdmittedRegion"][0]) % 256)
    if t["operation"] == "soak":
        if ingress["admittedRegions"] or ingress["retainedCallbacks"] or t["drains"] or t.get("science") is not None or len(t["resident"]) > 14:
            raise ValueError("Soak retained unbounded per-operation telemetry")
        total_frames = 0
        for metrics in t["soakOutcomes"].values():
            counts = {sum(statuses.values()) for statuses in metrics.values()}
            if len(counts) != 1:
                raise ValueError("Missing metric validity in soak")
            total_frames += counts.pop()
        if total_frames != t["emittedFrames"]:
            raise ValueError("Missing per-lane soak counts")
        common["laneOutcomes"] = t["soakOutcomes"]
        warm = [sample["residentBytes"] for sample in t["resident"] if sample["consumedFrames"] >= t["consumedFrames"] // 2]
        common["secondHalfResidentBytes"] = distribution(warm)
        return common
    calls = ingress["retainedCallbacks"]
    accepted = [c for c in calls if c["admitted"]]
    drains = t["drains"]
    blocks = [d for d in drains if "dequeuedNS" in d]
    if len(calls) != ingress["offered"] or len(accepted) != len(blocks) or len(blocks) != t["drainedBlocks"]:
        raise ValueError("Missing callback or worker observation")
    lower, upper = [], []
    for call, block in zip(accepted, blocks, strict=True):
        if call["sourceHostNS"] != block["sourceHostNS"] or block["frames"] != call["frames"]:
            raise ValueError("Queue timing joined to a different source block")
        begin, end, dequeued = call["enteredNS"], call["returnedNS"], block["dequeuedNS"]
        if not begin <= end or not block["startedNS"] <= dequeued <= block["finishedNS"] or dequeued < begin:
            raise ValueError("Invalid callback or dequeue clock")
        lower.append(max(0, dequeued - end))
        upper.append(dequeued - begin)
    ns = lambda count: round(count * 1e9 / rate)
    common.update(callbackNS=distribution(c["returnedNS"] - c["enteredNS"] for c in calls),
                  callbackBudgetMisses=sum(c["returnedNS"] - c["enteredNS"] > ns(c["frames"]) for c in calls),
                  enqueueToDequeueLowerNS=distribution(lower), enqueueToDequeueUpperNS=distribution(upper),
                  drainNS=distribution(d["finishedNS"] - d["startedNS"] for d in drains),
                  observedDepthAfter=distribution(d["depthAfter"] for d in drains if "depthAfter" in d))
    if paced:
        common["arrivalLatenessNS"] = distribution(c["enteredNS"] - c["sourceHostNS"] - ns(c["frames"]) for c in calls)
    finished = [d["afterPublicationNS"] for d in drains]
    records = t["science"]["records"]
    if len(records) != t["emittedFrames"] or t["science"]["equivalentNativeFrames"] != len(records):
        raise ValueError("Scientific oracle denominator differs from delivery")
    requirements = {r["lane"]: r for r in t["requirements"]}
    lanes = defaultdict(list)
    for record in records:
        drain = bisect_left(finished, record["publishedNS"])
        if drain == len(drains) or not drains[drain]["finishedNS"] <= record["publishedNS"] <= record["observedNS"]:
            raise ValueError("Frame publication outside its worker handoff")
        lanes[record["lane"]].append((record, drains[drain]["finishedNS"]))
    if set(lanes) != set(requirements):
        raise ValueError("Missing enabled lane")
    common["scienceSHA256"] = t["science"]["sha256"]
    common["lanes"] = {}
    for lane, samples in lanes.items():
        items = [record for record, _ in samples]
        statuses = defaultdict(Counter)
        for r in items:
            for metric, status in r["outcomes"].items():
                statuses[metric][status] += 1
        recovery = []
        for start, end in ingress["admittedRegions"]:
            group = [r for r in items if r["regionStart"] == start]
            first_valid = {}
            for metric in statuses:
                good = next((r for r in group if r["outcomes"][metric] == "available"), None)
                first_valid[metric] = None if good is None else {
                    "sourceFramesUntilFirstValidWindowEnd": good["windowEnd"] - start,
                    "observedAfterFirstCallbackNS": good["observedNS"] - next(
                        c["enteredNS"] for c in accepted if c["sourceStart"] == start)}
            recovery.append(dict(start=start, end=end, emitted=len(group), firstValid=first_valid))
        result = dict(frames=len(items), outcomes=dict(statuses), recovery=recovery,
                      workerEndToPublicationNS=distribution(r["publishedNS"] - worker for r, worker in samples),
                      subscriberLagNS=distribution(r["observedNS"] - r["publishedNS"] for r in items),
                      effectiveDelaySeconds=distribution(r["effectiveDelaySeconds"] for r in items))
        if paced:
            result.update(acousticEndToPublicationNS=distribution(r["publishedNS"] - r["acousticEndNS"] for r in items),
                          acousticEndToObservationNS=distribution(r["observedNS"] - r["acousticEndNS"] for r in items),
                          deadlineMisses=sum(r["observedNS"] > r["dependencyEndNS"] +
                                             round(requirements[lane]["hopSeconds"] * 1e9) for r in items))
        windows = t["science"]["windows"][lane]
        if windows["noCapacityLossFrames"] - windows["omittedWindowPositions"] + windows["addedWindowPositionsAfterReset"] != len(items):
            raise ValueError("Missing or double-counted scheduled window positions")
        common["lanes"][lane] = dict(result, windows=windows)
    return common
