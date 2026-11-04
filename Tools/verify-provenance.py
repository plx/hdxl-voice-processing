"""Check dependency and fixture provenance without downloading or executing references."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


class ProvenanceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ProvenanceError(message)


def text(value, label):
    require(isinstance(value, str) and bool(value.strip()), f"{label}: expected nonempty text")
    return value


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_path(root, relative):
    text(relative, "path")
    pure = PurePosixPath(relative)
    require(not pure.is_absolute() and ".." not in pure.parts, f"Unsafe path: {relative}")
    resolved = (root / relative).resolve()
    require(resolved.is_relative_to(root.resolve()), f"Path leaves repository: {relative}")
    require(resolved.is_file(), f"Missing file: {relative}")
    return resolved


def check_hash(root, record):
    path = checked_path(root, record["path"])
    expected = record["sha256"]
    require(isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected), f"Invalid SHA256: {record['path']}")
    require(digest(path) == expected, f"SHA256 mismatch: {record['path']}")


def visible_files(root):
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    )
    names = {item.decode("utf-8") for item in output.split(b"\0") if item}
    return {name for name in names if (root / name).is_file()}


def fixture_paths(files):
    audio = {".wav", ".aif", ".aiff", ".flac", ".mp3", ".m4a", ".ogg", ".caf", ".pcm"}
    return {
        name for name in files
        if PurePosixPath(name).suffix.lower() in audio
        or ("fixtures" in [part.lower() for part in PurePosixPath(name).parts]
            and PurePosixPath(name).suffix.lower() not in {".md", ".py", ".swift"})
    }


def validate(root, manifest, files, for_publication=False):
    require(isinstance(manifest, dict), "Expected a provenance object")
    require(type(manifest.get("schemaVersion")) is int and manifest["schemaVersion"] == 1, "Unsupported provenance schema")
    require(manifest["runtimeExternalDependencies"] == [], "Runtime dependency policy changed: update graph checks and provenance together")
    require(manifest["optionalModels"] == [], "Model integration requires a separate license/download policy and verification")
    project = manifest["projectLicense"]
    status = project["status"]
    require(status in {"pending-owner-decision", "selected"}, "Invalid project license status")
    if status == "selected":
        text(project["identifier"], "Project license identifier")
        checked_path(root, project["path"])
        text(project["decisionURL"], "Project license decision")
    else:
        text(project["decisionURL"], "Pending license decision")
        require(not for_publication, "Publication blocked: project license awaits owner decision (#78)")

    component_ids = set()
    swift_pins = {}
    for component in manifest["components"]:
        identifier = text(component["id"], "Component id")
        require(identifier not in component_ids, f"Duplicate component: {identifier}")
        component_ids.add(identifier)
        for key in ("sourceURL", "license", "licenseEvidenceURL"):
            text(component[key], f"{identifier}.{key}")
        require(isinstance(component["usedBy"], list) and component["usedBy"], f"Missing usage: {identifier}")
        state = component["status"]
        require(state in {"system", "development-tool", "planned", "design-only", "active"}, f"Invalid component status: {identifier}")
        if state == "planned":
            require(component["selectedVersion"] is None, f"Planned version must remain unselected: {identifier}")
            text(component["implementationIssue"], f"{identifier}.implementationIssue")
        else:
            text(component["selectedVersion"], f"{identifier}.selectedVersion")
        require(isinstance(component["redistributed"], bool), f"Missing redistribution classification: {identifier}")
        if component.get("swiftPackageIdentity") and state == "active":
            revision = component.get("revision", "")
            require(re.fullmatch(r"[0-9a-f]{40}", revision) is not None, f"Missing exact revision: {identifier}")
            package_identity = component["swiftPackageIdentity"]
            require(package_identity not in swift_pins, f"Duplicate Swift identity: {package_identity}")
            swift_pins[package_identity] = component
        if component.get("redistributed"):
            require(state == "active", f"Only active dependencies may be redistributed: {identifier}")
            for notice in component["noticePaths"]:
                checked_path(root, notice)
            require(bool(component["noticePaths"]), f"Missing notices: {identifier}")

    # Every resolved direct/transitive Swift package must have an exact inventory record.
    for name in files:
        if PurePosixPath(name).name != "Package.resolved":
            continue
        lock = json.loads(checked_path(root, name).read_text())
        require(lock.get("version") in {2, 3}, f"Unsupported lock format: {name}")
        for pin in lock["pins"]:
            identity = pin["identity"]
            require(identity in swift_pins, f"Uninventoried Swift dependency: {identity} in {name}")
            entry = swift_pins[identity]
            normalized_url = lambda value: value.rstrip("/").removesuffix(".git")
            require(normalized_url(pin["location"]) == normalized_url(entry["sourceURL"]), f"Dependency source drift: {identity}")
            require(pin["state"]["revision"] == entry["revision"], f"Dependency revision drift: {identity}")
            require(pin["state"].get("version", entry["selectedVersion"]) == entry["selectedVersion"], f"Dependency version drift: {identity}")

    paths = set()
    identifiers = set()
    for fixture in manifest["fixtures"]:
        identifier = text(fixture["id"], "Fixture id")
        require(identifier not in identifiers, f"Duplicate fixture id: {identifier}")
        identifiers.add(identifier)
        path = fixture["path"]
        require(path not in paths, f"Duplicate fixture path: {path}")
        paths.add(path)
        require(path in files, f"Fixture is not Git-visible: {path}")
        check_hash(root, fixture)
        source = fixture["source"]
        require(source["kind"] in {"original-generated", "third-party"}, f"Private/unknown source is not allowed: {path}")
        for key in ("url", "versionOrHash"):
            text(source[key], f"{path}.source.{key}")
        rights = fixture["redistribution"]
        if rights["license"] == "project":
            require(source["kind"] == "original-generated", f"Third-party fixture cannot inherit project license: {path}")
            require(rights["permission"] == "inherits-project-license", f"Invalid project permission reference: {path}")
        else:
            text(rights["license"], f"{path}.license")
            require(rights["permission"] == "granted", f"Redistribution permission not granted: {path}")
        text(rights["evidence"], f"{path}.redistribution.evidence")
        require(isinstance(fixture["containsHumanVoice"], bool), f"Missing voice classification: {path}")
        consent = fixture["consent"]
        require(consent["status"] in {"not-applicable", "documented"}, f"Missing consent status: {path}")
        if fixture["containsHumanVoice"]:
            require(consent["status"] == "documented", f"Human voice needs consent evidence: {path}")
        text(consent["evidence"], f"{path}.consent.evidence")
        require(isinstance(fixture["transformations"], list), f"Missing transformations: {path}")
        for transformation in fixture["transformations"]:
            text(transformation, f"{path}.transformation")
        text(fixture["expectedProfile"], f"{path}.expectedProfile")
        text(fixture["referenceOutputIdentity"], f"{path}.referenceOutputIdentity")
        if "generator" in fixture:
            require(fixture["generator"]["path"] in files, f"Generator is not Git-visible: {path}")
            check_hash(root, fixture["generator"])
            text(fixture["generator"]["version"], f"{path}.generator.version")
    require(paths == fixture_paths(files), f"Fixture inventory mismatch: unlisted={sorted(fixture_paths(files) - paths)}, stale={sorted(paths - fixture_paths(files))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--for-publication", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        manifest = json.loads((root / "Configuration/provenance.json").read_text())
        validate(root, manifest, visible_files(root), args.for_publication)
    except (ProvenanceError, KeyError, TypeError, OSError, json.JSONDecodeError) as error:
        print(f"Provenance check failed: {error}", file=sys.stderr)
        return 1
    print(f"Provenance verified: {len(manifest['fixtures'])} fixtures; project license {manifest['projectLicense']['status']}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
