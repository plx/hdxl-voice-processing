import copy
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import instrumentation

spec = importlib.util.spec_from_file_location("trace_instrumentation", Path(__file__).resolve().parents[1] / "trace-instrumentation.py")
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


def trials(compiled_out=False):
    rows = []
    for index in range(8):
        for mode in instrumentation.MODES:
            selected = {"bare": 0, "disabled": 0, "sampled": 625, "detailed": 10000}[mode]
            rows.append(dict(trial=index, mode=mode, iterations=10000, nanoseconds=100000,
                             checksum="ede5395b22cea917", intervals=0 if compiled_out else selected * 3,
                             events=0 if compiled_out or not selected else selected + 1,
                             suppressed=37500 if mode == "sampled" else 0,
                             unavailable=selected * 4 + 1 if compiled_out and selected else 0))
    return rows


def synthetic_trace():
    root = ET.Element("trace-query-result")
    node = ET.SubElement(root, "node")
    schema = ET.SubElement(node, "schema", name="os-signpost")
    columns = ("time", "subsystem", "category", "name", "identifier", "event-type", "message")
    for name in columns:
        ET.SubElement(ET.SubElement(schema, "col"), "mnemonic").text = name
    tick = 0
    span = {1: 0, 2: 0}
    def emit(session, frame, name, kind, identifier=None, validity=0):
        nonlocal tick
        tick += 1
        if kind != "End":
            span[session] += 1
        identifier = identifier or f"{session}:{span[session]}"
        epoch = 0 if frame <= 8 else 1
        message = (f"session={session} epoch={epoch} span={span[session]} profile=1 frame={frame} "
                   f"samples=32 depth=1 validity={validity} processed=0 queue_ns=123") if kind != "End" else ""
        category = "worker" if name in {"FFT", "AnalysisFrame"} else "lifecycle"
        row = ET.SubElement(node, "row")
        for key, value in zip(columns, (tick, trace.SUBSYSTEM, category, name, identifier, kind, message)):
            ET.SubElement(row, key).text = str(value)
        return identifier
    for session in (1, 2):
        emit(session, 0, "Initialize", "Event")
    for frame in range(32):
        ids = {}
        for session in (1, 2):
            ids[session] = [emit(session, frame, "AnalysisFrame", "Begin")]
            emit(session, frame, "CaptureHandoff", "Event")
            ids[session].append(emit(session, frame, "FFT", "Begin"))
            event = {5: ("Error", 6), 7: ("Cancelled", 5), 8: ("Reset", 0), 9: ("Overrun", 3),
                     10: ("RouteChange", 0), 11: ("ConfigurationChange", 0)}.get(frame)
            if event:
                emit(session, frame, event[0], "Event", validity=event[1])
        for session in (1, 2):
            emit(session, frame, "FFT", "End", ids[session][1])
            emit(session, frame, "AnalysisFrame", "End", ids[session][0])
    return root


class InstrumentationEvidenceTests(unittest.TestCase):
    def test_mode_counts_checksums_and_fallback(self):
        for compiled_out in (False, True):
            self.assertEqual(instrumentation.summarize(trials(compiled_out), compiled_out)["checksum"], "ede5395b22cea917")

    def test_missing_or_corrupted_overhead_is_rejected(self):
        valid = trials()
        cases = [valid[:-1], valid + [valid[0]]]
        for key, value in (("checksum", "wrong"), ("nanoseconds", 0), ("intervals", 1), ("trial", 99)):
            changed = copy.deepcopy(valid)
            changed[0][key] = value
            cases.append(changed)
        for rows in cases:
            with self.assertRaises(ValueError):
                instrumentation.summarize(rows)

    def test_trace_requires_complete_pairs_and_numeric_metadata(self):
        root = synthetic_trace()
        self.assertEqual(trace.validate_trace(ET.tostring(root))["pairedIntervals"], 128)
        for mutation in ("missing_end", "payload", "frame"):
            changed = copy.deepcopy(root)
            node = changed.find("node")
            if mutation == "missing_end":
                node.remove(node.findall("row")[-1])
            elif mutation == "payload":
                node.find("row/message").text += " file=/private/audio.wav"
            else:
                row = next(r for r in node.findall("row") if r.findtext("name") == "Error")
                row.find("message").text = row.findtext("message").replace("frame=5", "frame=0")
            with self.assertRaises(ValueError):
                trace.validate_trace(ET.tostring(changed))

    def test_end_records_cannot_carry_metadata(self):
        for structured in (False, True):
            root = synthetic_trace()
            end = next(row for row in root.findall("node/row") if row.findtext("event-type") == "End")
            message = end.find("message")
            if structured:
                ET.SubElement(message, "narrative-text").text = "file=/private/audio.wav"
            else:
                message.text = "file=/private/audio.wav"
            with self.assertRaisesRegex(ValueError, "ends must not contain metadata"):
                trace.validate_trace(ET.tostring(root))

    def test_trace_uses_raw_numeric_arguments_instead_of_localized_display(self):
        root = synthetic_trace()
        message = root.find("node/row/message")
        fields = message.text.split()
        message.text = None
        message.set("fmt", "localized grouping must not be parsed")
        for index, field in enumerate(fields):
            key, number = field.split("=")
            ET.SubElement(message, "narrative-text").text = (" " if index else "") + key + "="
            argument = ET.SubElement(message, "uint64")
            argument.text = str((1 << 64) - 1) if key in ("frame", "queue_ns") else number
        self.assertEqual(trace.validate_trace(ET.tostring(root))["pairedIntervals"], 128)
        message.find("uint64").text = "not numeric"
        with self.assertRaises(ValueError):
            trace.validate_trace(ET.tostring(root))

    def test_callback_code_rejects_calls_and_backward_branches(self):
        header = "0000000100000010 <_$CaptureDiagnostics6record>:"
        for instruction in ("bl 0x100000020", "b.lo 0x100000010", "tbz w2, #0x0, 0x100000010"):
            with patch.object(instrumentation.ci, "capture", return_value=header + "\n100000014: 54000043 " + instruction):
                with self.assertRaises(ValueError):
                    instrumentation.inspect_callback(Path("unused"))
        assembly = header + "\n100000010: 54000043 tbz w2, #0x0, 0x100000018\n100000014: f9400288 ldr x8, [x20]\n100000018: d65f03c0 ret\n"
        with patch.object(instrumentation.ci, "capture", return_value=assembly):
            self.assertIn("tbz", instrumentation.inspect_callback(Path("unused")))


if __name__ == "__main__":
    unittest.main()
