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

def stage(java_home: Path, jar: Path, destination: Path, replace: bool = False) -> dict:
    java_home, jar, destination = java_home.resolve(), jar.resolve(), destination.resolve()
    if destination == java_home or destination.is_relative_to(java_home) or java_home.is_relative_to(destination):
        raise ValueError("Staging destination must be separate from the source java-home")
    validation = verify.validate(java_home, jar)
    destination.mkdir(parents=True, exist_ok=True)
    owned = [destination / "java-home", destination / "legado-runtime.jar", destination / "runtime-manifest.json"]
    if any(path.exists() for path in owned) and not replace:
        raise ValueError("Staged payload already exists; pass --replace to replace only runtime-owned paths")
    if replace and any(path.exists() for path in owned) and not (destination / "runtime-manifest.json").is_file():
        raise ValueError("Refusing to replace a payload without a runtime-manifest.json ownership marker")
    if any(path.is_symlink() for path in owned):
        raise ValueError("Refusing to replace symlinked runtime-owned paths")
    manifest = {**validation, "jarSHA256": hashlib.sha256(jar.read_bytes()).hexdigest(), "layout": "exploded-java-home/modules", "sourcePins": json.loads((HERE / "runtime-lock.json").read_text(encoding="utf-8"))}
    with tempfile.TemporaryDirectory(prefix="legado-stage-", dir=destination.parent) as temporary:
        staged = Path(temporary)
        shutil.copytree(java_home, staged / "java-home")
        shutil.copy2(jar, staged / "legado-runtime.jar")
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
    args = parser.parse_args()
    print(json.dumps(stage(args.java_home, args.jar, args.destination, args.replace), indent=2))

if __name__ == "__main__": main()
