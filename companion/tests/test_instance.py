import subprocess
import sys
from bookpocket_companion.cli import InstanceGuard

def test_only_one_cli_process_can_recover_a_data_folder(tmp_path):
    first = InstanceGuard(tmp_path)
    command = [sys.executable, "-c", "from pathlib import Path; from bookpocket_companion.cli import InstanceGuard; import sys; g=InstanceGuard(Path(sys.argv[1])); g.close()", str(tmp_path)]
    while_locked = subprocess.run(command, capture_output=True, text=True)
    assert while_locked.returncode != 0
    assert "already running" in while_locked.stderr
    first.close()
    after_release = subprocess.run(command, capture_output=True, text=True)
    assert after_release.returncode == 0, after_release.stderr
