#!/usr/bin/env python3
"""Stage a validated Java payload into the app's folder resource reference."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("verify_runtime", HERE / "verify-runtime.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
image_spec = importlib.util.spec_from_file_location("stage_module_image", HERE / "jimage-tools.py")
images = importlib.util.module_from_spec(image_spec)
image_spec.loader.exec_module(images)
notice_spec = importlib.util.spec_from_file_location("runtime_notices", HERE.parent / "reader-experience/runtime-notices.py")
notices = importlib.util.module_from_spec(notice_spec)
notice_spec.loader.exec_module(notices)

def stage(java_home: Path, jar: Path, destination: Path, replace: bool = False, module_format: str = "exploded") -> dict:
    if module_format not in ("exploded", "jimage"):
        raise ValueError("Unknown Java module format")
    for path in (java_home, jar, destination):
        notices.checked_path(path)
    java_home, jar, destination = java_home.resolve(), jar.resolve(), destination.resolve()
    if destination == java_home or destination.is_relative_to(java_home) or java_home.is_relative_to(destination):
        raise ValueError("Staging destination must be separate from the source java-home")
    validation = verify.validate(java_home, jar)
    notice_validation = notices.verify(notices.VENDOR)
    destination.mkdir(parents=True, exist_ok=True)
    owned = [destination / "java-home", destination / "legado-runtime.jar", destination / "runtime-manifest.json", destination / "Notices"]
    for path in owned:
        notices.checked_path(path)
    if any(path.exists() for path in owned) and not replace:
        raise ValueError("Staged payload already exists; pass --replace to replace only runtime-owned paths")
    if replace and any(path.exists() for path in owned) and not (destination / "runtime-manifest.json").is_file():
        raise ValueError("Refusing to replace a payload without a runtime-manifest.json ownership marker")
    if any(path.is_symlink() for path in owned):
        raise ValueError("Refusing to replace symlinked runtime-owned paths")
    if replace and (destination / "Notices").exists():
        previous = json.loads((destination / "runtime-manifest.json").read_bytes())
        previous_notices = previous.get("runtimeNotices") if isinstance(previous, dict) else None
        if (not isinstance(previous_notices, dict)
                or previous_notices.get("manifestSHA256") != notices.MANIFEST_SHA256):
            raise ValueError("Refusing to replace Notices without matching notice ownership in runtime-manifest.json")
        # A legacy three-path staging marker cannot authorize deleting a user's
        # sibling Notices directory. Both the old declaration and its actual
        # original notice manifest/bytes must identify this fixed owned payload.
        notices.verify(destination / "Notices")
    with tempfile.TemporaryDirectory(prefix="legado-stage-", dir=destination.parent) as temporary:
        staged = Path(temporary)
        staged_home = staged / "java-home"
        image_creation = None
        if module_format == "jimage":
            if not (java_home / "modules").is_dir():
                raise ValueError("Image creation requires the pinned exploded native input")
            # The native supply remains immutable. Only its module storage format
            # changes; configuration, security data and notices retain their bytes.
            shutil.copytree(java_home, staged_home,
                            ignore=lambda path, names: ["modules"] if Path(path) == java_home else [])
            (staged_home / "lib").mkdir(exist_ok=True)
            image_creation = images.create(java_home / "modules", staged_home / "lib/modules")
            image_creation.pop("resourcePaths", None)
        else:
            shutil.copytree(java_home, staged_home)
        staged_validation = verify.validate(staged_home, jar)
        manifest = {**staged_validation, "jarSHA256": hashlib.sha256(jar.read_bytes()).hexdigest(),
                    "layout": "jimage-java-home/lib/modules" if module_format == "jimage" else "exploded-java-home/modules",
                    "sourcePins": json.loads((HERE / "runtime-lock.json").read_text(encoding="utf-8")),
                    "runtimeNotices": notice_validation}
        if image_creation is not None:
            manifest["moduleImageCreation"] = image_creation
        shutil.copy2(jar, staged / "legado-runtime.jar")
        notices.stage(staged / "Notices")
        (staged / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        for path in owned:
            if path.exists():
                # Fixed child names of a resolved, explicit destination; never remove a source.
                if path.is_dir(): shutil.rmtree(path)
                else: path.unlink()
            shutil.move(str(staged / path.name), str(path))
    return manifest

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java-home", required=True, type=Path)
    parser.add_argument("--jar", required=True, type=Path)
    parser.add_argument("--destination", type=Path, default=HERE.parents[1] / "Resources/LegadoRuntime")
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--module-format", choices=("exploded", "jimage"), default="exploded")
    args = parser.parse_args()
    print(json.dumps(stage(args.java_home, args.jar, args.destination, args.replace, args.module_format), indent=2))

if __name__ == "__main__": main()
