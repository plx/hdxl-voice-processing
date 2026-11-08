#!/usr/bin/env python3
"""Generate original session-v1 candidates independently of the Swift encoder.

Requires a new explicit output directory. No input recordings, native exports,
reference executable or network are used. Never updates provenance or goldens.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

MAGIC = bytes.fromhex("4844584c564f49434500010000000000")
START = (1 << 54) + 29
EPOCH = {"streamID": "00000000-0000-0000-0000-000000005801", "sequence": 7}
CATALOG = {1, 2, 3, 4, 7, 8, 9, 10, 11, 13}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode()


def identifier(name):
    return {"name": name, "version": 1}


def source_interval(start, count):
    return {"epoch": EPOCH, "startSample": start, "sampleCount": count, "sampleRate": 16000}


def source(start=START, continuity=19):
    return {"origin": {"source": source_interval(start, 0),
            "continuityEpoch": {**EPOCH, "sequence": continuity},
            "sourceStartSeconds": None, "hostStartNanoseconds": None,
            "wallClockStartUnixSeconds": None},
            "acquisition": {"conditions": {"routeIdentifier": "synthetic-route",
                "recordingSettings": {}, "notes": "No human recording"},
                "deviceIdentifier": "synthetic-device", "platformDescription": "synthetic-platform"}}


def levels(window=400, hop=160):
    return {"schemaVersion": 1, "sampleRate": 16000, "inputPrecision": "float64",
            "arithmeticPrecision": "float64", "windowLength": window, "hopLength": hop,
            "accumulation": "compensatedSliding", "weighting": {"kind": "none"},
            "partialWindowPolicy": "emitUnavailable", "pcmReference": "unitPeak",
            "channelPolicy": "monoAlreadySelected", "averaging": "rectangularMeanSquare",
            "energyUnit": "normalizedSquaredAmplitude", "logLevelUnit": "decibelsFullScale",
            "filterPhasePolicy": "causalFrequencyDependentNoTimestampShift", "kWeighting": None}


def series(source_index=0, scheduled=False):
    return {"profileIndex": 0, "sourceIndex": source_index,
            "measurement": {"kind": "rms", "unit": "normalizedAmplitude",
                "algorithm": identifier("digital-level-windows")},
            "clock": "secondsFromOrigin" if scheduled else "sourceSamples",
            "isScheduled": scheduled, "mask": None}


class Archive:
    def __init__(self, *, audio=False):
        self.bytes = bytearray(MAGIC)
        self.kinds = []
        self.media_bytes = 0
        self.add(1, {"format": "hdxl-voice-session", "schemaVersion": 1,
                     "id": "00000000-0000-0000-0000-000000005800",
                     "producer": identifier("independent-python-session-fixture"),
                     "audioPolicy": "explicitlyInclude" if audio else "omit",
                     "notes": "Original synthetic contract fixture; no personal data"})

    def add(self, kind, value):
        payload = value if isinstance(value, bytes) else canonical(value)
        prefix = struct.pack("<B3xIQ", kind, len(payload), len(self.kinds))
        self.bytes += prefix + hashlib.sha256(prefix + payload).digest() + payload
        self.kinds.append(kind)
        if kind == 12:
            self.media_bytes += len(payload) - 12

    def finish(self, completion="completed"):
        self.add(255, {"completion": completion, "precedingRecordCount": len(self.kinds),
            "precedingByteCount": len(self.bytes),
            "precedingSHA256": {"sha256": hashlib.sha256(self.bytes).hexdigest()},
            "measurementCount": self.kinds.count(5), "gapCount": self.kinds.count(6),
            "catalogEntryCount": sum(kind in CATALOG for kind in self.kinds),
            "mediaReferenceCount": self.kinds.count(11), "embeddedMediaBytes": self.media_bytes})
        return bytes(self.bytes)


def timing(start, count, included, delay, clocks=False):
    result = struct.pack("<QQQdB", start, count, included, delay, 7 if clocks else 0)
    if clocks:
        result += struct.pack("<dQQ", -2.5, (1 << 64) - 101, (1 << 64) - 2)
    return result


def scalar(index, start, reason=None, intermediates=False):
    result = struct.pack("<IQ", index, start + 2)
    result += timing(start, 7, 6, 0.25, clocks=True)
    result += (struct.pack("<BB", 1, reason) if reason is not None
               else struct.pack("<BdBdB", 0, 0.25, 1, 0.75, 5))
    result += struct.pack("<II", 4 if intermediates else 0, 1 if intermediates else 0)
    if intermediates:
        name = b"synthetic-spectrum"
        result += struct.pack("<H", len(name)) + name
        result += struct.pack("<IQQBBddI", 1, start, 7, 0, 6, 0, 0.25, 4)
        result += struct.pack("<4d", 0, 0.125, -4, 1e20)
    return result


def scalar_archive(completion):
    archive = Archive()
    archive.add(2, {"kind": "levels", "recipe": levels()})
    archive.add(3, source())
    archive.add(4, series())
    archive.add(5, scalar(0, START, intermediates=True))
    for reason in range(13):
        archive.add(5, scalar(0, START + 16 * (reason + 1), reason=reason))
    next_start = START + 229
    archive.add(3, source(next_start, continuity=20))
    archive.add(6, {"previousSourceIndex": 0, "nextSourceIndex": 1,
        "observedSource": source_interval(START, 224), "dispatchedSourceSamples": 222,
        "pendingSourceSamplesDiscarded": 2, "missingSource": source_interval(START + 224, 5),
        "reason": "droppedAudio"})
    archive.add(4, series(1))
    archive.add(5, scalar(1, next_start))
    return archive.finish(completion)


def wave():
    pcm = struct.pack("<32h", *([8192] * 32))
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


def audio_archive(embedded):
    archive = Archive(audio=embedded)
    pcm = {"sampleRate": 16000, "channelCount": 1, "encoding": "float64", "layout": "planar"}
    profile = {"schemaVersion": 1, "inputFormat": pcm, "channels": {"channelIndex": 0},
               "channelConversion": "nativeSelectionOrScaledFloat64Mean",
               "levels": levels(8, 8), "pitch": None, "cpps": None}
    archive.add(2, {"kind": "schedule", "recipe": profile})
    archive.add(3, source())
    archive.add(4, series(scheduled=True))
    for offset in range(0, 32, 8):
        native = timing(START + offset, 8, 8, 8 / 16000 / 2)
        record = struct.pack("<Id", 0, offset / 16000 + 8 / 16000 / 2) + native
        record += struct.pack("<BdBB", 0, 0.25, 0, 0)  # available RMS, no confidence/warnings
        record += native + struct.pack("<13Q", 8, 8, 8, *([0] * 10))
        record += struct.pack("<dII", 128 / 16000, 0, 0)
        archive.add(5, record)
    audio = wave()
    storage = {"sampleRate": ("real", 16000), "formatID": ("integer", 1819304813),
               "formatFlags": ("integer", 12), "bytesPerPacket": ("integer", 2),
               "framesPerPacket": ("integer", 1), "bytesPerFrame": ("integer", 2),
               "channelsPerFrame": ("integer", 1), "bitsPerChannel": ("integer", 16)}
    archive.add(11, {"media": {"referenceIdentifier": "original-synthetic-pcm16-wave",
        "originalRecordingID": "00000000-0000-0000-0000-000000005802",
        "content": {"sha256": hashlib.sha256(audio).hexdigest()}, "byteCount": len(audio)},
        "decoder": {"identifier": "apple-avaudiofile-native-pcm-v1",
            "runtime": "synthetic-fixture-origin", "fileSampleCount": 32, "decodedPCM": pcm,
            "storage": {key: {"type": kind, kind: value} for key, (kind, value) in storage.items()}},
        "inclusion": "embedded" if embedded else "omitted",
        "provenance": identifier("independent-integer-pcm-generator"),
        "mappings": [{"sourceIndex": 0, "source": source_interval(START, 32), "fileStartSample": 0}],
        "notes": "32 mono PCM16 samples at 16000 Hz, each 8192/32768"})
    if embedded:
        archive.add(12, struct.pack("<IQ", 0, 0) + audio[:31])
        archive.add(12, struct.pack("<IQ", 0, 31) + audio[31:])
    archive.add(13, {"seriesIndex": 0, "mediaReferenceIndex": 0, "mappingIndex": 0, "mask": None})
    return archive.finish()


def fixtures():
    complete = scalar_archive("completed")
    return {"scalars-v1.hvps": complete,
            "partial-v1.hvps": scalar_archive("partial"),
            "interrupted-v1.hvps": complete[:-7],
            "embedded-pcm-v1.hvps": audio_archive(True),
            "omitted-pcm-v1.hvps": audio_archive(False)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    values = fixtures()
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {"schemaVersion": 1, "generator": "independent-python-session-v1",
                "containsHumanVoice": False, "sourceStartSample": START, "files": []}
    for name, data in values.items():
        (args.output / name).write_bytes(data)
        manifest["files"].append({"name": name, "sha256": hashlib.sha256(data).hexdigest(),
                                  "byteCount": len(data)})
    (args.output / "manifest.json").write_bytes(canonical(manifest) + b"\n")


if __name__ == "__main__":
    main()
