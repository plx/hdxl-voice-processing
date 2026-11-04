"""Failure-injection checks for the provenance gate; no third-party dependencies."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("provenance", ROOT / "Tools/verify-provenance.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        name = "Tests/Fixtures/example.json"
        fixture = self.root / name
        fixture.parent.mkdir(parents=True)
        fixture.write_text('{"value":1}\n')
        self.files = {name}
        self.manifest = {
            "schemaVersion": 1,
            "runtimeExternalDependencies": [],
            "optionalModels": [],
            "projectLicense": {"status": "pending-owner-decision", "decisionURL": "https://example.invalid/decision"},
            "components": [],
            "fixtures": [{
                "id": "example", "path": name, "sha256": MODULE.digest(fixture),
                "source": {"kind": "original-generated", "url": "https://example.invalid/source", "versionOrHash": "1"},
                "redistribution": {"license": "project", "permission": "inherits-project-license", "evidence": "Owner decision pending"},
                "containsHumanVoice": False,
                "consent": {"status": "not-applicable", "evidence": "Synthetic JSON; no human recording"},
                "transformations": [], "expectedProfile": "contract-example-v1",
                "referenceOutputIdentity": "example-v1",
            }],
        }

    def check(self, manifest=None, publication=False):
        MODULE.validate(self.root, manifest or self.manifest, self.files, publication)

    def test_development_accepts_recorded_pending_license(self):
        self.check()

    def test_publication_requires_owner_license(self):
        with self.assertRaisesRegex(MODULE.ProvenanceError, "Publication blocked"):
            self.check(publication=True)

    def test_changed_fixture_fails(self):
        (self.root / self.manifest["fixtures"][0]["path"]).write_text("tampered")
        with self.assertRaisesRegex(MODULE.ProvenanceError, "SHA256 mismatch"):
            self.check()

    def test_removed_fixture_is_not_treated_as_unlisted_before_staging(self):
        subprocess.run(["git", "init", "--quiet"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "Tests"], cwd=self.root, check=True)
        name = self.manifest["fixtures"][0]["path"]
        self.assertIn(name, MODULE.visible_files(self.root))
        (self.root / name).unlink()
        self.assertNotIn(name, MODULE.visible_files(self.root))

    def test_uninventoried_audio_fails_even_outside_fixture_directory(self):
        self.files.add("Examples/undisclosed.wav")
        with self.assertRaisesRegex(MODULE.ProvenanceError, "unlisted"):
            self.check()

    def test_third_party_cannot_inherit_project_license(self):
        self.manifest["fixtures"][0]["source"]["kind"] = "third-party"
        with self.assertRaisesRegex(MODULE.ProvenanceError, "cannot inherit"):
            self.check()

    def test_human_voice_needs_documented_consent(self):
        self.manifest["fixtures"][0]["containsHumanVoice"] = True
        with self.assertRaisesRegex(MODULE.ProvenanceError, "consent evidence"):
            self.check()

    def test_private_sources_and_unknown_schema_fail(self):
        private = copy.deepcopy(self.manifest)
        private["fixtures"][0]["source"]["kind"] = "private-recording"
        with self.assertRaisesRegex(MODULE.ProvenanceError, "Private/unknown"):
            self.check(private)
        future = copy.deepcopy(self.manifest)
        future["schemaVersion"] = 2
        with self.assertRaisesRegex(MODULE.ProvenanceError, "Unsupported"):
            self.check(future)

    def test_path_traversal_and_duplicates_fail(self):
        unsafe = copy.deepcopy(self.manifest)
        unsafe["fixtures"][0]["path"] = "../outside.json"
        self.files.add("../outside.json")
        with self.assertRaisesRegex(MODULE.ProvenanceError, "Unsafe path"):
            self.check(unsafe)
        self.files.remove("../outside.json")
        self.manifest["fixtures"].append(copy.deepcopy(self.manifest["fixtures"][0]))
        with self.assertRaisesRegex(MODULE.ProvenanceError, "Duplicate"):
            self.check()

    def test_dependency_source_and_revision_drift_fail(self):
        lock_name = "Benchmarks/Package.resolved"
        lock_path = self.root / lock_name
        lock_path.parent.mkdir()
        self.files.add(lock_name)
        component = {
            "id": "benchmark", "sourceURL": "https://example.invalid/benchmark",
            "license": "Apache-2.0", "licenseEvidenceURL": "https://example.invalid/license",
            "usedBy": ["Benchmarks"], "status": "active", "selectedVersion": "1.0.0",
            "revision": "a" * 40, "swiftPackageIdentity": "benchmark", "redistributed": False,
        }
        self.manifest["components"] = [component]
        pin = {"identity": "benchmark", "location": component["sourceURL"] + ".git",
               "state": {"version": "1.0.0", "revision": "a" * 40}}
        lock_path.write_text(json.dumps({"version": 3, "pins": [pin]}))
        self.check()
        pin["state"]["revision"] = "b" * 40
        lock_path.write_text(json.dumps({"version": 3, "pins": [pin]}))
        with self.assertRaisesRegex(MODULE.ProvenanceError, "revision drift"):
            self.check()
        pin["state"]["revision"] = "a" * 40
        pin["location"] = "https://example.invalid/imposter"
        lock_path.write_text(json.dumps({"version": 3, "pins": [pin]}))
        with self.assertRaisesRegex(MODULE.ProvenanceError, "source drift"):
            self.check()

    def test_contract_generator_matches_existing_golden_files(self):
        spec = importlib.util.spec_from_file_location("contract_generator", ROOT / "Tools/Fixtures/generate-contract-fixtures.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        for name, content in generator.fixtures().items():
            actual = (ROOT / "Tests/HDXLVoiceProcessingTests/Fixtures" / name).read_bytes()
            self.assertEqual(actual, content.encode("utf-8"))


if __name__ == "__main__":
    unittest.main()
