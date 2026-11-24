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
            row["resourceSamples"] = [dict(epoch="e1", elapsedSeconds=t, processCPUSeconds=t/4,
                                           residentBytes=1024+t, queueDepthSlots=1, thermalState="unavailable")
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
        receipt = dict(schemaVersion=1, operation="capture-only", status="completed", requestedRuns=2,
                       revision=self.commit, sourceState="clean", runs=[first, dict(first, epoch="e2")])
        item = dict(kind="mac-capture-check", file="native.json", sha256=self.save("native.json", receipt))
        row["evidence"].append(item)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "passed")
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
        epoch.update(resourceSamples=row.pop("resourceSamples"), durationNS=120_000_000_000)
        row["resourceSamples"] = []
        receipt = dict(schemaVersion=1, operation="capture-only", status="completed", requestedRuns=1,
                       revision=self.commit, sourceState="clean", runs=[epoch])
        item = dict(kind="mac-capture-check", file="native.json", sha256=self.save("native.json", receipt))
        row["evidence"].append(item)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "passed")
        epoch["durationNS"] -= 1
        item["sha256"] = self.save("native.json", receipt)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "deferred")
        receipt.update(status="failed", failure="capture callback failed")
        item["sha256"] = self.save("native.json", receipt)
        self.assertEqual(device_trial.evaluate(row, self.folder)["functionalStatus"], "failed")

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
