import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools"))
from Capture import acceptance, device_trial


class AcceptanceTests(unittest.TestCase):
    boot = "11111111-2222-3333-4444-555555555555"
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.commit = "a" * 40

    def save(self, name, obj):
        path = self.folder / name
        path.write_text(json.dumps(obj))
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def software(self):
        config = json.loads((ROOT / "Configuration/build.json").read_bytes())
        self.save("environment.json", {
            "commit": self.commit, "workingTreeDirty": False, "lane": "debug", "configuration": "debug",
            "xcode": f"Xcode {config['xcodeVersion']}\nBuild version {config['xcodeBuild']}",
            "swift": "swiftlang-" + config["swiftCompilerVersion"], "hostOS": "27.0",
            "sdks": dict(zip(("macosx", "iphoneos", "iphonesimulator"),
                             [config["sdkVersions"][k] for k in ("macOS", "iOS", "iOSSimulator")])),
            "python": config["pythonVersion"],
        })
        root = ET.Element("testsuite")
        for tests in acceptance.CASES.values():
            for name in tests:
                ET.SubElement(root, "testcase", classname=acceptance.MODULE, name=name + "()")
        ET.ElementTree(root).write(self.folder / "tests.xml")
        self.save("result.json", {"lane": "debug", "status": "passed", "commands": [{"exitCode": 0}],
                                  "testReports": acceptance.ci.test_reports(self.folder)})
        return root

    def physical(self, scenario="sustained-foreground"):
        row = device_trial.prepare("iPhone", "built-in", scenario)
        row.update(execution="physical", deferredReason=None)
        row["run"] = dict(recordedAtUTC="2026-01-01T00:00:00Z", commit=self.commit, deviceModel="fixture",
                          architecture="arm64", osVersion="27.0", osBuild="fixture", xcodeBuild="fixture",
                          configuration="release", operation="capture-only", profileID="capture-only",
                          profileVersion="1", diagnostics="disabled", acquisitionScheduleID="fixture-120",
                          durationSeconds=120, powerSource="battery", lowPowerMode=False, profiler="fixture",
                          conditions="synthetic validator test")
        row["observations"] = dict.fromkeys(row["observations"], True)
        row["evidence"] = [{"kind": "operator-notes", "file": "notes.json", "sha256": self.save("notes.json", {})}]
        if scenario not in device_trial.NO_CAPTURE_CASES:
            row["epochs"] = [dict(epoch="e1", sampleRate=48000, channels=1, encoding="float32", layout="planar",
                                  queueSlots=16, maximumFramesPerChunk=4096, acceptedChunks=3, drainedChunks=3,
                                  consumedFrames=3072, droppedFrames=0, knownGapFrames=0, unknownGaps=0,
                                  invalidChunks=0, producerContractViolated=False, queueHighWater=2)]
        if scenario == "sustained-foreground":
            row["epochs"][0].update(acceptedChunks=6000, drainedChunks=6000, consumedFrames=5_760_000,
                                    durationNS=120_000_000_000)
            row["resourceSamples"] = [dict(epoch="e1", elapsedSeconds=t, processCPUSeconds=t/4,
                                           residentBytes=1024+t, acceptedChunks=t*50, queueDepthSlots=1, thermalState="unavailable")
                                      for t in (0, 60, 120)]
            row["latencies"]["callbackDurationNS"] = [1, 2, 3, 80]
        return row

    def test_named_cases_must_exist_and_pass_in_the_expected_module_and_revision(self):
        root = self.software()
        report = acceptance.software_report(self.folder, self.commit)
        self.assertEqual(set(report["scenarios"]), set(acceptance.CASES))
        self.assertEqual(report["physicalEvidence"], "pending physical validation")
        with self.assertRaises(ValueError):
            acceptance.software_report(self.folder, "b" * 40)
        path = self.folder / "tests.xml"
        case = root[0]
        ET.SubElement(case, "skipped")
        ET.ElementTree(root).write(path)
        with self.assertRaises(ValueError):
            acceptance.software_report(self.folder, self.commit)
        case.remove(case[0])
        case.set("classname", "unrelated")
        ET.ElementTree(root).write(path)
        with self.assertRaises(ValueError):
            acceptance.software_report(self.folder, self.commit)

    def test_pending_forms_cover_both_baseline_hosts_without_asserting_execution(self):
        for device in device_trial.PLATFORMS:
            for scenario in device_trial.CASES:
                if device == "Mac" and scenario in device_trial.IOS_CASES:
                    with self.assertRaises(ValueError):
                        device_trial.prepare(device, "built-in", scenario)
                    continue
                doc = device_trial.prepare(device, "built-in", scenario)
                result = device_trial.evaluate(doc, self.folder)
                self.assertEqual(result["functionalStatus"], "deferred")
                self.assertEqual(result["coverage"], "optional" if device == "iPad" else "baseline")

    def test_sustained_observations_preserve_units_and_distinguish_missing_evidence(self):
        row = self.physical()
        report = device_trial.evaluate(row, self.folder)
        self.assertEqual(report["functionalStatus"], "passed")
        self.assertEqual(report["measurements"]["processCPUSecondsPerWallSecond"]["p99"], 0.25)
        self.assertEqual(report["measurements"]["callbackDurationNS"]["p99"], 80)
        self.assertNotIn("energy", report["measurements"])
        for field, value in (("resourceSamples", []), ("evidence", [])):
            with self.subTest(field=field):
                self.assertEqual(device_trial.evaluate(dict(row, **{field: value}), self.folder)["functionalStatus"], "deferred")
        incomplete = copy.deepcopy(row)
        del incomplete["resourceSamples"][1]["queueDepthSlots"]
        self.assertIn("sustained queueDepthSlots observations", device_trial.evaluate(incomplete, self.folder)["missing"])
        stalled = copy.deepcopy(row)
        for sample in stalled["resourceSamples"]:
            sample["acceptedChunks"] = 1
        self.assertEqual(device_trial.evaluate(stalled, self.folder)["functionalStatus"], "failed")
        row["run"]["operation"] = "live-analysis"
        self.assertIn("acousticEndToObservationNS", device_trial.evaluate(row, self.folder)["missing"])

    def test_loss_capacity_and_early_failure_are_visible(self):
        row = self.physical()
        for changes in ({"droppedFrames": 10}, {"queueHighWater": 17}, {"acceptedChunks": 4}, {"unknownGaps": 1}):
            with self.subTest(changes=changes):
                bad = copy.deepcopy(row)
                bad["epochs"][0].update(changes)
                self.assertEqual(device_trial.evaluate(bad, self.folder)["functionalStatus"], "failed")
        row.update(epochs=[], resourceSamples=[], failures=["capture start failed"])
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "failed")
        row = self.physical("permission-denied")
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "passed")

    def test_restart_needs_two_distinct_epochs_and_matching_native_evidence(self):
        row = self.physical("stop-restart")
        row.update(deviceClass="Mac", platform="macOS")
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "deferred")
        first = row["epochs"].pop()
        first.update(startedUptimeNS=1, stoppedUptimeNS=101, durationNS=100, inputChanged=False, resourceSamples=[])
        second = dict(first, epoch="e2", startedUptimeNS=102, stoppedUptimeNS=202)
        receipt = dict(schemaVersion=1, bootSession=self.boot, operation="capture-only", status="completed", requestedRuns=2,
                       revision=self.commit, sourceState="clean", runs=[first, second])
        item = dict(kind="mac-capture-check", file="native.json", sha256=self.save("native.json", receipt))
        row["evidence"].append(item)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "passed")
        receipt.update(requestedRuns=1, runs=[first])
        item["sha256"] = self.save("native.json", receipt)
        extra = dict(kind="mac-capture-check", file="second.json", sha256=self.save("second.json", dict(receipt, runs=[second])))
        row["evidence"].append(extra)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "deferred")
        row["evidence"].pop()
        receipt.update(requestedRuns=2, runs=[first, second])
        item["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            device_trial.evaluate(row, self.folder)
        receipt["runs"][1]["epoch"] = "e1"
        item["sha256"] = self.save("native.json", receipt)
        with self.assertRaises(ValueError):
            device_trial.evaluate(row, self.folder)

    def test_sustained_mac_import_uses_native_duration_samples_and_terminal_outcome(self):
        row = self.physical()
        row.update(deviceClass="Mac", platform="macOS")
        epoch = row["epochs"].pop()
        epoch.update(resourceSamples=row.pop("resourceSamples"), durationNS=120_000_000_000, inputChanged=False,
                     startedUptimeNS=10, stoppedUptimeNS=120_000_000_010)
        for sample in epoch["resourceSamples"]:
            sample["uptimeNS"] = 10 + sample["elapsedSeconds"] * 1_000_000_000
        row["resourceSamples"] = []
        receipt = dict(schemaVersion=1, bootSession=self.boot, operation="capture-only", status="completed", requestedRuns=1,
                       revision=self.commit, sourceState="clean", runs=[epoch])
        item = dict(kind="mac-capture-check", file="native.json", sha256=self.save("native.json", receipt))
        row["evidence"].append(item)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "passed")
        epoch["durationNS"] -= 1
        epoch["stoppedUptimeNS"] -= 1
        item["sha256"] = self.save("native.json", receipt)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "deferred")
        receipt.update(status="failed", failure="capture callback failed")
        item["sha256"] = self.save("native.json", receipt)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "failed")

    def test_route_recovery_requires_a_completed_epoch_after_the_change_and_keeps_samples(self):
        row = self.physical("route-change")
        row.update(deviceClass="Mac", platform="macOS")
        first = row["epochs"].pop()
        def epoch(start, key, changed):
            sample = dict(epoch=key, uptimeNS=start + 1, elapsedSeconds=0, thermalState="fair",
                          processCPUSeconds=1, residentBytes=1024, queueDepthSlots=1, acceptedChunks=1)
            return dict(first, epoch=key, durationNS=100, startedUptimeNS=start, stoppedUptimeNS=start + 100,
                        inputChanged=changed, resourceSamples=[sample])
        one, two, three = epoch(1, "e1", False), epoch(110, "e2", True), epoch(220, "e3", False)
        receipt = dict(schemaVersion=1, bootSession=self.boot, operation="capture-only", requestedRuns=2, revision=self.commit,
                       sourceState="clean", status="failed", failure="input configuration changed", runs=[one,two])
        row["evidence"].append(dict(kind="mac-capture-check", file="before.json", sha256=self.save("before.json",receipt)))
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "deferred")
        after = dict(receipt, requestedRuns=1, status="completed", runs=[three])
        row["evidence"].append(dict(kind="mac-capture-check", file="after.json", sha256=self.save("after.json",after)))
        result = device_trial.evaluate(row, self.folder)
        self.assertEqual(result["functionalStatus"], "passed")
        after["bootSession"] = self.boot.replace("1", "9")
        row["evidence"][-1]["sha256"] = self.save("after.json", after)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "failed")
        self.assertEqual(result["measurements"]["queueDepthSlots"]["count"], 3)
        self.assertEqual(result["resourceSamples"][-1]["elapsedSeconds"], 219e-9)

    def test_stalled_microphone_and_impossible_pcm_configuration_do_not_qualify(self):
        row = self.physical()
        row["epochs"][0]["consumedFrames"] = 6000
        self.assertIn("delivered audio duration differs from the capture interval", device_trial.evaluate(row, self.folder)["failures"])
        for changes in (dict(channels=33), dict(queueSlots=4096, maximumFramesPerChunk=65536)):
            invalid = copy.deepcopy(row)
            invalid["epochs"][0].update(changes)
            with self.assertRaises(ValueError):
                device_trial.evaluate(invalid, self.folder)

    def test_recovered_epoch_must_be_lossless_and_have_an_observed_prior_boundary(self):
        row = self.physical("interruption")
        old = row["epochs"][0]
        old.update(boundary="interruption", droppedFrames=5, knownGapFrames=5)
        new = dict(old, epoch="e2", boundary=None, droppedFrames=0, knownGapFrames=0)
        row["epochs"].append(new)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "passed")
        new.update(droppedFrames=1, knownGapFrames=1)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "failed")
        new["boundary"] = "interruption"
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "deferred")

    def test_sustained_capture_cannot_hide_stalls_or_shorten_its_measurement_window(self):
        row = self.physical()
        row["resourceSamples"].insert(1,dict(row["resourceSamples"][0], elapsedSeconds=30, processCPUSeconds=3))
        self.assertIn("capture stalled between resource observations", device_trial.evaluate(row,self.folder)["failures"])
        row["resourceSamples"].pop(1)
        row["resourceSamples"][1]["longestObservedStallNS"] = 5_000_000_000
        self.assertIn("capture stalled before thinning resource history", device_trial.evaluate(row,self.folder)["failures"])
        row["epochs"][0].update(durationNS=600_000_000_000, acceptedChunks=30000, drainedChunks=30000, consumedFrames=28_800_000)
        report = device_trial.evaluate(row,self.folder)
        self.assertIn("declared trial duration is shorter than capture", report["failures"])
        self.assertIn("sustained residentBytes observations", report["missing"])

    def test_invalid_clock_counter_and_sensor_observations_cannot_pass(self):
        row = self.physical()
        for field, value in (("processCPUSeconds", -1), ("elapsedSeconds", 0), ("queueDepthSlots", True),
                             ("residentBytes", 0), ("thermalState", "unrecognized")):
            with self.subTest(field=field):
                bad = copy.deepcopy(row)
                bad["resourceSamples"][1][field] = value
                with self.assertRaises(ValueError):
                    device_trial.evaluate(bad, self.folder)
        row["energy"] = {"unit": None, "samples": [0.1], "unavailableReason": None}
        with self.assertRaises(ValueError):
            device_trial.evaluate(row, self.folder)
