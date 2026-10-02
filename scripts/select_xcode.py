import os
import pathlib
import re

candidates = []
for app in pathlib.Path("/Applications").glob("Xcode*.app"):
    match = re.search(r"Xcode[_-](\d+(?:\.\d+)*)", app.name)
    if match and "beta" not in app.name.lower():
        candidates.append((tuple(map(int, match.group(1).split("."))), app))
if not candidates:
    raise SystemExit("No versioned stable Xcode installation found")
version, app = max(candidates)
developer = app / "Contents/Developer"
with open(os.environ["GITHUB_ENV"], "a") as handle:
    handle.write("DEVELOPER_DIR=" + str(developer) + "\n")
print("Selected", app.name)
