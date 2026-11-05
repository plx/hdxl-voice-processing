"""Failure controls for optimized sanitizer capability evidence."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

SPEC = importlib.util.spec_from_file_location(
    "sanitizer_capability", Path(__file__).resolve().parents[1] / "sanitizer-capability.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class SanitizerCapabilityTests(unittest.TestCase):
    def test_only_the_expected_instrumented_failure_counts(self):
        for mode, (_, diagnostics, code) in probe.CONTROLS.items():
            for marker in diagnostics:
                self.assertTrue(probe.validate_result(mode, code, marker)["available"])
            diagnostic = diagnostics[0]
            self.assertTrue(probe.validate_result(mode, code, diagnostic)["available"])
            for observed_code, output in (
                    (0, diagnostic), (-11, diagnostic), (code, "compiler error"),
                    (code, diagnostic + "\nUnexpected success: 114"),
                    (code, "WARNING: unrelated runtime diagnostic")):
                with self.subTest(mode=mode, code=observed_code, output=output):
                    with self.assertRaises(ValueError):
                        probe.validate_result(mode, observed_code, output)

    def test_capture_retains_diagnostics_and_exit_status(self):
        code, output = probe.capture(
            [sys.executable, "-c", "print('controlled diagnostic'); raise SystemExit(86)"], 5)
        self.assertEqual(code, 86)
        self.assertEqual(output, "controlled diagnostic\n")

    def test_timeout_and_excessive_log_are_failures(self):
        with self.assertRaisesRegex(ValueError, "exceeded"):
            probe.capture([sys.executable, "-c", "import time; time.sleep(10)"], .05)
        with self.assertRaisesRegex(ValueError, "log budget"):
            probe.capture([sys.executable, "-c", f"print('x' * {probe.MAX_LOG_BYTES})"], 5)


if __name__ == "__main__":
    unittest.main()
