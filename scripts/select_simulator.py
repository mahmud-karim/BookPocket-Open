import json
import subprocess
import sys

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
sdk_major = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip().split(".")[0]
devices = [dict(d, runtime=runtime) for runtime, ds in data["devices"].items() if ".iOS-" + sdk_major + "-" in runtime for d in ds if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not devices:
    raise SystemExit("No available iPhone Simulator found")
devices.sort(key=lambda d: ("Pro Max" in d["name"], d["name"]), reverse=True)
print(devices[0]["udid"])
print("Selected " + devices[0]["name"] + " / " + devices[0]["runtime"], file=sys.stderr)
