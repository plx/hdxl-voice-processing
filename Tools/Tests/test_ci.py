"""Failure-path checks for the contributor/CI entry point."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ci", Path(__file__).resolve().parents[1] / "ci.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class CIGateTests(unittest.TestCase):
    def setUp(self):
        self.expected = json.loads((ci.ROOT / "Configuration/build.json").read_text())
        self.actual = {
            "xcode": f"Xcode {self.expected['xcodeVersion']}\nBuild version {self.expected['xcodeBuild']}",
            "swift": f"swiftlang-{self.expected['swiftCompilerVersion']}",
            "hostOS": "27.0.1", "python": self.expected["pythonVersion"],
            "sdks": {"macosx": "27.0", "iphoneos": "27.0", "iphonesimulator": "27.0"},
        }

    def test_toolchain_drift_is_not_a_success(self):
        ci.validate_environment(self.actual, self.expected)
        for key, value in (("xcode", "Xcode 27.1\nBuild version drift"),
                           ("swift", "Apple Swift version 6.3"), ("hostOS", "26.6.1"),
                           ("python", "3.15.1"), ("sdks", {"macosx": "27.1"})):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                ci.validate_environment({**self.actual, key: value}, self.expected)

    def test_child_failure_fails_lane_and_replaces_stale_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Configuration").mkdir()
            (root / "Configuration/build.json").write_text(json.dumps(self.expected))
            output = root / ".build/ci-artifacts/debug"
            output.mkdir(parents=True)
            (output / "stale.xml").write_text("old success")
            command = [sys.executable, "-c", "print('intentional failure'); raise SystemExit(23)"]
            with patch.object(ci, "ROOT", root), patch.object(ci, "environment", return_value=self.actual), \
                 patch.object(ci, "commands", return_value=[command]), \
                 patch.object(sys, "argv", ["ci.py", "debug"]), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ci.main(), 1)
            result = json.loads((output / "result.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["commands"][0]["exitCode"], 23)
            self.assertIn("intentional failure", (output / "commands.log").read_text())
            self.assertFalse((output / "stale.xml").exists())

    def test_local_account_paths_are_redacted(self):
        text = f"{ci.ROOT}/Sources/test.swift {Path.home()}/Library/example"
        self.assertEqual(ci.redact(text), "<checkout>/Sources/test.swift <home>/Library/example")

    def test_missing_empty_or_failed_reports_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            for xml in (None, '<testsuites/>',
                        '<testsuites><testsuite><testcase><failure/></testcase></testsuite></testsuites>'):
                with self.subTest(xml=xml):
                    if xml is not None:
                        (output / 'tests-swift-testing.xml').write_text(xml)
                    with self.assertRaises(RuntimeError):
                        ci.test_reports(output)
            (output / 'tests-swift-testing.xml').write_text(
                '<testsuites><testsuite><testcase/></testsuite></testsuites>')
            self.assertEqual(ci.test_reports(output)[0]['testCases'], 1)

    def test_report_redaction_preserves_valid_xml_and_failure_details(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'tests.xml'
            root = ET.Element('testsuites')
            failure = ET.SubElement(root, 'failure', message=f'{ci.ROOT}/Tests/example.json & missing')
            failure.text = f'Failed to read {Path.home()}/private-path'
            ET.ElementTree(root).write(report, encoding='utf-8', xml_declaration=True)
            ci.redact_report(report)
            restored = ET.parse(report).getroot().find('failure')
            self.assertEqual(restored.get('message'), '<checkout>/Tests/example.json & missing')
            self.assertEqual(restored.text, 'Failed to read <home>/private-path')
            self.assertNotIn(str(Path.home()), report.read_text())


if __name__ == "__main__":
    unittest.main()
