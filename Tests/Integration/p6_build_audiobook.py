"""Run with sonook and four local model directories: LLM, VoiceDesign, VoxCPM2, ASR."""
import json
import shlex
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path


def exercise(binary, models, root):
    workspace = root / "author's workspace"
    source = root / "pause.txt"
    # A scene break produces a deterministic pause WAV without relying on ASR transcription accuracy.
    source.write_text("……\n", encoding="utf-8")
    output = root / "scene.m4b"

    def run(*args, status=0):
        p = subprocess.run([binary, *args, "--workspace", workspace, "--json"],
                           capture_output=True, text=True, timeout=600)
        assert p.returncode == status, (args[:2], p.returncode, p.stderr[-3000:])
        return json.loads(p.stdout)

    alias = root / "input.txt"
    alias.symlink_to(source)
    assert "overwrite the source" in run("build", alias, "--name", "重合", "--out", source, status=1)["message"]
    assert "output file" in run("build", source, "--name", "目录", "--out", root, status=1)["message"]
    assert run("project", "list") == []
    options = ["build", alias, "--name", "场间", "--publish", "--out", output,
               "--soundscape", "--seed", "11", "--max-repair-rounds", "0"]
    assert "model register" in run(*options, status=1)["message"]
    for (kind, provider), path in zip([("llm", "mlx-swift-lm"), ("tts", "qwen3-tts-voice-design"),
                                       ("tts", "voxcpm2-mlx"), ("asr", "qwen3-asr-mlx")], models):
        run("model", "register", "--id", provider, "--provider", provider, "--kind", kind, "--path", path)
    built = run(*options)
    assert built["schema_version"] == 1 and built["status"] == "completed" and built["blocking_segment_ids"] == []
    assert Path(built["export"]["output_path"]) == output and output.is_file()
    assert len(built["export"]["verified_m4b"]["chapters"]) == 1
    pack = run("pack", "verify", built["publication"]["output_path"])["manifest"]
    assert pack["project_id"] == built["project_id"] and pack["audio_mode"] == "soundscape"

    # Inject a persisted review verdict after generation in this disposable workspace.
    # The completed DAG alone must never authorize an export or publication.
    with sqlite3.connect(workspace / "sonook.sqlite") as db:
        db.execute("""
            CREATE TRIGGER require_review AFTER UPDATE OF document ON scripts
            WHEN json_extract(NEW.document, '$.segments[0].status') = 'verified'
            BEGIN
                UPDATE scripts SET document = json_set(NEW.document, '$.segments[0].status', 'needs_review')
                WHERE project_id = NEW.project_id AND chapter_id = NEW.chapter_id;
            END
        """)
    blocked_file = root / "blocked.wav"
    blocked = run("build", source, "--name", "复核", "--format", "wav", "--out", blocked_file,
                  "--publish", "--max-repair-rounds", "0", status=3)
    project = blocked["project_id"]
    assert blocked["status"] == "needs_review" and blocked["blocking_segment_ids"]
    assert run("verify", "--project", project, status=3)["blocking_segment_ids"] == blocked["blocking_segment_ids"]
    assert not blocked_file.exists() and run("releases", "list", "--project", project) == []
    commands = [shlex.split(cmd) for cmd in blocked["guidance"]]
    assert [cmd[:3] for cmd in commands] == [["sonook", "review", action] for action in ("list", "retry", "approve-all")]
    for cmd in commands:
        assert cmd[cmd.index("--project") + 1] == project and cmd[cmd.index("--workspace") + 1] == str(workspace)


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit("Usage: p6_build_audiobook.py <sonook> <llm-dir> <voice-design-dir> <voxcpm2-dir> <asr-dir>")
    with tempfile.TemporaryDirectory(prefix="sonook-build-") as directory:
        exercise(Path(sys.argv[1]).resolve(), [Path(p).resolve() for p in sys.argv[2:]], Path(directory).resolve())
    print("P6 audiobook build, publication and blocked review gate passed.")
