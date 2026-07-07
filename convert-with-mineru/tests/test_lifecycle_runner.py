from __future__ import annotations

import io
import importlib
import json
import os
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path


FAKE_TOKEN = "secret-token-never-write"
SOURCE_ID = "src_0123456789ab_cafefeed"
HTML_SOURCE_ID = "src_aaaaaaaaaaaa_bbbbbbbb"
PENDING_STUB = f"# {SOURCE_ID}\n\nMinerU processing pending - file not yet parsed."

Json = str | int | bool | None | list["Json"] | dict[str, "Json"]
pytest = importlib.import_module("pytest")


@dataclass(frozen=True, slots=True)
class ApiCall:
    method: str
    target: str
    payload: dict[str, Json] | None = None
    body: bytes | None = None
    headers: dict[str, str] | None = None


@dataclass(slots=True)  # noqa: MUTABLE_OK - fake records calls across a run.
class FakePrecisionApi:
    upload_batches: list[dict[str, Json]] = field(default_factory=list)
    poll_batches: list[dict[str, Json]] = field(default_factory=list)
    zip_by_url: dict[str, bytes] = field(default_factory=dict)
    calls: list[ApiCall] = field(default_factory=list)
    _upload_index: int = 0
    _poll_index: int = 0

    def post_json(
        self, target: str, payload: dict[str, Json], headers: dict[str, str]
    ) -> dict[str, Json]:
        self.calls.append(ApiCall("POST", target, payload=payload, headers=headers))
        response = self.upload_batches[self._upload_index]
        self._upload_index += 1
        return response

    def put_bytes(self, target: str, body: bytes) -> None:
        self.calls.append(ApiCall("PUT", target, body=body))

    def get_json(self, target: str, headers: dict[str, str]) -> dict[str, Json]:
        self.calls.append(ApiCall("GET", target, headers=headers))
        if not self.poll_batches:
            return {"code": 0, "msg": "ok", "data": {"extract_result": []}}
        response = self.poll_batches[min(self._poll_index, len(self.poll_batches) - 1)]
        self._poll_index += 1
        return response

    def get_bytes(self, target: str) -> bytes:
        self.calls.append(ApiCall("GET_BYTES", target))
        return self.zip_by_url[target]


@dataclass(frozen=True, slots=True)
class RunInput:
    tmp_path: Path
    sources: list[tuple[str, Path]]
    client: FakePrecisionApi
    token: str = FAKE_TOKEN
    max_poll_seconds: int = 0
    poll_interval_seconds: int = 0


def _run_lifecycle(run: RunInput):
    module = importlib.import_module("scripts.mineru_lifecycle_runner")

    config = module.LifecycleRunConfig(
        sources=[module.LifecycleSource(source_id=source_id, path=path) for source_id, path in run.sources],
        output_root=run.tmp_path / "out",
        audit_dir=run.tmp_path / "audit",
        state_path=run.tmp_path / "audit" / "lifecycle-state.jsonl",
        token=run.token,
        client=run.client,
        max_poll_seconds=run.max_poll_seconds,
        poll_interval_seconds=run.poll_interval_seconds,
    )
    return module.run_lifecycle(config)


def _source(tmp_path: Path, source_id: str = SOURCE_ID, name: str = "report.pdf") -> tuple[str, Path]:
    path = tmp_path / name
    path.write_bytes(b"%PDF-1.7")
    return source_id, path


def _many_sources(tmp_path: Path, count: int) -> list[tuple[str, Path]]:
    sources: list[tuple[str, Path]] = []
    for index in range(count):
        source_id = f"src_{index:012x}_{index:08x}"
        sources.append(_source(tmp_path, source_id, f"doc-{index:02d}.pdf"))
    return sources


def _upload_response(batch_id: str, sources: list[tuple[str, Path]]) -> dict[str, Json]:
    return {
        "code": 0,
        "msg": "ok",
        "data": {
            "batch_id": batch_id,
            "file_urls": [f"https://upload.example/{source_id}" for source_id, _ in sources],
            "task_ids": {source_id: f"task-{source_id}" for source_id, _ in sources},
        },
    }


def _poll_response(batch_id: str, source_id: str, state: str, **extra: Json) -> dict[str, Json]:
    item: dict[str, Json] = {"data_id": source_id, "task_id": f"task-{source_id}", "state": state, **extra}
    return {"code": 0, "msg": "ok", "data": {"batch_id": batch_id, "extract_result": [item]}}


def _zip_bytes(markdown: str, image_dir: str = "images") -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf:
        zf.writestr("full.md", markdown)
        zf.writestr("content_list.json", "[]")
        zf.writestr("model.json", "{}")
        zf.writestr("layout.json", "{}")
        zf.writestr(f"{image_dir}/img1.png", b"png")
    return buffer.getvalue()


def test_runner_chunks_local_batch_requests_to_fifty_files(tmp_path: Path):
    sources = _many_sources(tmp_path, 51)
    client = FakePrecisionApi([
        _upload_response("batch-1", sources[:50]),
        _upload_response("batch-2", sources[50:]),
    ])

    _run_lifecycle(RunInput(tmp_path, sources, client))

    post_calls = [call for call in client.calls if call.target == "/api/v4/file-urls/batch"]
    chunk_sizes: list[int] = []
    for call in post_calls:
        assert call.payload is not None
        files = call.payload["files"]
        assert isinstance(files, list)
        chunk_sizes.append(len(files))
    assert chunk_sizes == [50, 1]


def test_runner_requests_upload_urls_for_local_files(tmp_path: Path):
    sources = [_source(tmp_path)]
    client = FakePrecisionApi([_upload_response("batch-1", sources)])

    _run_lifecycle(RunInput(tmp_path, sources, client))

    call = client.calls[0]
    assert call == ApiCall(
        "POST",
        "/api/v4/file-urls/batch",
        payload={"files": [{"name": "report.pdf", "data_id": SOURCE_ID}], "model_version": "vlm"},
        headers={"Authorization": f"Bearer {FAKE_TOKEN}", "Content-Type": "application/json"},
    )


def test_runner_puts_file_bytes_to_upload_url(tmp_path: Path):
    sources = [_source(tmp_path)]
    client = FakePrecisionApi([_upload_response("batch-1", sources)])

    _run_lifecycle(RunInput(tmp_path, sources, client))

    assert ApiCall("PUT", f"https://upload.example/{SOURCE_ID}", body=b"%PDF-1.7") in client.calls


def test_runner_persists_batch_and_task_state_after_submission(tmp_path: Path):
    sources = [_source(tmp_path)]
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, "pending")])

    _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))

    state = [json.loads(line) for line in (tmp_path / "audit" / "lifecycle-state.jsonl").read_text(encoding="utf-8").splitlines()]
    assert state[0]["batch_id"] == "batch-1"
    assert state[0]["task_id"] == f"task-{SOURCE_ID}"


def _fake_monotonic(*values: float):
    ticks = iter(values)
    last = values[-1]

    def monotonic() -> float:
        nonlocal last
        try:
            last = next(ticks)
        except StopIteration:
            return last
        return last

    return monotonic


def _assert_pending_timeout_for_state(tmp_path: Path, monkeypatch, api_state: str) -> None:
    monkeypatch.setattr(time, "monotonic", _fake_monotonic(0.0, 2.0))
    sources = [_source(tmp_path)]
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, api_state)])

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))

    assert summary.items[0].status == "pending_timeout"
    assert [call.method for call in client.calls].count("GET") == 1


def test_runner_marks_waiting_file_state_pending_timeout(tmp_path: Path, monkeypatch):
    _assert_pending_timeout_for_state(tmp_path, monkeypatch, "waiting-file")


def test_runner_marks_pending_state_pending_timeout(tmp_path: Path, monkeypatch):
    _assert_pending_timeout_for_state(tmp_path, monkeypatch, "pending")


def test_runner_marks_running_state_pending_timeout(tmp_path: Path, monkeypatch):
    _assert_pending_timeout_for_state(tmp_path, monkeypatch, "running")


def test_runner_marks_converting_state_pending_timeout(tmp_path: Path, monkeypatch):
    _assert_pending_timeout_for_state(tmp_path, monkeypatch, "converting")


def test_runner_budget_allows_second_poll_to_reach_done(tmp_path: Path):
    sources = [_source(tmp_path)]
    zip_url = "https://cdn.example/second-poll.zip"
    client = FakePrecisionApi(
        [_upload_response("batch-1", sources)],
        [
            _poll_response("batch-1", SOURCE_ID, "pending"),
            _poll_response("batch-1", SOURCE_ID, "done", full_zip_url=zip_url),
        ],
        {zip_url: _zip_bytes("# Done on second poll\n")},
    )

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=10))

    assert summary.items[0].status == "done"
    assert [call.method for call in client.calls].count("GET") == 2


def test_runner_uses_poll_interval_between_pending_polls(tmp_path: Path, monkeypatch):
    sleeps: list[float] = []
    monkeypatch.setattr(time, "monotonic", _fake_monotonic(0.0, 0.0, 10.0))
    monkeypatch.setattr(time, "sleep", sleeps.append)
    sources = [_source(tmp_path)]
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, "pending")])

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=5, poll_interval_seconds=2))

    assert summary.items[0].status == "pending_timeout"
    assert [call.method for call in client.calls].count("GET") == 2
    assert sleeps == [2]


def test_runner_downloads_done_zip_and_extracts_markdown_and_images(tmp_path: Path):
    sources = [_source(tmp_path)]
    zip_url = "https://cdn.example/full.zip"
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, "done", full_zip_url=zip_url)], {zip_url: _zip_bytes("# Done\n\n![](images/img1.png)\n")})

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))

    assert summary.items[0].status == "done"
    assert (tmp_path / "out" / f"{SOURCE_ID}.md").read_text(encoding="utf-8") == f"# Done\n\n![]({SOURCE_ID}.images/img1.png)\n"
    assert (tmp_path / "out" / f"{SOURCE_ID}.images" / "img1.png").read_bytes() == b"png"


def test_runner_resumes_pending_state_without_resubmitting(tmp_path: Path):
    sources = [_source(tmp_path)]
    audit = tmp_path / "audit"
    audit.mkdir()
    (audit / "lifecycle-state.jsonl").write_text(json.dumps({"source_id": SOURCE_ID, "batch_id": "batch-1", "task_id": f"task-{SOURCE_ID}", "status": "pending_timeout"}) + "\n", encoding="utf-8")
    zip_url = "https://cdn.example/resumed.zip"
    client = FakePrecisionApi(poll_batches=[_poll_response("batch-1", SOURCE_ID, "done", full_zip_url=zip_url)], zip_by_url={zip_url: _zip_bytes("# Resumed\n")})

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))

    assert [call.method for call in client.calls].count("POST") == 0
    assert summary.items[0].status == "done"


def test_runner_records_failed_err_msg_without_unbounded_retry(tmp_path: Path):
    sources = [_source(tmp_path)]
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, "failed", err_msg="file broken")])

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))

    assert summary.items[0].status == "failed"
    assert summary.items[0].error == "file broken"
    assert len([call for call in client.calls if call.target.endswith("batch-1")]) == 1


def test_runner_marks_unrecoverable_pending_as_stale_pending(tmp_path: Path):
    sources = [_source(tmp_path)]
    client = FakePrecisionApi(poll_batches=[{"code": -60012, "msg": "not found", "data": {"batch_id": "batch-1"}}])
    audit = tmp_path / "audit"
    audit.mkdir()
    (audit / "lifecycle-state.jsonl").write_text(json.dumps({"source_id": SOURCE_ID, "batch_id": "batch-1", "status": "pending_timeout"}) + "\n", encoding="utf-8")

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))
    assert summary.items[0].status == "stale_pending"
    assert summary.items[0].next_action == "resubmit"


def test_runner_redacts_token_from_logs_state_manifests_and_errors(tmp_path: Path, capsys):
    sources = [_source(tmp_path)]
    leaked = f"Authorization: Bearer {FAKE_TOKEN}"
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, "failed", err_msg=leaked)])

    summary = _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))
    captured = capsys.readouterr()
    written = "\n".join(path.read_text(encoding="utf-8") for path in (tmp_path / "audit").rglob("*.json*") if path.is_file())
    assert FAKE_TOKEN not in f"{summary!r}\n{captured.out}\n{captured.err}\n{written}"


def test_runner_maps_downloaded_output_to_source_id_paths(tmp_path: Path):
    sources = [_source(tmp_path, name="original-name.pdf")]
    zip_url = "https://cdn.example/mapped.zip"
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, "done", full_zip_url=zip_url)], {zip_url: _zip_bytes("# Mapped\n")})

    _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))
    assert (tmp_path / "out" / f"{SOURCE_ID}.md").exists()
    assert not (tmp_path / "out" / "original-name.md").exists()


def test_runner_rewrites_original_stem_image_references_to_source_id(tmp_path: Path):
    sources = [_source(tmp_path, name="report.pdf")]
    zip_url = "https://cdn.example/rewrite.zip"
    client = FakePrecisionApi([_upload_response("batch-1", sources)], [_poll_response("batch-1", SOURCE_ID, "done", full_zip_url=zip_url)], {zip_url: _zip_bytes("# Report\n\n![](report.images/img1.png)\n", "report.images")})

    _run_lifecycle(RunInput(tmp_path, sources, client, max_poll_seconds=1))
    markdown = (tmp_path / "out" / f"{SOURCE_ID}.md").read_text(encoding="utf-8")
    assert f"![]({SOURCE_ID}.images/img1.png)" in markdown
    assert "report.images" not in markdown


def test_runner_remaps_existing_local_artifacts_without_api_calls(tmp_path: Path):
    sources = [_source(tmp_path)]
    raw = tmp_path / "audit" / "raw" / SOURCE_ID
    (raw / "images").mkdir(parents=True)
    (raw / "full.md").write_text("# Local\n\n![](images/img1.png)\n", encoding="utf-8")
    (raw / "images" / "img1.png").write_bytes(b"png")
    client = FakePrecisionApi()

    summary = _run_lifecycle(RunInput(tmp_path, sources, client))
    assert client.calls == []
    assert summary.items[0].status == "done"
    assert (tmp_path / "out" / f"{SOURCE_ID}.md").exists()


def test_runner_submits_non_html_files_with_vlm_model(tmp_path: Path):
    sources = [_source(tmp_path, name="report.pdf")]
    client = FakePrecisionApi([_upload_response("batch-1", sources)])
    _run_lifecycle(RunInput(tmp_path, sources, client))
    assert client.calls[0].payload is not None
    assert client.calls[0].payload["model_version"] == "vlm"


def test_runner_submits_html_files_with_mineru_html_model(tmp_path: Path):
    html = tmp_path / "page.html"
    html.write_text("<html></html>", encoding="utf-8")
    sources = [(HTML_SOURCE_ID, html)]
    client = FakePrecisionApi([_upload_response("batch-html", sources)])
    _run_lifecycle(RunInput(tmp_path, sources, client))
    assert client.calls[0].payload is not None
    assert client.calls[0].payload["model_version"] == "MinerU-HTML"


def test_pending_stub_file_is_classified_as_pending_stub(tmp_path: Path):
    assert len(PENDING_STUB.encode("utf-8")) == 77
    output = tmp_path / f"{SOURCE_ID}.md"
    output.write_text(PENDING_STUB, encoding="utf-8")

    module = importlib.import_module("scripts.mineru_lifecycle_runner")

    assert module.classify_lifecycle_output(output, source_id=SOURCE_ID).status == "pending_stub"


def test_contentful_missing_heading_is_not_classified_as_empty(tmp_path: Path):
    output = tmp_path / f"{SOURCE_ID}.md"
    output.write_text("contentful paragraph without heading. " * 20, encoding="utf-8")

    module = importlib.import_module("scripts.mineru_lifecycle_runner")

    classification = module.classify_lifecycle_output(output, source_id=SOURCE_ID)
    assert classification.status == "missing_heading_contentful"
    assert classification.status not in {"empty", "missing", "done", "quality_passed"}


@pytest.mark.skipif(
    not os.environ.get("RUN_MINERU_REAL_SMOKE"),
    reason="Real MinerU smoke test requires RUN_MINERU_REAL_SMOKE=1 and MINERU_TOKEN",
)
def test_real_smoke_skipped_without_env_var():
    """This test exists solely to make the skip visible in pytest -v output."""
