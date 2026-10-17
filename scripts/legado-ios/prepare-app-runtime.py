#!/usr/bin/env python3
"""Place the validated Java home where the statically linked iOS JVM boots.

OpenJDK discovers App.app/lib before it parses -Djava.home. The engine JAR and
its original staging manifest remain in the LegadoRuntime resource directory.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import uuid


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("verify_app_runtime", HERE / "verify-runtime.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
OWNER_FILE = ".legado-runtime-home-owner.json"
OWNER = {"schemaVersion": 1, "owner": "legado-ios-prototype", "layout": "app-lib-java-home"}


def checked_path(path: Path, app: Path) -> Path:
    """Reject links and escapes before inspecting or mutating a bundle child."""
    if path == app or not path.is_relative_to(app):
        raise ValueError("Runtime path must be a child of the explicit .app bundle")
    candidate = app
    for component in path.relative_to(app).parts:
        candidate = candidate / component
        if candidate.is_symlink() or getattr(candidate, "is_junction", lambda: False)():
            raise ValueError("Refusing symlinked runtime path: " + str(candidate))
        resolved = candidate.resolve()
        if resolved == app or not resolved.is_relative_to(app):
            raise ValueError("Runtime path escapes the explicit .app bundle: " + str(candidate))
    return path


def checked_tree(root: Path, app: Path) -> None:
    pending = [checked_path(root, app)]
    while pending:
        current = checked_path(pending.pop(), app)
        if current.is_dir():
            pending.extend(current.iterdir())
        elif not current.is_file():
            raise ValueError("Runtime tree contains a non-regular entry: " + str(current))


def check_app(app: Path) -> Path:
    app = app.absolute()
    if app.suffix != ".app" or app.is_symlink() or getattr(app, "is_junction", lambda: False)():
        raise ValueError("Expected an explicit .app product, not a symlink")
    app = app.resolve(strict=True)
    if not app.is_dir():
        raise ValueError("App product is not a directory")
    info_path = checked_path(app / "Info.plist", app)
    info = plistlib.loads(info_path.read_bytes())
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or executable in {".", ".."} or any(c in executable for c in "/\\"):
        raise ValueError("Info.plist must identify a bundle-local executable")
    if not checked_path(app / executable, app).is_file():
        raise ValueError("App bundle executable is absent")
    return app


def read_manifest(marker: Path, jar: Path) -> dict:
    if not marker.is_file():
        raise ValueError("Runtime payload requires its runtime-manifest.json ownership marker")
    manifest = json.loads(marker.read_text(encoding="utf-8-sig"))
    if not isinstance(manifest, dict) or manifest.get("staticValidationPassed") is not True or manifest.get("layout") != "exploded-java-home/modules":
        raise ValueError("Invalid runtime-manifest.json ownership marker")
    if not jar.is_file():
        raise ValueError("Runtime payload JAR is absent")
    # Xcode build phases may select Apple's system Python 3.9 even when the
    # calling shell selected a newer interpreter. Do not require file_digest (3.11).
    digest = hashlib.sha256()
    with jar.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if manifest.get("jarSHA256") != digest.hexdigest():
        raise ValueError("Runtime payload JAR does not match its staging manifest")
    return manifest


def check_owned_home(home: Path, app: Path, jar: Path) -> dict:
    checked_tree(home, app)
    owner = checked_path(home / OWNER_FILE, app)
    if not owner.is_file() or json.loads(owner.read_text(encoding="utf-8-sig")) != OWNER:
        raise ValueError("Refusing to replace an unowned App/lib Java home")
    return verify.validate(home, jar)


def prepare(app: Path) -> dict:
    app = check_app(app)
    resources = checked_path(app / "LegadoRuntime", app)
    source = checked_path(resources / "java-home", app)
    destination = checked_path(app / "lib", app)
    marker = checked_path(resources / "runtime-manifest.json", app)
    jar = checked_path(resources / "legado-runtime.jar", app)
    result = {"javaHomePresent": False, "javaHomeRelativePath": None, "changed": False,
              "layout": "source-only", "staticValidationPassed": False, "deviceValidationPassed": False}
    if not source.exists() and not destination.exists() and not marker.exists():
        return result
    read_manifest(marker, jar)
    if destination.exists():
        check_owned_home(destination, app, jar)
    if not source.exists():
        if not destination.exists():
            raise ValueError("Staging manifest exists but both Java home directories are absent")
        return {**result, "javaHomePresent": True, "javaHomeRelativePath": "lib", "layout": OWNER["layout"], "staticValidationPassed": True}
    checked_tree(source, app)
    validation = verify.validate(source, jar)
    source_owner = checked_path(source / OWNER_FILE, app)
    if source_owner.exists():
        if json.loads(source_owner.read_text(encoding="utf-8-sig")) != OWNER:
            raise ValueError("Source Java home has an invalid ownership marker")
    else:
        with source_owner.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(OWNER, sort_keys=True) + "\n")

    # Both directories are in one verified bundle. Keep an old owned Java home
    # until the replacement rename succeeds, rather than deleting it first.
    backup = None
    if destination.exists():
        backup = checked_path(app / (".legado-runtime-lib-previous-" + uuid.uuid4().hex), app)
        if backup.exists():
            raise ValueError("Runtime backup path already exists")
        checked_path(destination, app).rename(checked_path(backup, app))
    try:
        checked_path(source, app).rename(checked_path(destination, app))
    except OSError:
        if backup is not None:
            checked_path(backup, app).rename(checked_path(destination, app))
        raise
    if backup is not None:
        checked_tree(backup, app)
        # Check the resolved absolute target again immediately before deletion.
        shutil.rmtree(checked_path(backup, app))
    return {**result, **validation, "javaHomePresent": True, "javaHomeRelativePath": "lib",
            "layout": OWNER["layout"], "changed": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Explicit already-built .app product")
    args = parser.parse_args()
    print(json.dumps(prepare(args.app), indent=2))


if __name__ == "__main__":
    main()
