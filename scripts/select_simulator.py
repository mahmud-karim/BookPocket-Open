"""Choose installed iPhone simulators; never assume a particular model exists."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def select_device(data, sdk_major, compact=False, exclude=None):
    devices = [dict(d, runtime=runtime) for runtime, ds in data["devices"].items()
               if ".iOS-" + str(sdk_major) + "-" in runtime for d in ds
               if d.get("isAvailable") and d["name"].startswith("iPhone") and d["udid"] != exclude]
    if compact:
        # SE/mini/e are preferred, then standard-sized iPhones. Unknown or larger
        # classes must not silently turn the second pass into another large screen.
        devices = [d for d in devices if re.fullmatch(r"iPhone (?:SE(?: .*)?|\d+(?:e| mini| Pro)?)", d["name"])]
        def order(device):
            name = device["name"]
            tier = 0 if " SE" in name else 1 if " mini" in name else 2 if re.search(r"\de$", name) else 4 if " Pro" in name else 3
            number = re.search(r"iPhone (\d+)", name)
            return tier, int(number[1]) if number else 0, name, device["runtime"], device["udid"]
        devices.sort(key=order)
    else:
        devices.sort(key=lambda d: ("Pro Max" in d["name"], d["name"], d["runtime"], d["udid"]), reverse=True)
    if not devices:
        raise ValueError("No distinct available compact iPhone Simulator matches the selected SDK" if compact else "No available iPhone Simulator found")
    return devices[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compact", action="store_true")
    parser.add_argument("--exclude", help="Exclude the primary simulator UDID")
    parser.add_argument("--report", type=Path, help="Write actual inventory and selection for CI evidence")
    args = parser.parse_args()
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
    try:
        selected = select_device(data, sdk.split(".")[0], args.compact, args.exclude)
    except ValueError as exc:
        parser.exit(1, str(exc) + "\n")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({"sdk": sdk, "compact": args.compact, "excluded": args.exclude,
                                         "selected": selected, "inventory": data}, indent=2) + "\n")
    print(selected["udid"])
    print("Selected " + selected["name"] + " / " + selected["runtime"], file=sys.stderr)


if __name__ == "__main__":
    main()
