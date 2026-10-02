"""Tests for sim-test.sh, with xcodebuild and xcrun mocked and locks in a temp dir.

Run with: python3 dev/scripts/test_sim_test.py
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("sim-test.sh")
IOS18 = "6E0E6B50-70D1-40D4-A0AD-E2903266BAD1"
IOS27 = "A6E1A97A-06FC-4AF2-BB11-E3118549122E"
IOS27_BOOTED = "BC522296-7945-4DEC-AAB3-EF6A35D69912"
DEVICES = f"""== Devices ==
-- iOS 18.5 --
    iPhone 16 Pro ({IOS18}) (Shutdown)
-- iOS 27.0 --
    iPhone 18 Pro Max ({IOS27}) (Shutdown)
    iPhone 18 Pro Max - Agent 2 ({IOS27_BOOTED}) (Booted)
    iPad Pro 13-inch (M5) (11111111-1111-1111-1111-111111111111) (Booted)
-- watchOS 12.0 --
    Apple Watch Series 11 (46mm) (22222222-2222-2222-2222-222222222222) (Booted)
"""
# A unique sleep, so cleanup can't kill anything else.
DAEMON = "sleep 61.37"
MOCK_XCODEBUILD = f"""import json, os, sys, time
with open(os.environ["CAPTURE"], "a") as output:
    output.write(json.dumps(["xcodebuild"] + sys.argv[1:]) + "\\n")
# Like git fsmonitor--daemon: a detached helper inheriting every open fd.
os.system("{DAEMON} >/dev/null 2>&1 &")
if "-showBuildSettings" in sys.argv:
    print("    BUILT_PRODUCTS_DIR = " + os.environ["PRODUCTS"])
    sys.exit(0)
if "test-without-building" in sys.argv:
    time.sleep(float(os.environ.get("MOCK_SLEEP", "0")))
print("** TEST SUCCEEDED **")
"""
MOCK_XCRUN = """import json, os, sys
if sys.argv[1:3] == ["simctl", "list"]:
    print(os.environ["MOCK_DEVICES"], end="")
    sys.exit(0)
with open(os.environ["CAPTURE"], "a") as output:
    output.write(json.dumps(["xcrun"] + sys.argv[1:]) + "\\n")
"""


class SimTestGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.addCleanup(subprocess.run, ["pkill", "-f", DAEMON])
        self.root = Path(temporary.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "Actuali/Actuali.xcodeproj").mkdir(parents=True)
        (self.root / "sub").mkdir()
        self.locks = self.root / "locks"
        self.gate = self.root / "sim-test.sh"
        self.gate.write_text(
            SCRIPT.read_text()
            .replace("LOCKROOT=/tmp/actuali-sim-locks", f"LOCKROOT={self.locks}")
            .replace("LOG=/tmp/actuali-", f"LOG={self.root}/actuali-")
        )
        binary = self.root / "bin"
        binary.mkdir()
        for name, body in (("xcodebuild", MOCK_XCODEBUILD), ("xcrun", MOCK_XCRUN)):
            (binary / name).write_text(f"#!{sys.executable}\n" + body)
            (binary / name).chmod(0o755)
        self.app = self.root / "products/Actuali.app"
        self.app.mkdir(parents=True)
        plist = str(self.app / "Info.plist")
        subprocess.run(["plutil", "-create", "xml1", plist], check=True)
        subprocess.run(["plutil", "-insert", "CFBundleIdentifier", "-string", "com.mfazz.ActualiOS", plist], check=True)
        self.capture = self.root / "calls.jsonl"
        self.env = dict(
            os.environ,
            PATH=f"{binary}:{os.environ['PATH']}",
            CAPTURE=str(self.capture),
            PRODUCTS=str(self.app.parent),
            MOCK_DEVICES=DEVICES,
            WAIT="0",
            BUILD_SLOTS="1",
        )

    def run_gate(self, *args, **env):
        self.capture.write_text("")
        result = subprocess.run(
            ["bash", str(self.gate), *args], cwd=self.root / "sub", env=dict(self.env, **env),
            capture_output=True, text=True, timeout=30,
        )
        return result, [json.loads(line) for line in self.capture.read_text().splitlines()]

    def start_gate(self, *args, **env):
        return subprocess.Popen(
            ["bash", str(self.gate), *args], cwd=self.root, env=dict(self.env, **env),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )

    def hold(self, *names):
        self.locks.mkdir(exist_ok=True)
        handles = [open(self.locks / f"{name}.lock", "a") for name in names]
        for handle in handles:
            self.addCleanup(handle.close)
            fcntl.flock(handle, fcntl.LOCK_EX)
        return handles

    def held_locks(self):
        held = []
        for path in self.locks.glob("*.lock"):
            with open(path, "a") as handle:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    held.append(path.name)
        return sorted(held)

    def destination_of(self, calls):
        self.assertEqual([call[1] for call in calls], ["build-for-testing", "test-without-building"])
        test = calls[1]
        return test[test.index("-destination") + 1].removeprefix("platform=iOS Simulator,id=")

    def test_takes_first_free_iphone_booted_then_newest(self):
        for target, busy, expected in [
            ("any", (), IOS27_BOOTED),
            ("any", (IOS27_BOOTED,), IOS27),
            ("any", (IOS27_BOOTED, IOS27), IOS18),
            ("ios27", (IOS27_BOOTED,), IOS27),
            ("ios18", (), IOS18),
        ]:
            with self.subTest(target=target, busy=busy):
                handles = self.hold(*busy)
                result, calls = self.run_gate(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.destination_of(calls), expected)
                for handle in handles:
                    handle.close()
        # The mock daemons are still alive, and must not be holding anything.
        self.assertEqual(self.held_locks(), [])

    def test_skips_ui_tests_unless_named(self):
        for args, skipped in [((), True), (("-only-testing:ActualiUITests/SearchUITests",), False)]:
            with self.subTest(args=args):
                result, calls = self.run_gate("ios18", *args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for call in calls:
                    self.assertEqual("-skip-testing:ActualiUITests" in call, skipped, call)

    def test_busy_simulator_times_out_naming_holder(self):
        self.hold(IOS18)
        (self.locks / f"{IOS18}.owner").write_text("pid 1 in /elsewhere\n")
        result, calls = self.run_gate("ios18")
        self.assertEqual(result.returncode, 75)
        self.assertIn("pid 1 in /elsewhere", result.stdout)
        self.assertEqual(calls[-1][1], "build-for-testing")

    def test_rejects_bad_targets_and_destination(self):
        for args in (["ipad"], ["ios99"], ["ios27", "-destination", f"id={IOS18}"]):
            with self.subTest(args=args):
                result, calls = self.run_gate(*args)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertEqual(calls, [])

    def test_one_invocation_per_checkout(self):
        first = self.start_gate("ios18", MOCK_SLEEP="3")
        time.sleep(1)
        result, _ = self.run_gate("ios27")
        self.assertEqual(result.returncode, 75)
        self.assertIn("WORKTREE BUSY", result.stdout)
        first.wait(timeout=10)

    def test_sigkilled_wrapper_keeps_locks_until_xcodebuild_exits(self):
        wrapper = self.start_gate("ios18", MOCK_SLEEP="3")
        time.sleep(1)
        wrapper.send_signal(signal.SIGKILL)
        wrapper.wait()
        self.assertEqual(len(self.held_locks()), 2)  # worktree + simulator
        self.assertIn(f"{IOS18}.lock", self.held_locks())
        time.sleep(3)
        self.assertEqual(self.held_locks(), [])

    def test_run_launches_demo_data_and_holds_simulator_for_driver(self):
        probe = self.root / "probe"
        driver = (
            f'echo "$UDID $BUNDLE_ID" >{probe}; exec 9>>{self.locks}/"$UDID".lock; '
            f'lockf -s -t 0 9; echo "rc=$?" >>{probe}; {DAEMON} >/dev/null 2>&1 &'
        )
        result, calls = self.run_gate("run", "ios27", "bash", "-c", driver)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls[0][1], "build")
        self.assertEqual(calls[0][calls[0].index("-configuration") + 1], "Debug")
        self.assertIn(["xcrun", "simctl", "install", IOS27_BOOTED, str(self.app)], calls)
        self.assertIn(
            ["xcrun", "simctl", "launch", "--terminate-running-process", IOS27_BOOTED,
             "com.mfazz.ActualiOS", "-loadDemoData"],
            calls,
        )
        # The driver saw its simulator locked (75 = EX_TEMPFAIL), and its
        # backgrounded helper didn't keep the lock once the driver exited.
        self.assertEqual(probe.read_text().splitlines(), [f"{IOS27_BOOTED} com.mfazz.ActualiOS", "rc=75"])
        self.assertEqual(self.held_locks(), [])

    def test_run_without_driver_releases_after_launch(self):
        result, _ = self.run_gate("run", "ios18")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("simulator released", result.stdout)
        self.assertEqual(self.held_locks(), [])


if __name__ == "__main__":
    unittest.main()
