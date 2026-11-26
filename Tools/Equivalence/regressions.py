"""Index executed reference and declared-difference tests from the shared correctness lane."""
from collections import defaultdict
from hashlib import sha256
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
import ci

CASES = {
    "checked PCM, channels and integer clocks": (
        "schedulingPartitionsPreserveAllAlgorithmOutputsAndDirectValues", "schedulingRejectsInvalidWholeChunksBeforeConsumption",
        "schedulingSourceMappingPreservesLargeOriginalPositions", "schedulingPlanarFloatMatchesInterleavedChannelSelection"),
    "framing, conditioning and transforms": (
        "framingGapResetNeverReusesPreviousSamples", "previewDoubleMatchesIndependentConvolutionAndPartitions",
        "fourierFloatMatchesIndependentScalarForwardAndInverse", "doubleConditioningMatchesIndependentReference",
        "floatConditioningMatchesIndependentReference", "cepstrumMatchesIndependentCosineSumTransformAtEveryStage"),
    "CPPS grid, edge and selection": (
        "schedulingProfilesDoNotSubstitutePreviewForWholeInterval", "cppsWholePCMExternalReferences",
        "cppsPreviewChunkAlignmentTailAndGap", "cppsWholePCMChunksAndShortIntervals",
        "cppsRegionWeightingCoverageAndPopulationIdentity", "cppsRollingLatestUnavailableSuppressesPriorNumber",
        "cppsRegionMissingExcludedAndEmptyNeverBecomeZero"),
    "level precision and weighted history": (
        "levelFloatMatchesIndependentFilterAndWindowVectors", "levelDoubleMatchesIndependentFilterAndWindowVectors",
        "schedulingWeightedExportsRetainFullFilterHistoryCoverage"),
    "periodicity and global amplitude reference": (
        "hnrQuietPrefixHasDistinctGlobalAndCausalAmplitudeReferences", "hnrScheduleMatchesDirectKernelsAcrossMethodsPrecisionModesAndChunks",
        "hnrWholeIntervalChunkingAggregatesAndResetPreserveCoverage", "swipePrimeAllIndependentNativeStageReferences",
        "swipePrimeRejectsUnsupportedGeometryAndUnknownConventions", "yinNonadjacentGlobalTiesKeepTheSmallerLag"),
    "mask and spectrum support": (
        "maskSeparatedShortRegionsNeverMakeSyntheticCPPFrameAndEmptySelectionHasNoRows",
        "schedulingSelectedRegionsNeverBridgeAndKeepUnavailablePitchEvidence", "ltsfInsufficientInputAndCancelledBorrowNeverExposeStaleFeatures",
        "liveFloatRowsMatchReplayAndSettingsHaveDistinctIdentities", "bandwidthWindowLeakagePrecisionAndUnsupportedBins"),
    "period, cycle and amplitude coverage": (
        "pulseStreamingRejectsGapsOverlapsWrongEpochAndInvalidInputAtomically",
        "pulseTrackerUnvoicedAndExcludedRegionsRemainVisibleWithoutStitching", "pulseReferenceCatalogComparesEveryRawLandmarkAndAvailableAmplitude",
        "jitterCoverageAndUnavailableReasonsRemainDistinctFromZero", "jitterRollingDoesNotAccumulateSubtractionDriftOrStitchIndependentBlocks",
        "shimmerRollingInvalidCallsAreAtomicAndExpiredHistoryIsStale"),
    "Burg and harmonic dependencies": (
        "silenceConstantShortMalformedAndDifferentSettingsHaveSeparateOutcomes",
        "correctionReportsOnlyConsumedSupportAndPropagatesUpstreamBurgStatus", "rawOnlyNarrowbandPropagatesUnavailabilityAndOriginalClock",
        "publicYINAndBurgSupplyAnActualCorrectedObservation"),
}


def index(documents):
    cases = defaultdict(list)
    for xml in documents:
        for case in ET.fromstring(xml).iter("testcase"):
            module = case.get("classname", "")
            if module.split(".")[0] == "HDXLVoiceProcessingTests":
                cases[case.get("name")].append(case)
    result = {}
    for group, names in CASES.items():
        result[group] = []
        for name in names:
            rows = cases[name + "()"]
            if len(rows) != 1 or any(rows[0].find(tag) is not None for tag in ("failure", "error", "skipped")):
                raise ValueError(f"Missing, ambiguous or unsuccessful conformance regression: {name}")
            result[group].append(rows[0].get("classname") + "." + name)
    return result


def main(folder):
    env = json.loads((folder / "environment.json").read_bytes())
    ci.validate_environment(env, json.loads((ROOT / "Configuration/build.json").read_bytes()))
    if env["commit"] != ci.capture("git", "rev-parse", "HEAD") or env["workingTreeDirty"] or env["lane"] != "debug":
        raise ValueError("Expected current clean debug correctness evidence")
    reports = ci.test_reports(folder)
    lane = json.loads((folder / "result.json").read_bytes())
    if lane["status"] != "passed" or lane["testReports"] != reports:
        raise ValueError("Incomplete correctness lane")
    documents = {r["file"]: (folder / r["file"]).read_bytes() for r in reports}
    report = dict(commit=env["commit"], xcode=env["xcode"], architecture=env["architecture"],
                  reportSHA256={name: sha256(xml).hexdigest() for name, xml in documents.items()}, cases=index(documents.values()), status="passed")
    (folder / "algorithm-contracts.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
