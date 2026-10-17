#!/usr/bin/env python3
"""Run the already-built Zero probe in Simulator and preserve startup evidence.

This smoke test exercises a simulator process. It does not pass an iPhone/iPad
device gate, regardless of its result.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import uuid


BUNDLE_ID = "local.legado.runtime-probe"
DIAGNOSTICS_PATH = Path("Library/Application Support/LegadoRuntimeDiagnostics")
TERMINAL_STAGES = {"passed", "failed"}
CHECKPOINT_LIMIT = 32_768


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def decode_output(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value or ""


def read_checkpoint(path):
    """The app publishes this file atomically; malformed files are real failures."""
    try:
        with path.open("rb") as stream:
            data = stream.read(CHECKPOINT_LIMIT + 1)
    except FileNotFoundError:
        return None
    if len(data) > CHECKPOINT_LIMIT:
        raise RuntimeError("Probe checkpoint exceeds its 32 KiB limit")
    value = json.loads(data.decode("utf-8-sig"))
    if not isinstance(value, dict):
        raise RuntimeError("Probe checkpoint is not a JSON object")
    return value


def process_alive(pid):
    if pid is None:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # A sandbox denial says nothing about whether the process has exited.
        return True
    return True


def launch_pid(output):
    match = re.search(r"^" + re.escape(BUNDLE_ID) + r":\s*(\d+)\s*$", output, re.MULTILINE)
    return int(match.group(1)) if match else None


def checkpoint_is_current(checkpoint, pid, launched_at):
    timestamp = checkpoint.get("recordedAt")
    if isinstance(timestamp, bool) or not isinstance(timestamp, (float, int)):
        raise RuntimeError("Probe checkpoint has no numeric recordedAt timestamp")
    if timestamp < launched_at:
        return False
    if pid is not None and checkpoint.get("processIdentifier") != pid:
        return False
    if checkpoint.get("executionPlatform") != "ios-simulator":
        raise RuntimeError("Probe checkpoint did not identify an iOS simulator")
    return True


def wait_for_probe(checkpoint_path, pid, launched_at, deadline, observe):
    while True:
        checkpoint = read_checkpoint(checkpoint_path)
        if checkpoint and checkpoint_is_current(checkpoint, pid, launched_at):
            observe(checkpoint)
            stage = checkpoint.get("stage")
            if stage in TERMINAL_STAGES:
                if stage == "failed":
                    raise RuntimeError("Synthetic fixture failed: " + str(checkpoint.get("failure", "No failure detail")))
                return checkpoint
        if process_alive(pid) is False:
            # Read once more after process death: an atomic final checkpoint can
            # have landed between the preceding read and the liveness check.
            checkpoint = read_checkpoint(checkpoint_path)
            if checkpoint and checkpoint_is_current(checkpoint, pid, launched_at):
                observe(checkpoint)
                if checkpoint.get("stage") == "passed":
                    return checkpoint
                if checkpoint.get("stage") == "failed":
                    raise RuntimeError("Synthetic fixture failed: " + str(checkpoint.get("failure", "No failure detail")))
            raise RuntimeError("Simulator app exited before a terminal probe checkpoint")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Simulator probe did not finish before its deadline")
        # This polls an external process and an atomic file, not application
        # state that should instead be synchronized by a callback.
        time.sleep(min(1.0, remaining))


def built_app(settings):
    targets = [item for item in settings if item.get("target") == "LegadoRuntimeProbe"]
    if len(targets) != 1:
        raise RuntimeError("Expected exactly one LegadoRuntimeProbe build-settings target")
    values = targets[0]["buildSettings"]
    if values.get("PLATFORM_NAME") != "iphonesimulator":
        raise RuntimeError("Build settings did not select the simulator product")
    app = (Path(values["TARGET_BUILD_DIR"]) / values["FULL_PRODUCT_NAME"]).resolve()
    if not app.is_dir():
        raise RuntimeError("Already-built simulator app is absent: " + str(app))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError("Simulator app has an unexpected bundle identifier")
    if "iPhoneSimulator" not in info.get("CFBundleSupportedPlatforms", []):
        raise RuntimeError("App bundle is not an iPhoneSimulator build")
    if not (app / info["CFBundleExecutable"]).is_file():
        raise RuntimeError("Simulator app executable is absent")
    return app


class ProbeRun:
    def __init__(self, repo, output, timeout_seconds):
        self.repo = repo
        output.mkdir(parents=True, exist_ok=True)
        self.output_root = output
        self.output = output / (datetime.now(timezone.utc).strftime("run-%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
        self.output.mkdir()
        self.started = time.monotonic()
        self.deadline = self.started + timeout_seconds
        self.env = os.environ.copy()
        self.container = None
        self.pid = None
        self.udid = None
        self.launched_at = None
        self.result = {
            "schemaVersion": 1,
            "startedAt": utc_now(),
            "executionPlatform": "ios-simulator",
            "deviceValidationPassed": False,
            "simulatorValidationPassed": False,
            "status": "failed",
            "timeoutSeconds": timeout_seconds,
            "evidenceDirectory": str(self.output),
            "lastCheckpoint": None,
            "collectionErrors": [],
        }

    def command(self, name, argv, timeout=120, enforce_deadline=True):
        remaining = self.deadline - time.monotonic() if enforce_deadline else timeout
        if remaining <= 0:
            raise TimeoutError("Simulator probe deadline expired before " + name)
        record = {"name": name, "argv": argv, "startedAt": utc_now()}
        try:
            completed = subprocess.run(argv, cwd=self.repo, env=self.env, text=True,
                                       encoding="utf-8", errors="replace", capture_output=True,
                                       timeout=min(timeout, remaining), check=False)
            stdout, stderr = completed.stdout, completed.stderr
            record["returnCode"] = completed.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr = decode_output(error.stdout), decode_output(error.stderr)
            record["timedOut"] = True
            raise TimeoutError(name + " timed out") from error
        finally:
            # Write partial subprocess output even when boot or launch times out.
            if "stdout" in locals():
                (self.output / (name + ".stdout.log")).write_text(stdout, encoding="utf-8")
                (self.output / (name + ".stderr.log")).write_text(stderr, encoding="utf-8")
            with (self.output / "commands.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record) + "\n")
        if completed.returncode:
            detail = (completed.stderr or completed.stdout).strip()[-2000:]
            raise RuntimeError(f"{name} exited {completed.returncode}: {detail}")
        return completed.stdout

    def observe(self, checkpoint):
        previous = self.result["lastCheckpoint"]
        self.result["lastCheckpoint"] = checkpoint
        if not previous or (previous.get("stage"), previous.get("operation")) != (checkpoint.get("stage"), checkpoint.get("operation")):
            print(json.dumps({"stage": checkpoint.get("stage"), "operation": checkpoint.get("operation")}), flush=True)

    def run(self, device_filter):
        if sys.platform != "darwin":
            raise RuntimeError("Simulator execution requires macOS and Xcode")
        sim_script = str(self.repo / "scripts/sim.sh")
        developer = self.command("resolve-xcode", ["bash", sim_script, "xcode"]).strip()
        if not developer:
            raise RuntimeError("sim.sh returned no Xcode developer directory")
        self.env["DEVELOPER_DIR"] = developer
        destination = self.command("resolve-destination", ["bash", sim_script, "dest", device_filter]).strip()
        if not destination.startswith("id=") or "," in destination:
            raise RuntimeError("sim.sh returned an unexpected destination: " + destination)
        self.udid = destination.removeprefix("id=")
        self.result.update({"developerDirectory": developer, "destination": destination, "simulatorUDID": self.udid})
        project = self.repo / "Prototypes/LegadoRuntimeProbe/LegadoRuntimeProbe.xcodeproj"
        settings = self.command("build-settings", ["xcodebuild", "-project", str(project), "-scheme", "LegadoRuntimeProbe",
                                "-configuration", "Release", "-destination", destination, "ARCHS=arm64",
                                "CODE_SIGNING_ALLOWED=NO", "-showBuildSettings", "-json"])
        app = built_app(json.loads(settings))
        self.result["appPath"] = str(app)
        # build-probe.sh deliberately disables signing for both products. Only
        # this verified simulator bundle gets a local ad-hoc signature; the
        # separately packaged unsigned iPhone/iPad IPA is never modified here.
        self.command("simulator-codesign", ["codesign", "--force", "--sign", "-", "--timestamp=none", str(app)])
        self.command("simulator-codesign-verify", ["codesign", "--verify", "--strict", str(app)])
        self.result["simulatorSigning"] = "ad-hoc; simulator app only; no Apple account"
        inventory = json.loads(self.command("simulator-inventory", ["xcrun", "simctl", "list", "devices", "available", "--json"]))
        devices = [device for group in inventory["devices"].values() for device in group if device["udid"] == self.udid]
        if len(devices) != 1:
            raise RuntimeError("Selected simulator is absent or duplicated in the device inventory")
        state = devices[0]["state"]
        self.result["simulator"] = devices[0]
        if state == "Shutdown":
            self.command("boot", ["xcrun", "simctl", "boot", self.udid])
        elif state not in {"Booted", "Booting"}:
            raise RuntimeError("Selected simulator cannot be booted from state " + state)
        self.command("boot-status", ["xcrun", "simctl", "bootstatus", self.udid, "-b"], timeout=240)
        self.command("install", ["xcrun", "simctl", "install", self.udid, str(app)])
        container = self.command("app-container", ["xcrun", "simctl", "get_app_container", self.udid, BUNDLE_ID, "data"]).strip()
        self.container = Path(container)
        if not self.container.is_absolute() or not self.container.is_dir():
            raise RuntimeError("simctl returned an invalid app data container")
        stdout = self.output / "app-stdout.log"
        stderr = self.output / "app-stderr.log"
        stdout.touch()
        stderr.touch()
        self.command("launch-help", ["xcrun", "simctl", "help", "launch"])
        self.launched_at = time.time()
        launch_output = self.command("launch", ["xcrun", "simctl", "launch", "--terminate-running-process",
                                     "--stdout=" + str(stdout), "--stderr=" + str(stderr), self.udid,
                                     BUNDLE_ID, "--legado-probe-autorun"], timeout=60)
        self.pid = launch_pid(launch_output)
        self.result.update({"launchPID": self.pid, "launchedAtUnix": self.launched_at})
        if self.pid is None:
            self.result["pidNotice"] = "simctl returned no parseable PID; checkpoint timestamps establish freshness"
        checkpoint_path = self.container / DIAGNOSTICS_PATH / "probe-progress.json"
        wait_for_probe(checkpoint_path, self.pid, self.launched_at, self.deadline, self.observe)
        self.result.update({"simulatorValidationPassed": True, "status": "passed"})

    def collect(self):
        if self.container:
            diagnostics = self.container / DIAGNOSTICS_PATH
            target = self.output / "diagnostics"
            target.mkdir()
            for name in ("current", "previous", "exports", "probe-progress.json", "previous-probe-progress.json"):
                source = diagnostics / name
                if source.is_symlink():
                    raise RuntimeError("Diagnostics entry must not be a symlink: " + str(source))
                if source.is_dir():
                    shutil.copytree(source, target / name, symlinks=True)
                elif source.is_file():
                    shutil.copy2(source, target / name)
        # Simulator native crashes may be emitted here in addition to JVM logs.
        reports = Path.home() / "Library/Logs/DiagnosticReports"
        if self.launched_at and reports.is_dir():
            for source in reports.glob("LegadoRuntimeProbe*"):
                if source.is_file() and source.stat().st_mtime >= self.launched_at:
                    destination = self.output / "crash-reports"
                    destination.mkdir(exist_ok=True)
                    shutil.copy2(source, destination / source.name)

    def finish(self):
        try:
            self.collect()
        except Exception as error:
            self.result["collectionErrors"].append(str(error))
            self.result.update({"status": "failed", "simulatorValidationPassed": False})
            print("Diagnostics collection failed: " + str(error), file=sys.stderr, flush=True)
        self.result.update({"finishedAt": utc_now(), "elapsedSeconds": round(time.monotonic() - self.started, 3)})
        text = json.dumps(self.result, indent=2) + "\n"
        (self.output / "result.json").write_text(text, encoding="utf-8")
        (self.output_root / "result.json").write_text(text, encoding="utf-8")
        print(text, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-filter", default="iPhone", help="Name substring passed to scripts/sim.sh")
    parser.add_argument("--timeout-seconds", type=float, default=600)
    parser.add_argument("--output-directory", type=Path)
    args = parser.parse_args()
    if not 0 < args.timeout_seconds <= 600:
        parser.error("--timeout-seconds must be greater than zero and at most 600")
    repo = Path(__file__).resolve().parents[2]
    output = (args.output_directory or repo / ".build/ci-logs/simulator-probe").resolve()
    probe = ProbeRun(repo, output, args.timeout_seconds)
    try:
        probe.run(args.device_filter)
    except (Exception, KeyboardInterrupt) as error:
        probe.result["failure"] = f"{type(error).__name__}: {error}"
        print(probe.result["failure"], file=sys.stderr, flush=True)
    finally:
        probe.finish()
    return 0 if probe.result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
