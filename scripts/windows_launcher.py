"""Portable GUI launcher; packaged runtime and user-local state only."""
from pathlib import Path
import os
import sys
root = Path(__file__).resolve().parent
os.environ["PATH"] = str(root / "tools") + os.pathsep + os.environ.get("PATH", "")
os.environ["PYTHONUTF8"] = "1"
os.environ["PYTHONNOUSERSITE"] = "1"
if not (root / "tools/ffmpeg.exe").exists():
    message = "Media tools are missing. Run Setup Media.cmd in the Book Pocket folder, then reopen the app."
    if sys.stdout is None:
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, message, "Book Pocket Open", 0x10)
    else: print(message)
    raise SystemExit(1)
from bookpocket_companion.cli import main
sys.argv = [sys.argv[0], "serve", "--studio-dir", str(root / "studio"), "--tray", *sys.argv[1:]]
main()
