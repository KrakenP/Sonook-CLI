"""Exercise a built sonook CLI and its real loopback HTTP/SSE service without installed models."""
import hashlib
import http.client
import io
import json
import math
import os
from contextlib import closing, contextmanager
from pathlib import Path
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import wave


DATE = "2026-01-01T00:00:00Z"
CHAPTERS = [
    ("第一章 溪边", "lin", "林风", ["林风在溪边露营。", "他支起帐篷，听着流水。"]),
    ("第二章 古塔", "xuan", "玄冥", ["反派玄冥在古塔现身。", "塔门在他身后合拢。"]),
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def wav_asset(db, workspace, project, number):
    rate, frames = 24000, 12000
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        audio.writeframes(b"".join(struct.pack("<h", int(4000 * math.sin(i * number / 20))) for i in range(frames)))
    data = buffer.getvalue()
    digest = sha256(data)
    path = Path("assets", "segment_wav", digest + ".wav")
    target = workspace / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    asset = dict(schema_version=1, asset_id=f"audio-{number}", project_id=project, kind="segment_wav",
                 relative_path=str(path), file_extension="wav", file_sha256=digest, byte_size=len(data),
                 sample_rate=rate, frame_count=frames, provenance={}, created_at=DATE)
    db.execute("INSERT INTO assets(asset_id, project_id, relative_path, document) VALUES (?,?,?,?)",
               (asset["asset_id"], project, str(path), json.dumps(asset)))
    return asset


def seed(run, root, workspace, project):
    book = root / "book.txt"
    book.write_text("".join("\n".join([title, *lines]) + "\n" for title, _, _, lines in CHAPTERS), encoding="utf8")
    chapters = run("import", book, "--project", project)["chapters"]
    assert [c["chapter_number"] for c in chapters] == [1, 2]
    text = book.read_bytes()
    cards = []
    with closing(sqlite3.connect(workspace / "sonook.sqlite")) as db, db:
        for chapter, (_, speaker, name, lines) in zip(chapters, CHAPTERS):
            n, chapter_id = chapter["chapter_number"], chapter["chapter_id"]
            revision = chapter["source_document_revision"]
            asset = wav_asset(db, workspace, project, n)
            segments = []
            for index, line in enumerate(lines):
                start = text.index(line.encode())
                span = dict(unit="utf8_byte", start=start, end_exclusive=start + len(line.encode()))
                segments.append(dict(schema_version=1, segment_id=f"seg-{n}-{index}", chapter_id=chapter_id,
                                     source_document_revision=revision, script_revision=1, source_span=span,
                                     source_text=line, spoken_text=line, speaker_id=speaker, voice_profile_revision="1",
                                     audio_artifact_id=asset["asset_id"], direction={"pause_after_ms": 100},
                                     status="needs_review" if n == 2 and index == 1 else "verified"))
            script = dict(schema_version=1, chapter_id=chapter_id, source_document_revision=revision,
                          script_revision=1, segments=segments)
            db.execute("INSERT INTO scripts(project_id, chapter_id, document) VALUES (?,?,?)",
                       (project, chapter_id, json.dumps(script)))
            state = dict(character_id=speaker, canonical_name=name, status_summary=lines[0], relationships=[], last_seen_chapter=n)
            memory = dict(schema_version=1, project_id=project, chapter_id=chapter_id, chapter_number=n,
                          source_document_revision=revision, summary=lines[0], active_character_ids=[speaker],
                          character_states=[state], open_threads=[], created_at=DATE)
            db.execute("INSERT INTO chapter_memories(project_id,chapter_id,chapter_number,document) VALUES (?,?,?,?)",
                       (project, chapter_id, n, json.dumps(memory)))
            anchor = dict(anchor_id=f"private-anchor-{n}", asset_id=asset["asset_id"], file_sha256=asset["file_sha256"],
                          generator_provider_id="fixture", generator_model_id="fixture", design_prompt="fixture",
                          audition_text="fixture", sample_rate=asset["sample_rate"], created_at=DATE)
            cards.append(dict(schema_version=1, character_id=speaker, canonical_name=name, timbre_anchor=anchor,
                              voice_design_prompt=str(workspace / asset["relative_path"])))
        catalog = dict(schema_version=1, project_id=project, revision=1, cards=cards)
        db.execute("INSERT INTO voice_catalogs(project_id,document) VALUES (?,?)", (project, json.dumps(catalog)))
    return chapters


def publish(run, workspace, root, project):
    def book(*args, **kwargs):
        return run("publish", "--project", project, *args, **kwargs)

    assert "seg-2-1" in book(status=1)["message"]
    assert not run("releases", "list")
    run("segment", "approve", "seg-2-1", "--project", project, "--note", "Fixture WAV reviewed")
    report = book("--title", "溪边/古塔", "--author", "测试作者", "--narrator", "测试旁白")
    record = report["release"]
    relative = Path("outputs", f"测试书__{project}", "releases", "溪边-古塔_v1.audiopack")
    pack = workspace / relative
    assert Path(record["pack_relative_path"]) == relative and Path(report["output_path"]).samefile(pack)
    manifest = run("pack", "verify", pack)["manifest"]
    assert manifest["release_version"] == 1 and manifest["audio_mode"] == "dry"
    assert len(manifest["chapters"]) == 2 and record["manifest_sha256"] == sha256((pack / "manifest.json").read_bytes())
    cast = json.loads((pack / "characters.json").read_bytes())
    assert [c["canonical_name"] for c in cast] == ["林风", "玄冥"]
    for card in cast:
        assert set(card) == {"character_id", "canonical_name", "aliases", "persona_summary", "first_appeared_chapter"}
    for entry in manifest["chapters"]:
        transcript = json.loads((pack / entry["transcript_relative_path"]).read_bytes())
        assert [(s["start_ms"], s["end_ms"]) for s in transcript["segments"]] == [(0, 500), (600, 1100)]

    alias = root / "assets-alias"
    alias.symlink_to(workspace / "assets", target_is_directory=True)
    assert book("--out", alias / "missing" / "book.audiopack", status=1)["status"] == "error"
    assert not (workspace / "assets/missing").exists()

    # A portable export outside the workspace also has an independently servable, immutable local release.
    external = root / "portable.audiopack"
    second = book("--out", external, "--chapters", "1", "--soundscape")["release"]
    checked = run("pack", "verify", external)["manifest"]
    assert checked["release_version"] == 2 and checked["audio_mode"] == "soundscape" and len(checked["chapters"]) == 1
    assert checked == run("pack", "verify", workspace / second["pack_relative_path"])["manifest"]
    # A corrupt portable copy does not change the server's release.
    (external / "chapters/001.m4a").write_bytes(b"broken")
    assert run("pack", "verify", external, status=1)["status"] == "error"
    assert book("--out", external, status=1)["status"] == "error"
    assert run("releases", "list", "--project", project) == [second, record]
    return record, manifest


def podcast_references(run, root, workspace):
    project = run("project", "create", "--name", "观察笔记", "--type", "podcast")["project_id"]
    notes = root / "notes.md"
    notes.write_text("溪边的水位在清晨上升。", encoding="utf8")
    run("podcast", "ingest", notes, "--project", project)
    episode = run("podcast", "plan", "--project", project, "--episode", "morning",
                  "--topic", "水位", "--lexical-only")["plan"]
    with closing(sqlite3.connect(workspace / "sonook.sqlite")) as db, db:
        asset = wav_asset(db, workspace, project, 3)
        script = episode["script_document"]
        for segment in script["segments"]:
            segment.update(status="verified", audio_artifact_id=asset["asset_id"])
        db.execute("UPDATE scripts SET document=? WHERE project_id=? AND chapter_id=?",
                   (json.dumps(script), project, episode["episode_id"]))
    pack = Path(run("publish", "--project", project)["output_path"])
    manifest = run("pack", "verify", pack)["manifest"]
    assert manifest["production_mode"] == "private_podcast" and "references.json" in manifest["optional_files"]
    assert episode["citations"] and json.loads((pack / "references.json").read_bytes()) == episode["citations"]


@contextmanager
def serving(binary, workspace, root):
    ready = root / "ready.json"
    with (root / "server.log").open("w+") as log, subprocess.Popen(
        [binary, "serve", "--workspace", workspace, "--host", "127.0.0.1", "--port", "0",
         "--ready-file", ready, "--json"], stdout=subprocess.PIPE, stderr=log, text=True
    ) as process:
        try:
            deadline = time.monotonic() + 15
            while not ready.exists():
                assert process.poll() is None, "Server exited before signalling readiness"
                assert time.monotonic() < deadline, "Timed out waiting for the listener"
                time.sleep(0.02)
            endpoint = json.loads(ready.read_bytes())
            assert endpoint["host"] == "127.0.0.1" and 0 < endpoint["port"] <= 65535
            assert endpoint["url"] == f"http://127.0.0.1:{endpoint['port']}"
            yield endpoint["port"]
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            try:
                stdout, _ = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise AssertionError("Server did not stop on SIGTERM")
        assert process.returncode == 0 and json.loads(stdout) == endpoint


class Client:
    def __init__(self, port):
        self.port = port
        self.token = None

    @contextmanager
    def response(self, path, body=None, status=(200,), headers=None):
        fields = dict(headers or {})
        if self.token:
            fields["Authorization"] = f"Bearer {self.token}"
        if body is not None:
            fields["Content-Type"] = "application/json"
            if not isinstance(body, bytes):
                body = json.dumps(body).encode()
        with closing(http.client.HTTPConnection("127.0.0.1", self.port, timeout=8)) as connection:
            connection.request("GET" if body is None else "POST", "/v1/" + path, body=body, headers=fields)
            with connection.getresponse() as response:
                assert response.status in status, (path, response.status, status)
                yield response

    def json(self, path, body=None):
        with self.response(path, body) as response:
            return json.load(response)


def downloads(client, record, manifest):
    base = "releases/" + record["release_id"]
    assert record in client.json("releases") and client.json(base + "/manifest") == manifest
    for chapter in manifest["chapters"]:
        path = f"{base}/files/{chapter['audio_relative_path']}"
        size = chapter["byte_size"]
        split = size // 2
        chunks = []
        headers = {}
        for start, end in [(0, split - 1), (split, size - 1)]:
            headers["Range"] = f"bytes={start}-{end}"
            with client.response(path, headers=headers, status=(206,)) as response:
                assert response.getheader("Content-Range") == f"bytes {start}-{end}/{size}"
                headers["If-Range"] = response.getheader("ETag")
                chunks.append(response.read())
                assert len(chunks[-1]) == end - start + 1
        assert sha256(b"".join(chunks)) == chapter["file_sha256"]
    with client.response(base + "/files/%2e%2e/secret", status=(400, 403)):
        pass


def sync(client, run, root, project, release, chapter, device):
    assert run("sync", "cursor", "--project", project) is None
    batch = []
    for seq, (kind, position) in enumerate([("play", 0), ("progress", 900), ("rewind", 200)], 1):
        batch.append(dict(schema_version=1, device_id=device, event_id=f"event-{seq}", project_id=project,
                          release_id=release, chapter_id=chapter, segment_id="seg-1-1" if position >= 600 else "seg-1-0",
                          position_ms=position, device_sequence=seq, occurred_at=f"2026-01-01T00:00:0{seq}Z", event_type=kind))
    offline = root / "offline.json"
    offline.write_text(json.dumps(batch))
    payload = offline.read_bytes()
    with client.response("events") as stream:
        assert stream.getheader("Content-Type") == "text/event-stream"
        assert stream.readline() == b": connected\n" and stream.readline() == b"\n"
        result = client.json("sync/events", payload)
        assert result["accepted_count"] == len(batch) and result["rewind_preserved_count"] == 1
        assert stream.readline() == b"event: playback_synced\n"
        data = stream.readline()
        assert data.startswith(b"data: ") and json.loads(data[6:])["accepted_count"] == len(batch)
        assert stream.readline() == b"\n"
        replay = client.json("sync/events", payload)
        assert replay["duplicate_count"] == len(batch) and replay["accepted_count"] == 0
    cursor = client.json(f"sync/cursor?project_id={project}")
    assert cursor == result["cursor"] == replay["cursor"] and cursor["last_event_type"] == "rewind" and cursor["position_ms"] == 200
    assert run("sync", "push", "--file", offline) == replay
    assert run("sync", "cursor", "--project", project) == cursor
    return cursor


def context(client, run, project, cursor):
    request = dict(project_id=project, max_chapter_number=1, query="玄冥在哪里？", allow_spoilers=False)
    for answer in [client.json("context/query", request),
                   run("context", "query", "--project", project, "--chapter", 1, "--query", request["query"], "--lexical-only")]:
        assert answer["withheld_future_chapters"] == 1 and answer["spoiler_filter_triggered"] and answer["resume_anchor"] == cursor
        visible = json.dumps(answer, ensure_ascii=False)
        assert all(word not in visible for word in ["玄冥", "古塔", "反派", "塔门"])
        assert "林风" in answer["answer"] and all(e["chapter_number"] == 1 for e in answer["evidence"])
    answer = client.json("context/query", dict(request, allow_spoilers=True))
    assert answer["withheld_future_chapters"] == 0 and "玄冥" in answer["answer"]
    assert any(e["chapter_number"] == 2 and "古塔" in e["excerpt"] for e in answer["evidence"])


def exercise(binary, root):
    workspace = root / "workspace"

    def run(*args, status=0):
        result = subprocess.run([binary, *map(str, args), "--workspace", workspace, "--json"],
                                capture_output=True, text=True, timeout=45)
        assert result.returncode == status, (args[:2], result.returncode, result.stderr)
        value = json.loads(result.stdout)
        if args[:2] == ("server", "pair-code"):
            assert value["code"] not in result.stderr
        return value

    for cmd in ["publish", "pack verify", "releases list", "sync push", "sync cursor", "context query",
                "server pair-code", "server devices", "server revoke", "serve"]:
        result = subprocess.run([binary, *cmd.split(), "--help"], capture_output=True, text=True, check=True,
                                env=dict(os.environ, SONOOK_WORKSPACE=str(workspace)))
        assert f"sonook {cmd}" in result.stderr and not workspace.exists()
    project = run("project", "create", "--name", "测试书")["project_id"]
    chapters = seed(run, root, workspace, project)
    record, manifest = publish(run, workspace, root, project)
    podcast_references(run, root, workspace)
    pairing = run("server", "pair-code")
    with serving(binary, workspace, root) as port:
        client = Client(port)
        health = client.json("health")
        assert health["status"] == "ok" and health["host_mode"] == "loopback"
        assert health["engine_version"] == "1.0.0"
        confirmation = dict(challenge_id=pairing["challenge_id"], code=pairing["code"], device_name="Test Player")
        receipt = client.json("pair/confirm", confirmation)
        with client.response("pair/confirm", confirmation, status=(401, 409)):
            pass
        client.token = receipt["bearer_token"]
        device = receipt["device"]["device_id"]
        devices = run("server", "devices")
        assert devices[0]["device_id"] == device and "token_hash_sha256" not in devices[0]
        downloads(client, record, manifest)
        cursor = sync(client, run, root, project, record["release_id"], chapters[0]["chapter_id"], device)
        context(client, run, project, cursor)
        assert run("server", "revoke", device)["revoked"]
        with client.response("releases", status=(401,)):
            pass
    log = (root / "server.log").read_text()
    assert "Listening on http://127.0.0.1:" in log and client.token not in log and pairing["code"] not in log


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="sonook-p5-") as directory:
        exercise(str(Path(sys.argv[1]).resolve()), Path(directory))
    print("P5 publish, verification and all 8 live server checks passed.")
