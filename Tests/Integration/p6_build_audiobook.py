"""Run with sonook and four local model directories: LLM, VoiceDesign, VoxCPM2, ASR."""
import json
import os
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

    def invoke(*args, status=0, json_mode=True):
        p = subprocess.run([binary, *args, "--workspace", workspace, *(["--json"] if json_mode else [])],
                           cwd=root, capture_output=True, text=True, timeout=600)
        assert p.returncode == status, (args[:2], p.returncode, p.stderr[-3000:])
        return p

    def run(*args, status=0):
        return json.loads(invoke(*args, status=status).stdout)

    def check_progress(stderr, directory):
        titles = ["导入文本", "本地模型分析", "角色试音定型", "语音合成与质检", "导出音频"]
        positions = [stderr.index(f"[{i}/5] {title}") for i, title in enumerate(titles, 1)]
        assert positions == sorted(positions) and "\x1b" not in stderr
        cards = (directory / "characters.voice-cards.md").read_text().splitlines().count("## Character")
        assert cards > 0
        for label, total in [("试音完成", cards), ("TTS 合成", 1), ("ASR 质检", 1)]:
            assert any(label in line and f"100% ({total}/{total})" in line for line in stderr.splitlines())
        return cards

    alias = root / "input.txt"
    alias.symlink_to(source)
    (root / "version").touch()
    assert "engine_version" in run("version")
    unknown = invoke("foobar", status=2)
    assert unknown.stderr.startswith("Unknown command: foobar\n") and "sonook <file> [options]" in unknown.stderr
    assert "overwrite the source" in run("build", alias, "--name", "重合", "--out", source, status=1)["message"]
    assert "output file" in run("build", source, "--name", "目录", "--out", root, status=1)["message"]
    assert run("project", "list") == []
    options = ["build", alias, "--name", "场间", "--format", "m4b", "--publish", "--out", output,
               "--soundscape", "--seed", "11", "--max-repair-rounds", "0"]
    assert "model register" in run(*options, status=1)["message"]
    sidecar = root / "pause_sonook"
    assert "model register" in run(source, status=1)["message"]
    assert not sidecar.exists() and run("project", "list") == []
    sidecar.touch()
    assert "output directory" in run(source, status=1)["message"]
    sidecar.unlink()
    for destination in [sidecar, sidecar / "verify-report.json", sidecar / "characters.voice-cards.md"]:
        assert "overlap" in run(source, "--out", destination, status=1)["message"]
    assert "immutable workspace assets" in run(source, "--out", workspace / "assets" / "book.wav", status=1)["message"]
    for (kind, provider), path in zip([("llm", "mlx-swift-lm"), ("tts", "qwen3-tts-voice-design"),
                                       ("tts", "voxcpm2-mlx"), ("asr", "qwen3-asr-mlx")], models):
        assert "model register" in run(source, status=1)["message"]
        assert not sidecar.exists() and run("project", "list") == []
        run("model", "register", "--id", provider, "--provider", provider, "--kind", kind, "--path", path)
    sidecar.mkdir()
    for filename in ["pause.m4a", "pause.timeline.json", "characters.voice-cards.md", "verify-report.json"]:
        collision = sidecar / filename
        os.link(source, collision)
        assert "overwrite the source" in run(source, status=1)["message"]
        collision.unlink()
    sidecar.rmdir()
    assert run("project", "list") == []

    quick = invoke(source)
    report = json.loads(quick.stdout)
    assert check_progress(quick.stderr, sidecar) == report["character_count"]
    assert report["status"] == "completed" and report["chapter_count"] == 1
    assert Path(report["output_directory"]) == sidecar
    for field, filename in [(report["export"]["output_path"], "pause.m4a"),
                            (report["export"]["timeline_path"], "pause.timeline.json"),
                            (report["characters_path"], "characters.voice-cards.md"),
                            (report["verify_report_path"], "verify-report.json")]:
        assert Path(field) == sidecar / filename and Path(field).stat().st_size > 0
    assert json.loads(Path(report["verify_report_path"]).read_text())["export_ready"]
    assert "修复第 2/2 轮" in quick.stderr

    plain = invoke(alias, json_mode=False)
    check_progress(plain.stderr, root / "input_sonook")
    for artifact in ["input.m4a", "characters.voice-cards.md", "verify-report.json"]:
        path = root / "input_sonook" / artifact
        assert path.is_file() and str(path) in plain.stdout
    assert "总用时" in plain.stdout and "[1/5]" not in plain.stdout
    custom = run(source, "--name", "试听", "--chapters", "1", "--format", "wav", "--out", root / "sample.wav",
                 "--soundscape", "--publish", "--max-repair-rounds", "0")
    assert Path(custom["output_directory"]) == root / "试听_sonook"
    assert Path(custom["export"]["output_path"]) == root / "sample.wav"
    quick_pack = Path(custom["publication"]["output_path"])
    assert quick_pack.parent.samefile(root / "试听_sonook" / "releases"), quick_pack
    assert run("pack", "verify", quick_pack)["manifest"]["audio_mode"] == "soundscape"

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

    stopped = invoke(source, "--name", "待审核", "--publish", status=3, json_mode=False)
    stopped_dir = root / "待审核_sonook"
    verify = stopped_dir / "verify-report.json"
    blocked_report = json.loads(verify.read_text())
    assert not blocked_report["export_ready"] and blocked_report["blocking_segment_ids"]
    assert all(segment in stopped.stderr for segment in blocked_report["blocking_segment_ids"])
    assert str(verify) in stopped.stderr and "sonook review list" in stopped.stderr
    assert (stopped_dir / "characters.voice-cards.md").is_file()
    assert not (stopped_dir / "待审核.m4a").exists() and not (stopped_dir / "releases").exists()


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit("Usage: p6_build_audiobook.py <sonook> <llm-dir> <voice-design-dir> <voxcpm2-dir> <asr-dir>")
    with tempfile.TemporaryDirectory(prefix="sonook-build-") as directory:
        exercise(Path(sys.argv[1]).resolve(), [Path(p).resolve() for p in sys.argv[2:]], Path(directory).resolve())
    print("P6 audiobook build, publication and blocked review gate passed.")
