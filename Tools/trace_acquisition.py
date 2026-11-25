"""Acquire an Instruments Logging trace from a single, separately owned synthetic probe."""
import ctypes
import json
import os
import select
import signal
import subprocess
import time
import uuid


class IncompleteRecording(ValueError):
    """Instruments omitted target records. Keep the attempt reason if recording again."""


class CollectorTimeout(IncompleteRecording):
    """A collector phase timed out without producing verified evidence."""


class AcquisitionJournal:
    """Persist phase transitions separately from the validated signpost result."""

    def __init__(self, output, environment, binary_sha256):
        self.path = output.with_name(f"{output.stem}-attempts-{uuid.uuid4().hex}.json")
        self.started = time.monotonic()
        self.data = {"schemaVersion": 1, "commit": environment["commit"], "xcode": environment["xcode"],
                     "binarySHA256": binary_sha256, "status": "acquiring", "events": []}
        self.mark("prepared")

    def mark(self, phase, **values):
        self.data["events"].append({"phase": phase, "elapsedSeconds": round(time.monotonic() - self.started, 3),
                                    **values})
        self.persist()

    def finish(self, status):
        self.data["status"] = status
        self.persist()

    def persist(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.data, indent=2, allow_nan=False) + "\n")
        temporary.replace(self.path)


def _record_attached(target, trace, report, ready, journal, validate_report):
    name = "org.hdxl.voice.trace." + uuid.uuid4().hex
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    fd, token = ctypes.c_int(), ctypes.c_int()
    journal.mark("recorder-startup")
    if system.notify_register_file_descriptor(name.encode(), ctypes.byref(fd), 0, ctypes.byref(token)):
        raise RuntimeError("Unable to register for Instruments recording startup")
    try:
        command = ["xcrun", "xctrace", "record", "--template", "Logging", "--no-prompt", "--output", trace,
                   "--time-limit", "1m", "--notify-tracing-started", name, "--attach", str(target.pid)]
        with subprocess.Popen(command, stdin=subprocess.DEVNULL) as recorder:
            try:
                deadline = time.monotonic() + 60
                while not select.select([fd.value], [], [], 0.25)[0]:
                    if time.monotonic() >= deadline:
                        raise CollectorTimeout("Recording-start notification timed out")
                    if recorder.poll() is not None or target.poll() is not None:
                        raise RuntimeError("Recorder or replay exited before recording started")
                if len(os.read(fd.value, 4)) != 4:
                    raise RuntimeError("Incomplete Instruments startup notification")
                journal.mark("measured-workload")
                ready.touch(exist_ok=False)
                deadline = time.monotonic() + 60
                while not report.is_file():
                    if target.poll() is not None or recorder.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Replay failed to publish its trial before recording ended")
                    time.sleep(0.05)
                completed = validate_report(target.pid)
                journal.mark("recorder-finalization")
                recorder.send_signal(signal.SIGINT)
                try:
                    status = recorder.wait(timeout=120)
                except subprocess.TimeoutExpired as error:
                    raise CollectorTimeout("Recorder finalization timed out") from error
                if status:
                    raise subprocess.CalledProcessError(status, command)
                return completed
            finally:
                if recorder.poll() is None:
                    recorder.kill()
    finally:
        system.notify_cancel(token.value)


def record_when_ready(arguments, trace, report, journal, validate_report):
    # Own the target independently. Stopping the attached recorder cannot terminate
    # the replay, and the replay can wait for finalization without holding up xctrace.
    ready = report.with_name("recorder-started")
    env = dict(os.environ, HDXL_REPLAY_RECORDING_START=str(ready), HDXL_REPLAY_HOLD_FOR_RECORDER="1")
    journal.mark("target-startup")
    with subprocess.Popen(arguments, env=env, stdin=subprocess.DEVNULL) as target:
        try:
            completed = _record_attached(target, trace, report, ready, journal, validate_report)
            journal.mark("target-release")
            ready.unlink()
            status = target.wait(timeout=10)
            if status:
                raise subprocess.CalledProcessError(status, arguments)
            return completed
        finally:
            if target.poll() is None:
                target.kill()
            ready.unlink(missing_ok=True)
