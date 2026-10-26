#!/usr/bin/env python3
"""Exercise the real wrapper with a fake CLI; no Xcode, simulator, or network work."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASH = os.environ.get("YUEDU_WRAPPER_BASH", "bash")
with tempfile.TemporaryDirectory(prefix="yuedu-xctest-wrapper-") as temporary:
    directory = Path(temporary).resolve()
    fake = directory / "xcodebuild"
    fake.write_text('''#!/bin/bash
# The wrapper's module-copy check needs settings, not a second test invocation.
for arg in "$@"; do
  if [[ "$arg" == -showBuildSettings ]]; then echo '[]'; exit 0; fi
done
case "$YUEDU_WRAPPER_FIXTURE" in
  success)
    echo "Background service failed to fetch account"
    echo "Test run with 6 tests in 1 suite passed"
    echo "** TEST SUCCEEDED **"
    exec sleep 30 ;;
  nonzero)
    echo "Test run with 6 tests in 1 suite passed"
    echo "** TEST SUCCEEDED **"
    exit 65 ;;
  zero)
    echo "Test run with 0 tests in 0 suites passed"
    echo "** TEST SUCCEEDED **"
    exit 0 ;;
  failure)
    echo "Test run with 2 tests in 1 suite failed"
    echo "** TEST FAILED **"
    exec sleep 30 ;;
  execute_success)
    echo "Executed 1 test, with 0 failures (0 unexpected)"
    echo "** TEST EXECUTE SUCCEEDED **"
    exec sleep 30 ;;
  execute_failure)
    echo "Executed 1 test, with 1 failure (1 unexpected)"
    echo "** TEST EXECUTE FAILED **"
    exec sleep 30 ;;
  execute_nonzero)
    echo "Executed 1 test, with 0 failures (0 unexpected)"
    echo "** TEST EXECUTE SUCCEEDED **"
    exit 65 ;;
  execute_zero)
    echo "Executed 0 tests, with 0 failures (0 unexpected)"
    echo "** TEST EXECUTE SUCCEEDED **"
    exit 0 ;;
  missing) echo "Exited without a verdict"; exit 0 ;;
  timeout) exec sleep 30 ;;
esac
''')
    fake.chmod(0o755)
    sentinel = subprocess.Popen([BASH, "-c", "exec -a 'xcodebuild test unrelated-fixture' sleep 120"])
    try:
        for case, expected in [("success", 0), ("failure", 1), ("missing", 1), ("timeout", 1), ("nonzero", 1), ("zero", 1),
                               ("execute_success", 0), ("execute_failure", 1), ("execute_nonzero", 1), ("execute_zero", 1)]:
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                       DEVELOPER_DIR="fixture", YUEDU_DEST="fixture",
                       YUEDU_WRAPPER_FIXTURE=case,
                       YUEDU_TEST_ACTION="test-without-building" if case.startswith("execute_") else "test")
            result = subprocess.run([BASH, (ROOT / "scripts/xctest.sh").as_posix(), "-l", (directory / (case + ".log")).as_posix(),
                                     "-t", "1" if case == "timeout" else "30"],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=40)
            assert result.returncode == expected, (case, result.returncode, result.stdout)
            assert sentinel.poll() is None, "Wrapper terminated another test process"
            print(f"PASS {case}: exit={expected}; unrelated process preserved")
    finally:
        sentinel.terminate()
        sentinel.wait(timeout=5)
