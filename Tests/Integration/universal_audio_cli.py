"""Run against a built sonook binary: python3 Tests/Integration/universal_audio_cli.py .build/debug/sonook"""
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import wave


def exercise(binary, root):
    workspace = root / "workspace"

    def command(*args, status=0):
        result = subprocess.run([binary, *map(str, args), "--workspace", workspace, "--json"],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == status, (args, result.returncode, result.stderr, result.stdout)
        return json.loads(result.stdout)

    for args in [("doctor", "-h"), ("soundscape", "library", "scan", "--help"), ("podcast", "--help", "plan")]:
        help_text = subprocess.run([binary, *args], env=dict(os.environ, SONOOK_WORKSPACE=str(workspace)),
                                   capture_output=True, text=True, check=True)
        assert "sonook podcast plan" in help_text.stderr + help_text.stdout and not workspace.exists()
    assert command("version") == {"engine_version": "1.0.0", "project": "Sonook", "schema_version": 1}
    assert not workspace.exists()
    project = command("project", "create", "--name", "Studio")["project_id"]

    def run(*args, status=0):
        return command(*args, "--project", project, status=status)

    book = root / "book.txt"
    book.write_text("第一章 春天\n树木发芽了。\n", encoding="utf8")
    imported = run("import", book)["chapters"]
    first_episode = max(c["chapter_number"] for c in imported) + 1
    source = root / "notes.txt"
    source.write_text("窗外下着小雨，远处传来一阵敲门声。", encoding="utf8")
    ingested = run("podcast", "ingest", source, "--title", "观察笔记")
    assert run("podcast", "sources") == [ingested]
    hit = run("podcast", "search", "--query", "小雨", "--limit", 1)[0]
    assert hit["chunk"]["source_id"] == ingested["source_id"]

    def episode(id_, **kwargs):
        return run("podcast", "plan", "--episode", id_, "--topic", "小雨", "--title", id_, **kwargs)

    one = episode("first")
    assert one["chapter_number"] == first_episode
    assert one["plan"]["citations"][0]["chunk_id"] == hit["chunk"]["chunk_id"]
    db = sqlite3.connect(workspace / "sonook.sqlite")
    cast = run("character", "list")
    host = cast["cards"][0]
    host.update(locked=True, canonical_name="我的主讲")
    db.execute("UPDATE voice_catalogs SET document=? WHERE project_id=?", (json.dumps(cast), project))
    db.commit()
    two = episode("second")  # Identical source digest, distinct chapter.
    dual = run("podcast", "plan", "--episode", 'two"hosts', "--topic", "小雨", "--format", "dual", "--lexical-only", "--seed", 17)
    assert dual["plan"]["host_speaker_ids"] == ["host_a", "host_b"]
    assert run("character", "list")["cards"][0] == host
    assert two["chapter_number"] == first_episode + 1 and dual["chapter_number"] == first_episode + 2
    assert len(run("chapter", "list")) == len(imported) + 3
    assert episode("first")["chapter_number"] == first_episode
    assert "error" == episode(imported[-1]["chapter_id"], status=1)["status"]
    chapters = ["--chapters", first_episode]
    blocked = run("verify", *chapters, status=3)
    assert not blocked["export_ready"]
    report = run("soundscape", "plan", *chapters, "--lexical-only")
    assert report["chapter_count"] == 1 and report["total_sfx_cues"] > 0
    denied = subprocess.run([binary, "drama", "adapt", *map(str, chapters), "--workspace", workspace,
                             "--project", project, "--json"], capture_output=True, text=True)
    assert denied.returncode != 0 and "--authorize" in denied.stderr and json.loads(denied.stdout)["status"] == "error"
    drama = run("drama", "adapt", *chapters, "--authorize", "--note", "fixture", "--lexical-only")
    script = run("script", "show", "--chapter", "first")[0]
    plan = run("soundscape", "list")[0]
    assert script["script_revision"] == plan["script_revision"] == drama["chapters"][0]["script_revision"] == 2
    assert drama["authorization"]["audit_note"] == "fixture"
    for model, kind in [("tts", "tts"), ("asr", "asr")]:
        command("model", "register", "--id", model, "--kind", kind, "--provider", "fixture", "--path", root)
    generation = run("generate", "--chapters", dual["chapter_number"])
    nodes = [n for n in generation["nodes"] if n["kind"] == "mlx_book_tts_segment"]
    assert all(json.loads(n["payload_json"])["chapter_id"] == 'two"hosts' for n in nodes)
    assert len(nodes) == len(dual["plan"]["script_document"]["segments"])

    # Supply a deterministic, locally generated dry fixture at the real verification/export boundary.
    fixture = root / "tone.wav"
    with wave.open(str(fixture), "wb") as wav:
        wav.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
        wav.writeframes(b"".join(struct.pack("<h", int(5000 * math.sin(i / 14))) for i in range(9600)))
    digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
    dry = workspace / "assets" / "segment_wav" / f"{digest}.wav"
    dry.parent.mkdir()
    shutil.copyfile(fixture, dry)
    record = dict(schema_version=1, asset_id="fixture", project_id=project, kind="segment_wav",
                  relative_path=str(dry.relative_to(workspace)), file_extension="wav", file_sha256=digest,
                  byte_size=dry.stat().st_size, sample_rate=24000, frame_count=9600, provenance={},
                  created_at="2026-01-01T00:00:00Z")
    db.execute("INSERT INTO assets VALUES (?,?,?,?)", ("fixture", project, record["relative_path"], json.dumps(record)))
    for id_ in ("first", "second"):
        script = json.loads(db.execute("SELECT document FROM scripts WHERE chapter_id=?", (id_,)).fetchone()[0])
        for seg in script["segments"]:
            seg.update(audio_artifact_id=record["asset_id"], status="verified")
        db.execute("UPDATE scripts SET document=? WHERE project_id=? AND chapter_id=?", (json.dumps(script), project, id_))
    db.commit()
    assert run("verify", *chapters)["export_ready"]
    library = root / "library"
    (library / "sfx").mkdir(parents=True)
    effect = library / "sfx" / "door-knock.wav"
    shutil.copyfile(dry, effect)
    audit = command("soundscape", "library", "scan", library, "--write-manifest")
    assert audit["license_audit"][0]["classification"] == "cc0" and (library / "manifest.json").exists()
    selection = ["--chapters", f"{first_episode}-{first_episode + 1}"]
    export = run("export", "--format", "m4b", *selection, "--soundscape", "--sound-library", library)
    output = Path(export["output_path"])
    assert output.parent.name == "audiobooks" and output.name.endswith("_soundscape.m4b")
    assert export["ambient_mixed"] and [ch["title"] for ch in export["verified_m4b"]["chapters"]] == ["first", "second"]
    assert run("verify", *selection, "--m4b", output)["export_ready"]
    assert json.loads(Path(export["timeline_path"]).read_text())["render_fingerprint"] == export["render_fingerprint"]
    assert {p["chapter_id"] for p in run("soundscape", "list")} == {"first", "second"}
    assert hashlib.sha256(dry.read_bytes()).hexdigest() == digest

    # The helper receives a local request. A later CLI process can resolve its asset without the helper.
    helper = root / "helper"
    helper.write_text('''#!/bin/sh
cp "$(dirname "$0")/tone.wav" output.wav
echo '{"schema_version":1}' > metadata.json
''')
    helper.chmod(0o700)
    generated = run("export", "--format", "wav", *chapters, "--soundscape", "--sfx-helper", helper, "--sfx-license", "CC0-1.0")
    helper.unlink()
    cached = run("export", "--format", "wav", *chapters, "--soundscape")
    assert generated["ambient_mixed"] and cached["render_fingerprint"] == generated["render_fingerprint"]
    effect.write_bytes(b"changed")
    assert command("soundscape", "library", "scan", library, status=1)["status"] == "error"
    run("export", "--format", "wav", *chapters, "--soundscape", "--sound-library", library, status=1)
    run("export", "--format", "wav", *chapters, "--soundscape", "--out", dry, status=1)
    assert hashlib.sha256(dry.read_bytes()).hexdigest() == digest
    book.write_text("第一章 春天\n树木发芽了。\n第二章 夏天\n树叶更绿了。", encoding="utf8")
    run("import", book)
    roster = run("chapter", "list")
    assert len(roster) == len({c["chapter_number"] for c in roster})
    assert next(c["chapter_number"] for c in roster if c["chapter_id"] == "first") == first_episode
    db.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        exercise(str(Path(sys.argv[1]).resolve()), Path(directory))
    print("Universal audio CLI integration passed.")
