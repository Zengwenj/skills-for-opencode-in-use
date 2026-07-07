from __future__ import annotations

import io
import json
import shutil
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Protocol


Json = str | int | bool | None | list["Json"] | dict[str, "Json"]

UPLOAD_URLS_ENDPOINT: Final = "/api/v4/file-urls/batch"
POLL_BATCH_ENDPOINT: Final = "/api/v4/extract-results/batch"
MAX_BATCH_SIZE: Final = 50
HTML_EXTENSIONS: Final = {".html", ".htm"}
PENDING_STATES: Final = {"waiting-file", "pending", "running", "converting"}
MIN_CONTENTFUL_BYTES: Final = 500


class PrecisionApiClient(Protocol):
    def post_json(self, target: str, payload: dict[str, Json], headers: dict[str, str]) -> dict[str, Json]: ...

    def put_bytes(self, target: str, body: bytes) -> None: ...

    def get_json(self, target: str, headers: dict[str, str]) -> dict[str, Json]: ...

    def get_bytes(self, target: str) -> bytes: ...


@dataclass(frozen=True, slots=True)
class LifecycleSource:
    source_id: str; path: Path


@dataclass(frozen=True, slots=True)
class LifecycleRunConfig:
    sources: list[LifecycleSource]
    output_root: Path
    audit_dir: Path
    state_path: Path
    token: str
    client: PrecisionApiClient
    max_poll_seconds: int
    poll_interval_seconds: int


@dataclass(frozen=True, slots=True)
class LifecycleItem:
    source_id: str; status: str
    error: str | None = None
    next_action: str | None = None


@dataclass(frozen=True, slots=True)
class LifecycleSummary:
    items: list[LifecycleItem]


@dataclass(frozen=True, slots=True)
class ClassificationResult:
    status: str


def classify_lifecycle_output(path: Path, source_id: str) -> ClassificationResult:
    if not path.exists():
        return ClassificationResult(status="missing")

    markdown = path.read_text(encoding="utf-8")
    if markdown == _pending_stub(source_id):
        return ClassificationResult(status="pending_stub")
    if not markdown.strip():
        return ClassificationResult(status="empty")
    if len(markdown.encode("utf-8")) > MIN_CONTENTFUL_BYTES and "#" not in markdown:
        return ClassificationResult(status="missing_heading_contentful")
    return ClassificationResult(status="done")


def run_lifecycle(config: LifecycleRunConfig) -> LifecycleSummary:
    config.output_root.mkdir(parents=True, exist_ok=True)
    config.audit_dir.mkdir(parents=True, exist_ok=True)

    state = _load_state(config.state_path)
    results: dict[str, LifecycleItem] = {}
    pending: list[tuple[LifecycleSource, dict[str, Json]]] = []
    to_submit: list[LifecycleSource] = []

    for source in config.sources:
        raw_dir = config.audit_dir / "raw" / source.source_id
        existing_output = config.output_root / f"{source.source_id}.md"
        if (raw_dir / "full.md").exists():
            results[source.source_id] = _remap_raw_artifacts(raw_dir, config.output_root, source)
        elif classify_lifecycle_output(existing_output, source.source_id).status == "done":
            results[source.source_id] = LifecycleItem(source.source_id, "done")
        elif state.get(source.source_id, {}).get("status") == "pending_timeout":
            pending.append((source, state[source.source_id]))
        else:
            to_submit.append(source)

    _poll_pending(config, pending, results)
    _submit_sources(config, to_submit, results)

    return LifecycleSummary(items=[results[source.source_id] for source in config.sources])


def _pending_stub(source_id: str) -> str:
    return f"# {source_id}\n\nMinerU processing pending - file not yet parsed."


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _model_version(path: Path) -> str:
    if path.suffix.lower() in HTML_EXTENSIONS:
        return "MinerU-HTML"
    return "vlm"


def _redact(message: str | None, token: str) -> str | None:
    if message is None:
        return None
    if not token:
        return message
    return message.replace(token, "***")


def _load_state(path: Path) -> dict[str, dict[str, Json]]:
    if not path.exists():
        return {}

    records: dict[str, dict[str, Json]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        loaded: Json = json.loads(line)
        if isinstance(loaded, dict):
            source_id = loaded.get("source_id")
            if isinstance(source_id, str):
                records[source_id] = loaded
    return records


def _append_state(path: Path, source_id: str, batch_id: str, task_id: str | None, status: str, error: str | None = None, next_action: str | None = None) -> None:
    payload: dict[str, Json] = {
        "source_id": source_id,
        "batch_id": batch_id,
        "status": status,
    }
    if task_id is not None:
        payload["task_id"] = task_id
    if error is not None:
        payload["error"] = error
    if next_action is not None:
        payload["next_action"] = next_action

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def _poll_pending(config: LifecycleRunConfig, pending: list[tuple[LifecycleSource, dict[str, Json]]], results: dict[str, LifecycleItem]) -> None:
    batches: dict[str, list[tuple[LifecycleSource, dict[str, Json]]]] = {}
    for source, record in pending:
        batch_id = record.get("batch_id")
        if isinstance(batch_id, str):
            batches.setdefault(batch_id, []).append((source, record))

    for batch_id, entries in batches.items():
        _poll_batch(config, batch_id, [source for source, _ in entries], results)


def _submit_sources(config: LifecycleRunConfig, sources: list[LifecycleSource], results: dict[str, LifecycleItem]) -> None:
    by_model: dict[str, list[LifecycleSource]] = {}
    for source in sources:
        by_model.setdefault(_model_version(source.path), []).append(source)

    for model_version, model_sources in by_model.items():
        for chunk in _chunks(model_sources):
            batch_id = _submit_chunk(config, chunk, model_version)
            _poll_batch(config, batch_id, chunk, results)


def _chunks(sources: list[LifecycleSource]) -> list[list[LifecycleSource]]:
    return [sources[index : index + MAX_BATCH_SIZE] for index in range(0, len(sources), MAX_BATCH_SIZE)]


def _submit_chunk(config: LifecycleRunConfig, sources: list[LifecycleSource], model_version: str) -> str:
    payload: dict[str, Json] = {
        "files": [{"name": source.path.name, "data_id": source.source_id} for source in sources],
        "model_version": model_version,
    }
    response = config.client.post_json(UPLOAD_URLS_ENDPOINT, payload, _headers(config.token))
    data = _mapping(response.get("data"))
    batch_id = _text(data.get("batch_id"))
    urls = [_text(value) for value in _items(data.get("file_urls"))]
    task_ids = _mapping(data.get("task_ids"))

    for source, upload_url in zip(sources, urls):
        config.client.put_bytes(upload_url, source.path.read_bytes())
        task_id = _text(task_ids.get(source.source_id))
        _append_state(config.state_path, source.source_id, batch_id, task_id, "uploaded")
    return batch_id


def _poll_batch(config: LifecycleRunConfig, batch_id: str, sources: list[LifecycleSource], results: dict[str, LifecycleItem]) -> None:
    target = f"{POLL_BATCH_ENDPOINT}/{batch_id}"
    deadline = time.monotonic() + config.max_poll_seconds
    pending = {source.source_id: source for source in sources}
    task_ids: dict[str, str] = {}

    while pending:
        response = config.client.get_json(target, _headers(config.token))
        if response.get("code") != 0:
            _record_stale_or_failed(config, batch_id, list(pending.values()), response, results)
            return

        by_source = _poll_items_by_source(_mapping(response.get("data")).get("extract_result"))
        for source_id, source in list(pending.items()):
            item = by_source.get(source_id, {})
            state = _text(item.get("state"))
            task_ids[source_id] = _text(item.get("task_id"))
            if state == "done":
                _complete_done_item(config, source, batch_id, item, results)
                pending.pop(source_id)
            elif state == "failed":
                error = _redact(_text(item.get("err_msg")), config.token)
                results[source_id] = LifecycleItem(source_id, "failed", error=error)
                _append_state(config.state_path, source_id, batch_id, task_ids[source_id], "failed", error)
                pending.pop(source_id)

        if not pending:
            return
        if time.monotonic() >= deadline:
            for source_id in pending:
                results[source_id] = LifecycleItem(source_id, "pending_timeout")
                _append_state(config.state_path, source_id, batch_id, task_ids.get(source_id), "pending_timeout")
            return
        time.sleep(config.poll_interval_seconds)


def _record_stale_or_failed(config: LifecycleRunConfig, batch_id: str, sources: list[LifecycleSource], response: dict[str, Json], results: dict[str, LifecycleItem]) -> None:
    status = "stale_pending" if response.get("code") == -60012 else "failed"
    next_action = "resubmit" if status == "stale_pending" else None
    error = _redact(_text(response.get("msg")), config.token)
    for source in sources:
        results[source.source_id] = LifecycleItem(source.source_id, status, error=error, next_action=next_action)
        _append_state(config.state_path, source.source_id, batch_id, None, status, error, next_action)


def _complete_done_item(config: LifecycleRunConfig, source: LifecycleSource, batch_id: str, item: dict[str, Json], results: dict[str, LifecycleItem]) -> None:
    zip_url = _text(item.get("full_zip_url"))
    raw_dir = _extract_zip_to_raw(config, source.source_id, zip_url)
    results[source.source_id] = _remap_raw_artifacts(raw_dir, config.output_root, source)
    _append_state(config.state_path, source.source_id, batch_id, _text(item.get("task_id")), "done")


def _extract_zip_to_raw(config: LifecycleRunConfig, source_id: str, zip_url: str) -> Path:
    raw_dir = config.audit_dir / "raw" / source_id
    if raw_dir.exists():
        shutil.rmtree(raw_dir)
    raw_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(io.BytesIO(config.client.get_bytes(zip_url))) as archive:
        archive.extractall(raw_dir)
    return raw_dir


def _remap_raw_artifacts(raw_dir: Path, output_root: Path, source: LifecycleSource) -> LifecycleItem:
    output_root.mkdir(parents=True, exist_ok=True)
    markdown = (raw_dir / "full.md").read_text(encoding="utf-8")
    (output_root / f"{source.source_id}.md").write_text(
        _rewrite_image_paths(markdown, source), encoding="utf-8"
    )

    image_source = _image_source_dir(raw_dir, source.path.stem)
    if image_source is not None:
        image_target = output_root / f"{source.source_id}.images"
        if image_target.exists():
            shutil.rmtree(image_target)
        shutil.copytree(image_source, image_target)
    return LifecycleItem(source.source_id, "done")


def _image_source_dir(raw_dir: Path, source_stem: str) -> Path | None:
    for candidate in (raw_dir / "images", raw_dir / f"{source_stem}.images"):
        if candidate.exists():
            return candidate
    return None


def _rewrite_image_paths(markdown: str, source: LifecycleSource) -> str:
    image_root = f"{source.source_id}.images/"
    return markdown.replace("(images/", f"({image_root}").replace(
        f"({source.path.stem}.images/", f"({image_root}"
    )


def _poll_items_by_source(value: Json | None) -> dict[str, dict[str, Json]]:
    result: dict[str, dict[str, Json]] = {}
    for item in _items(value):
        if isinstance(item, dict):
            source_id = item.get("data_id")
            if isinstance(source_id, str):
                result[source_id] = item
    return result


def _mapping(value: Json | None) -> dict[str, Json]:
    if isinstance(value, dict):
        return value
    return {}


def _items(value: Json | None) -> list[Json]:
    if isinstance(value, list):
        return value
    return []


def _text(value: Json | None) -> str:
    if isinstance(value, str):
        return value
    return ""
