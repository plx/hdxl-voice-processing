"""Independent framing/PCM audit and reproduction controls for session goldens."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import unittest
import wave
from collections import Counter

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/Sessions"
SPEC = importlib.util.spec_from_file_location("session_fixture_generator", ROOT / "Tools/Sessions/generate_fixtures.py")
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


def frames(data):
    """Structural oracle only; Swift separately validates every typed payload."""
    if data[:16] != bytes.fromhex("4844584c564f49434500010000000000"):
        raise ValueError("magic")
    offset = 16
    records = []
    while offset < len(data):
        if len(data) - offset < 48:
            raise ValueError("truncated header")
        kind, length, ordinal = struct.unpack_from("<B3xIQ", data, offset)
        if data[offset+1:offset+4] != b"\0\0\0" or ordinal != len(records):
            raise ValueError("ordering")
        end = offset + 48 + length
        if end > len(data):
            raise ValueError("truncated payload")
        payload = data[offset+48:end]
        if hashlib.sha256(data[offset:offset+16] + payload).digest() != data[offset+16:offset+48]:
            raise ValueError("digest")
        records.append((kind, payload))
        if kind == 255:
            seal = json.loads(payload)
            if end != len(data) or seal["precedingRecordCount"] != ordinal or seal["precedingByteCount"] != offset:
                raise ValueError("seal extent")
            if seal["precedingSHA256"]["sha256"] != hashlib.sha256(data[:offset]).hexdigest():
                raise ValueError("seal digest")
            return records
        offset = end
    raise ValueError("missing seal")


class SessionFixtureTests(unittest.TestCase):
    def test_reproduction_manifest_and_independent_footer_counts(self):
        generated = generator.fixtures()
        manifest = json.loads((FIXTURES / "manifest.json").read_bytes())
        self.assertFalse(manifest["containsHumanVoice"])
        self.assertEqual(manifest["sourceStartSample"], (1 << 54) + 29)
        self.assertEqual(set(generated), {item["name"] for item in manifest["files"]})
        for item in manifest["files"]:
            data = (FIXTURES / item["name"]).read_bytes()
            self.assertEqual(data, generated[item["name"]])
            self.assertEqual(len(data), item["byteCount"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"])
            if item["name"].startswith("interrupted"):
                with self.assertRaises(ValueError):
                    frames(data)
                continue
            records = frames(data)
            kinds = [kind for kind, _ in records]
            self.assertEqual(kinds[0], 1)
            seal = json.loads(records[-1][1])
            self.assertEqual(seal["measurementCount"], kinds.count(5))
            self.assertEqual(seal["gapCount"], kinds.count(6))
            self.assertEqual(seal["catalogEntryCount"], sum(kind in {1, 2, 3, 4, 7, 8, 9, 10, 11, 13} for kind in kinds))
            self.assertEqual(seal["mediaReferenceCount"], kinds.count(11))
            self.assertEqual(seal["embeddedMediaBytes"], sum(len(payload)-12 for kind, payload in records if kind == 12))

    def test_independent_frame_oracle_rejects_corruption_truncation_and_trailing_data(self):
        data = (FIXTURES / "scalars-v1.hvps").read_bytes()
        for offset in [0, 17, 20, 24, 32, 64, len(data)-1]:
            changed = bytearray(data)
            changed[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                frames(changed)
        for altered in [data[:16], data[:-1], data + b"\0", data + data]:
            with self.assertRaises(ValueError):
                frames(altered)

    def test_embedded_original_is_exact_integer_pcm_and_omission_has_no_chunks(self):
        records = frames((FIXTURES / "embedded-pcm-v1.hvps").read_bytes())
        chunks = [payload for kind, payload in records if kind == 12]
        self.assertEqual([struct.unpack_from("<IQ", chunk) for chunk in chunks], [(0, 0), (0, 31)])
        audio = b"".join(chunk[12:] for chunk in chunks)
        with wave.open(io.BytesIO(audio)) as original:
            self.assertEqual((original.getnchannels(), original.getsampwidth(), original.getframerate(), original.getnframes()), (1, 2, 16000, 32))
            self.assertEqual(struct.unpack("<32h", original.readframes(32)), (8192,) * 32)
        reference = json.loads(next(payload for kind, payload in records if kind == 11))
        self.assertEqual(reference["media"]["content"]["sha256"], hashlib.sha256(audio).hexdigest())
        omitted = frames((FIXTURES / "omitted-pcm-v1.hvps").read_bytes())
        self.assertNotIn(12, [kind for kind, _ in omitted])
        self.assertEqual(json.loads(next(payload for kind, payload in omitted if kind == 11))["inclusion"], "omitted")

    def test_calibration_fixture_preserves_labels_splits_rules_and_explicit_fabricated_claims(self):
        pin = json.loads((FIXTURES / "calibration-manifest.json").read_bytes())
        data = (FIXTURES / "calibration-v1.hvps").read_bytes()
        self.assertFalse(pin["containsHumanVoice"])
        self.assertEqual(pin["byteCount"], len(data))
        self.assertEqual(pin["sha256"], hashlib.sha256(data).hexdigest())
        reference = ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets/fitting-reference.json"
        self.assertEqual(pin["sourceReferenceSHA256"], hashlib.sha256(reference.read_bytes()).hexdigest())
        records = frames(data)
        kinds = Counter(kind for kind, _ in records)
        self.assertEqual(kinds, Counter({1: 1, 2: 1, 7: 1, 8: 1, 9: 64, 10: 2, 255: 1}))
        payload = {kind: json.loads(value) for kind, value in records if kind != 9 and kind != 10}
        self.assertEqual(payload[1]["audioPolicy"], "omit")
        self.assertIn("Fabricated", payload[1]["notes"])
        self.assertEqual(hashlib.sha256(generator.canonical(payload[2]["recipe"])).hexdigest(), pin["profileSHA256"])
        self.assertEqual(hashlib.sha256(generator.canonical(payload[7])).hexdigest(), pin["datasetSHA256"])
        plan = payload[8]["plan"]
        self.assertEqual(hashlib.sha256(generator.canonical(plan)).hexdigest(), pin["splitSHA256"])
        self.assertEqual(Counter(item["role"] for item in plan["assignments"]),
                         {"fitting": 14, "recordingEvaluation": 18, "sessionEvaluation": 32})
        takes = [take for session in payload[7]["sessions"] for take in session["takes"]]
        self.assertEqual(len(takes), 64)
        self.assertEqual(Counter(take["label"]["preference"] for take in takes), {"preferred": 32, "usual": 32})
        self.assertTrue(all(take["exclusions"][0]["source"]["sampleCount"] == 16 and len(take["mask"]["observations"]) == 1 for take in takes))
        targets = [json.loads(value) for kind, value in records if kind == 10]
        self.assertEqual([value["candidate"]["implementation"]["version"] for value in targets], [1, 99])
        self.assertIsNone(targets[1]["claimedEvaluationIdentity"])
        candidate = targets[0]["candidate"]
        self.assertEqual(hashlib.sha256(generator.canonical(candidate)).hexdigest(), pin["targetSHA256"])
        self.assertEqual(candidate["rule"]["featureScaling"], "identity; CPPS dB")
        self.assertEqual(candidate["rule"]["preferredInterval"], {"lower": 10, "upper": 10})
        self.assertEqual(candidate["rule"]["observedCPPS"], {"lower": 4, "upper": 10})
        self.assertEqual(candidate["rule"]["preferredTraining"]["count"], 7)
        self.assertEqual(candidate["rule"]["usualTraining"]["count"], 7)
        self.assertEqual(targets[0]["validationClaim"]["sourceIdentity"]["sha256"],
                         hashlib.sha256(b"fabricated-session-contract-validation-not-DSP-evidence").hexdigest())
        self.assertEqual(payload[255]["catalogEntryCount"], 70)
        self.assertEqual(payload[255]["embeddedMediaBytes"], 0)
