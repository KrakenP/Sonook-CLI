"""Exercise installation from a compiled sonook binary or a checkout with a release build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def exercise(source, root):
    repo = Path(__file__).resolve().parents[2]
    binary = source / ".build/release/sonook" if source.is_dir() else source
    binary = binary.resolve(strict=True)
    # Stage a checkout around the supplied build without changing the caller's release directory.
    checkout = root / "checkout"
    scripts = checkout / "scripts"
    scripts.mkdir(parents=True)
    for name in ("install.sh", "uninstall.sh"):
        shutil.copy2(repo / "scripts" / name, scripts / name)
    release = checkout / ".build/release"
    release.mkdir(parents=True)
    (release / "sonook").symlink_to(binary)
    for bundle in binary.parent.glob("*.bundle"):
        (release / bundle.name).symlink_to(bundle, target_is_directory=True)

    home = root / "home"
    home.mkdir()
    workspace = home / "Sonook"
    prefix = root / "local tools"
    installed = prefix / "bin/sonook"
    env = dict(os.environ, HOME=str(home), SONOOK_WORKSPACE=str(workspace))

    def run(*args):
        return subprocess.run(args, env=env, capture_output=True, text=True, check=True, timeout=60).stdout

    install = [scripts / "install.sh", "--prefix", prefix, "--skip-build"]
    uninstall = [scripts / "uninstall.sh", "--prefix", prefix]
    assert "export PATH=" in run(*install)
    assert installed.stat().st_mode & 0o777 == 0o755
    for bundle in binary.parent.glob("*.bundle"):
        if not bundle.name.endswith("Tests.bundle"):
            assert (installed.parent / bundle.name).is_dir()
    for alias in ("--version", "-v", "version"):
        assert run(installed, alias).strip() == "1.0.0"
        assert json.loads(run(installed, alias, "--json")) == {
            "engine_version": "1.0.0", "project": "Sonook", "schema_version": 1
        }
    assert not workspace.exists()
    doctor = json.loads(run(installed, "doctor", "--workspace", workspace, "--json"))
    assert doctor["engine_version"] == "1.0.0" and Path(doctor["workspace_path"]).resolve() == workspace
    assert (workspace / "sonook.sqlite").is_file()
    marker = workspace / "keep.txt"
    marker.write_text("preserve")
    run(*uninstall)
    assert not installed.exists() and marker.read_text() == "preserve" and (workspace / "sonook.sqlite").is_file()
    assert not list(installed.parent.glob("*.bundle"))
    assert "sonook model register" in run(*install, "--init-workspace")
    run(*uninstall, "--purge-workspace")
    assert not workspace.exists()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="sonook-install-") as directory:
        exercise(Path(sys.argv[1]), Path(directory).resolve())
    print("P6 install, version, doctor and uninstall smoke passed.")
