"""Bound cold-boot retries on the disposable GitHub simulator only."""
import subprocess
import sys

device = sys.argv[1]
for attempt in range(1, 4):
    print(f"Simulator boot attempt {attempt}/3", flush=True)
    try:
        # bootstatus -b boots an unbooted device and waits for readiness.
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, timeout=180)
        break
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        if attempt == 3:
            raise
        print("Cold boot stalled; shutting down this test simulator before retry.", flush=True)
        try:
            subprocess.run(["xcrun", "simctl", "shutdown", device], timeout=20, check=False)
        except subprocess.TimeoutExpired:
            pass
