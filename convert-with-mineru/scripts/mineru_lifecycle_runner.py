from __future__ import annotations

import hashlib
import io
import ipaddress
import json
import os
import re
import shutil
import stat
import time
import uuid
import zipfile
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Final, Protocol
from urllib.parse import urlsplit


Json = str | int | bool | None | list["Json"] | dict[str, "Json"]

UPLOAD_URLS_ENDPOINT: Final = "/api/v4/file-urls/batch"
POLL_BATCH_ENDPOINT: Final = "/api/v4/extract-results/batch"
MAX_BATCH_SIZE: Final = 50
HTML_EXTENSIONS: Final = {".html", ".htm"}
PENDING_STATES: Final = {"waiting-file", "pending", "running", "converting"}
MIN_CONTENTFUL_BYTES: Final = 500

# 契约 §6 ZIP 防护默认上限（本地安全上限，非官方配额）
ZIP_TOTAL_BYTES_LIMIT: Final = 256 * 1024 * 1024      # 下载 zip 总字节 256 MiB
ZIP_MEMBER_BYTES_LIMIT: Final = 256 * 1024 * 1024     # 单成员展开字节 256 MiB
ZIP_EXPANDED_TOTAL_LIMIT: Final = 1024 * 1024 * 1024  # 全部成员展开总量 1 GiB
ZIP_MEMBER_COUNT_LIMIT: Final = 10000                 # 成员数量

# 契约 §5 状态扩展
STATUS_UNCERTAIN: Final = "uncertain"
STATUS_MANUAL_RECONCILE: Final = "manual_reconcile"

# 契约 §5：有 batch_id 的这些状态只 poll，绝不重新 POST
POLL_ONLY_STATUSES: Final = {
    "submitting",
    "submitted",
    "uploaded",
    "waiting-file",
    "pending",
    "running",
    "converting",
    "pending_timeout",
    "poll_error",
}

# 无 batch_id 时允许全新提交的状态：全新（无记录）/ 配额被拒（未发送）/ 授权哈希分歧（未发送）。
# 其余未知状态一律 manual_reconcile（fail-closed：状态机未识别 ≠ 可重试）。
RESUBMITTABLE_STATUSES: Final = {"", "quota_refused", "authorization_divergent"}

# 用户硬约束：每日高精度解析 1000 页，任何账本配置不得突破
DAILY_PAGE_HARD_CAP: Final = 1000

# source_id 参与本地路径拼接与递归删除，必须是无路径语义的安全标识
SOURCE_ID_PATTERN: Final = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,127}$")

# 契约 §1 账本条目三态 + 预留释放
QUOTA_ENTRY_RESERVED: Final = "reserved"
QUOTA_ENTRY_CONFIRMED: Final = "confirmed"
QUOTA_ENTRY_RELEASED: Final = "released_never_sent"
QUOTA_ENTRY_UNCERTAIN: Final = "uncertain"

ZIP_STREAM_CHUNK_BYTES: Final = 64 * 1024


class QuotaGateError(RuntimeError):
    """fail-closed：五个额度前置条件任一不满足时拒绝提交（契约 §1）。"""


class SubmissionUncertainError(RuntimeError):
    """POST 结果未知（请求可能已被服务端接受）——一律 uncertain，禁止自动重发。"""


class ZipSafetyError(RuntimeError):
    """ZIP 防护（契约 §6）：超限/路径穿越/symlink/伪造头一律中止且不产出部分结果。"""


class PrecisionApiClient(Protocol):
    def post_json(self, target: str, payload: dict[str, Json], headers: dict[str, str]) -> dict[str, Json]: ...

    def put_bytes(self, target: str, body: bytes) -> None: ...

    def get_json(self, target: str, headers: dict[str, str]) -> dict[str, Json]: ...

    def get_bytes(self, target: str) -> bytes: ...


@dataclass(frozen=True, slots=True)
class ZipLimits:
    """契约 §6 ZIP 四项限额；默认值即契约推荐上限，测试/调用方可注入更小值。"""

    total_zip_bytes: int = ZIP_TOTAL_BYTES_LIMIT
    max_member_bytes: int = ZIP_MEMBER_BYTES_LIMIT
    total_expanded_bytes: int = ZIP_EXPANDED_TOTAL_LIMIT
    max_members: int = ZIP_MEMBER_COUNT_LIMIT


@dataclass(frozen=True, slots=True)
class LifecycleSource:
    source_id: str; path: Path
    pages: int | None = None  # 调用方已知的页数预估；缺省时按 PDF 页数/每文件 1 页保守估算
    # 批准哈希（upload-allowlist.archive_sha256）：提供时，上传字节与批准字节不符即拒绝提交
    expected_sha256: str | None = None


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
    # 契约 §1/§5：额度账本路径为必填项——不传即构造失败，绝不默认放行（fail-closed）。
    quota_ledger_path: Path
    zip_limits: ZipLimits = field(default_factory=ZipLimits)


@dataclass(frozen=True, slots=True)
class QuotaLedger:
    path: Path
    document: dict[str, Json]

    @classmethod
    def load(cls, path: Path) -> "QuotaLedger":
        if not path.exists():
            raise QuotaGateError(f"quota ledger missing: {path}")
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise QuotaGateError(f"quota ledger unreadable: {exc}") from exc
        if not isinstance(document, dict):
            raise QuotaGateError("quota ledger malformed: root is not a JSON object")
        return cls(path=path, document=document)


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
    # LOCAL-PATCH 2026-09-09: 行首 ATX H1-H6 判定（原版任意 # 子串误判表格/URL锚点中的 #）
    # 与 llmwiki-inbox-ingest Test-MarkdownHeading 规则对齐; 试点 20/20 闭环
    if len(markdown.encode("utf-8")) > MIN_CONTENTFUL_BYTES and not re.search(r"(?m)^#{1,6}\s", markdown):
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
        # oracle H5：source_id 参与本地路径拼接与 rmtree，进入任何路径操作前强制校验
        if not SOURCE_ID_PATTERN.match(source.source_id):
            raise ValueError(f"unsafe source_id rejected: {source.source_id!r}")
        raw_dir = config.audit_dir / "raw" / source.source_id
        existing_output = config.output_root / f"{source.source_id}.md"
        record = state.get(source.source_id, {})
        status = _text(record.get("status"))
        batch_id = _text(record.get("batch_id"))
        if (raw_dir / "full.md").exists():
            results[source.source_id] = _remap_raw_artifacts(raw_dir, config.output_root, source)
        elif classify_lifecycle_output(existing_output, source.source_id).status == "done":
            results[source.source_id] = LifecycleItem(source.source_id, "done")
        elif status == "submitting" and not batch_id:
            # 契约 §5：POST 前崩溃/响应未落盘 → uncertain，人工核查，禁止当未提交重发
            results[source.source_id] = LifecycleItem(
                source.source_id,
                STATUS_UNCERTAIN,
                error=_redact(_text(record.get("error")) or "interrupted before batch id persisted", config.token),
                next_action=STATUS_MANUAL_RECONCILE,
            )
        elif status in POLL_ONLY_STATUSES and batch_id:
            # 有 batch_id：只 poll 对账，绝不重新 POST/PUT
            pending.append((source, record))
        elif status in POLL_ONLY_STATUSES:
            # 契约 §5：POLL_ONLY 状态但 batch_id 丢失（状态损坏/截断）→ 人工对账，绝不当作未提交重发
            results[source.source_id] = LifecycleItem(
                source.source_id,
                STATUS_MANUAL_RECONCILE,
                error=_redact(
                    _text(record.get("error")) or "poll-only status without batch id (state record incomplete)",
                    config.token,
                ),
                next_action="batch id lost; manual reconcile (do not resubmit)",
            )
        elif status == "stale_pending":
            # 契约 §5：转 manual_reconcile，不自动重提；仅经用户单独授权后以新 intent 提交
            results[source.source_id] = LifecycleItem(
                source.source_id,
                STATUS_MANUAL_RECONCILE,
                error=_redact(_text(record.get("error")), config.token),
                next_action="resubmit only with explicit user authorization",
            )
        elif status == "failed":
            # 契约 §5：failed 为终态，不自动重发
            results[source.source_id] = LifecycleItem(
                source.source_id,
                "failed",
                error=_redact(_text(record.get("error")) or "previous attempt failed", config.token),
            )
        elif status in {STATUS_UNCERTAIN, STATUS_MANUAL_RECONCILE}:
            results[source.source_id] = LifecycleItem(
                source.source_id,
                status,
                error=_redact(_text(record.get("error")), config.token),
                next_action=STATUS_MANUAL_RECONCILE,
            )
        elif status == "done" and batch_id:
            # 本地产物丢失但 batch 已知：poll 取回
            pending.append((source, record))
        elif status == "done":
            # oracle B-S4：done 但产物与 batch 双缺失（状态损坏）→ 人工对账，不得重发
            results[source.source_id] = LifecycleItem(
                source.source_id,
                STATUS_MANUAL_RECONCILE,
                error=_redact(_text(record.get("error")) or "done without artifacts or batch id (state record incomplete)", config.token),
                next_action="manual reconcile (do not resubmit)",
            )
        elif status not in RESUBMITTABLE_STATUSES:
            # oracle B-S4：未知/未识别状态一律人工对账（fail-closed：状态机未识别 ≠ 可重试）
            results[source.source_id] = LifecycleItem(
                source.source_id,
                STATUS_MANUAL_RECONCILE,
                error=_redact(_text(record.get("error")) or f"unrecognized status {status!r}", config.token),
                next_action="manual reconcile (do not resubmit)",
            )
        else:
            # 全新 / quota_refused / authorization_divergent：本地可安全重试（从未发送）
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


_URL_PATTERN = re.compile(r"https?://[^\s\"'<>]+")


def _redact(message: str | None, token: str) -> str | None:
    # 契约 §E：token 与 URL（含预签名 URL）一律不得进入 state/manifest/日志
    if message is None:
        return None
    redacted = message
    if token:
        redacted = redacted.replace(token, "***")
    return _URL_PATTERN.sub("***", redacted)


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _state_lock_path(state_path: Path) -> Path:
    return state_path.with_name(state_path.name + ".lock")


def _quota_lock_path(config: LifecycleRunConfig) -> Path:
    """账本级锁：同一账本的预留/流转必须互斥，与 state 文件无关。

    原实现按 state_path 加锁：两个不同 state 共用同一账本时可并发预留并互相覆盖计数
    （oracle H4）。改为绑定账本文件自身，保证同账本全局串行。
    """
    return config.quota_ledger_path.with_name(config.quota_ledger_path.name + ".lock")


def _try_os_lock(descriptor: int) -> bool:
    """oracle B3：操作系统级字节范围锁（非阻塞）。Windows 用 msvcrt，POSIX 用 flock。"""
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def _release_os_lock(descriptor: int) -> None:
    os.lseek(descriptor, 0, os.SEEK_SET)
    if os.name == "nt":
        import msvcrt
        msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(descriptor, fcntl.LOCK_UN)


@contextmanager
def _file_lock(lock_path: Path, timeout_seconds: float = 10.0, stale_seconds: float = 60.0) -> Iterator[None]:
    """同一临界区串行化 state 追加与额度账本写（契约 §5：预留与 intent 同锁）。

    oracle B3：改用操作系统持有的字节范围锁——持有者进程退出（含崩溃）时由内核自动释放，
    不存在"检查后删除"的接管竞态，也不依赖 PID 存活判定。
    锁文件本身常驻磁盘（unlink 会重新引入竞态）；stale_seconds 仅保留签名兼容，无语义。
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    deadline: float | None = None
    while True:
        descriptor = os.open(str(lock_path), os.O_CREAT | os.O_RDWR)
        if _try_os_lock(descriptor):
            break
        os.close(descriptor)
        if deadline is None:
            deadline = time.monotonic() + timeout_seconds
        if time.monotonic() >= deadline:
            raise TimeoutError(f"could not acquire lock: {lock_path}")
        time.sleep(0.05)
    try:
        yield
    finally:
        try:
            _release_os_lock(descriptor)
        finally:
            os.close(descriptor)


def _atomic_write_json(path: Path, document: dict[str, Json]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.{uuid.uuid4().hex[:8]}.tmp")
    try:
        with temp_path.open("w", encoding="utf-8") as handle:
            json.dump(document, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def _quota_gate(document: dict[str, Json], requested_pages: int, service_today: str | None = None) -> str:
    """契约 §1 五个 fail-closed 条件：时区未知/epoch 不可对齐/计费口径不明/当日剩余未知/超限。

    通过时返回 epoch_date（供 state 的 quota_epoch 字段使用）。
    """
    epoch = document.get("epoch")
    if not isinstance(epoch, dict):
        raise QuotaGateError("quota epoch block missing")
    if epoch.get("service_timezone_known") is not True:
        raise QuotaGateError("service timezone unknown")
    if epoch.get("epoch_reset_basis") != "user_configured":
        raise QuotaGateError("epoch reset basis unknown; cannot align service day")
    epoch_date = epoch.get("epoch_date")
    if not isinstance(epoch_date, str):
        raise QuotaGateError("epoch_date missing")
    try:
        datetime.strptime(epoch_date, "%Y-%m-%d")
    except ValueError as exc:
        raise QuotaGateError(f"epoch_date invalid: {epoch_date!r}") from exc
    today = service_today or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if epoch_date != today:
        raise QuotaGateError(
            f"epoch_date {epoch_date} not aligned with current service day {today}; daily remaining unknown"
        )
    if document.get("billing_basis") != "per_page":
        raise QuotaGateError(f"billing basis unclear: {document.get('billing_basis')!r}")
    if not isinstance(document.get("entries"), list):
        raise QuotaGateError("quota entries unknown; daily remaining unknown")
    limit = epoch.get("daily_page_limit")
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 0:
        raise QuotaGateError("daily page limit unknown")
    # oracle H4：用户硬约束 1000 页/日，账本配置不得突破（防手改账本放宽上限）
    if limit > DAILY_PAGE_HARD_CAP:
        raise QuotaGateError(f"daily page limit {limit} exceeds hard cap {DAILY_PAGE_HARD_CAP}")
    if requested_pages <= 0:
        raise QuotaGateError(f"requested pages must be a positive integer, got {requested_pages}")
    counters: list[int] = []
    for counter_name in ("reserved_pages", "consumed_pages", "uncertain_pages"):
        value = document.get(counter_name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise QuotaGateError(f"daily usage unknown: {counter_name}")
        counters.append(value)
    reserved, consumed, uncertain = counters
    if reserved + consumed + uncertain + requested_pages > limit:
        raise QuotaGateError(
            f"quota exceeded: {reserved}+{consumed}+{uncertain}+{requested_pages} > {limit}"
        )
    return epoch_date


def _apply_reservation(
    document: dict[str, Json], attempt_id: str, source_ids: list[str], pages: int, ts: str
) -> None:
    # 契约 §1：预留计入 reserved_pages，条目 state=reserved
    entries = document.get("entries")
    if not isinstance(entries, list):
        raise QuotaGateError("quota entries unknown")
    entries.append(
        {
            "attempt_id": attempt_id,
            "batch_id": "",
            "source_ids": list(source_ids),
            "reserved_pages": pages,
            "state": QUOTA_ENTRY_RESERVED,
            "ts": ts,
        }
    )
    document["reserved_pages"] = int(document["reserved_pages"]) + pages  # type: ignore[arg-type]


def _ledger_transition(
    config: LifecycleRunConfig,
    attempt_id: str,
    new_state: str,
    batch_id: str | None = None,
) -> None:
    """在锁内流转账本条目：reserved → confirmed / uncertain / released_never_sent（幂等）。"""
    if not attempt_id:
        return
    with _file_lock(_quota_lock_path(config)):
        ledger = QuotaLedger.load(config.quota_ledger_path)
        document = ledger.document
        entries = document.get("entries")
        if not isinstance(entries, list):
            raise QuotaGateError("quota entries unknown")
        entry = next(
            (
                candidate
                for candidate in entries
                if isinstance(candidate, dict) and candidate.get("attempt_id") == attempt_id
            ),
            None,
        )
        if entry is None or entry.get("state") != QUOTA_ENTRY_RESERVED:
            return
        pages = entry.get("reserved_pages")
        if not isinstance(pages, int) or isinstance(pages, bool):
            return
        entry["state"] = new_state
        entry["ts"] = _utc_now_iso()
        if batch_id:
            entry["batch_id"] = batch_id
        if new_state == QUOTA_ENTRY_CONFIRMED:
            document["reserved_pages"] = int(document["reserved_pages"]) - pages  # type: ignore[arg-type]
            document["consumed_pages"] = int(document["consumed_pages"]) + pages  # type: ignore[arg-type]
        elif new_state == QUOTA_ENTRY_UNCERTAIN:
            # 契约 §1：失败项一律记 uncertain，不返还额度
            document["reserved_pages"] = int(document["reserved_pages"]) - pages  # type: ignore[arg-type]
            document["uncertain_pages"] = int(document["uncertain_pages"]) + pages  # type: ignore[arg-type]
        elif new_state == QUOTA_ENTRY_RELEASED:
            document["reserved_pages"] = int(document["reserved_pages"]) - pages  # type: ignore[arg-type]
        _atomic_write_json(config.quota_ledger_path, document)


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


def _append_state(
    path: Path,
    source_id: str,
    batch_id: str,
    task_id: str | None,
    status: str,
    error: str | None = None,
    next_action: str | None = None,
    *,
    attempt_id: str | None = None,
    request_fingerprint: str | None = None,
    source_sha256: str | None = None,
    reserved_pages: int | None = None,
    quota_epoch: str | None = None,
    ts: str | None = None,
    fsync: bool = False,
) -> None:
    payload: dict[str, Json] = {
        "source_id": source_id,
        "batch_id": batch_id,
        "status": status,
    }
    if attempt_id is not None:
        payload["attempt_id"] = attempt_id
    if request_fingerprint is not None:
        payload["request_fingerprint"] = request_fingerprint
    if source_sha256 is not None:
        payload["source_sha256"] = source_sha256
    if reserved_pages is not None:
        payload["reserved_pages"] = reserved_pages
    if quota_epoch is not None:
        payload["quota_epoch"] = quota_epoch
    if task_id is not None:
        payload["task_id"] = task_id
    if error is not None:
        payload["error"] = error
    if next_action is not None:
        payload["next_action"] = next_action
    payload["ts"] = ts or _utc_now_iso()

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
        handle.flush()
        if fsync:
            os.fsync(handle.fileno())


def _poll_pending(
    config: LifecycleRunConfig,
    pending: list[tuple[LifecycleSource, dict[str, Json]]],
    results: dict[str, LifecycleItem],
) -> None:
    batches: dict[str, list[tuple[LifecycleSource, dict[str, Json]]]] = {}
    for source, record in pending:
        batch_id = record.get("batch_id")
        if isinstance(batch_id, str):
            batches.setdefault(batch_id, []).append((source, record))

    for batch_id, entries in batches.items():
        attempts = {source.source_id: _text(record.get("attempt_id")) for source, record in entries}
        _poll_batch(config, batch_id, [source for source, _ in entries], results, attempts)


def _submit_sources(config: LifecycleRunConfig, sources: list[LifecycleSource], results: dict[str, LifecycleItem]) -> None:
    by_model: dict[str, list[LifecycleSource]] = {}
    for source in sources:
        by_model.setdefault(_model_version(source.path), []).append(source)

    for model_version, model_sources in by_model.items():
        for chunk in _chunks(model_sources):
            _submit_chunk(config, chunk, model_version, results)


def _chunks(sources: list[LifecycleSource]) -> list[list[LifecycleSource]]:
    return [sources[index : index + MAX_BATCH_SIZE] for index in range(0, len(sources), MAX_BATCH_SIZE)]


def _canonical_json(payload: dict[str, Json]) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _request_fingerprint(payload: dict[str, Json]) -> str:
    # 契约 §5：对提交请求规范化 JSON 的 SHA256
    return hashlib.sha256(_canonical_json(payload).encode("utf-8")).hexdigest()


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _estimate_pages(source: LifecycleSource) -> int:
    if source.pages is not None:
        return max(int(source.pages), 0)
    if source.path.suffix.lower() == ".pdf":
        try:
            import pymupdf  # 可选依赖：不可用时按每文件 1 页保守预留
        except Exception:
            return 1
        try:
            document = pymupdf.open(str(source.path))
        except Exception:
            return 1
        try:
            return max(int(document.page_count), 1)
        finally:
            document.close()
    return 1


def _mark_chunk_uncertain(
    config: LifecycleRunConfig,
    sources: list[LifecycleSource],
    attempt_id: str,
    results: dict[str, LifecycleItem],
    reason: str,
) -> None:
    """POST 结果未知（batch 未落盘）：条目转 uncertain 不返还，state 记 uncertain，禁止自动重发。"""
    error = _redact(reason, config.token)
    ledger_note = ""
    try:
        _ledger_transition(config, attempt_id, QUOTA_ENTRY_UNCERTAIN)
    except QuotaGateError as exc:
        ledger_note = f" (ledger transition failed: {exc})"
    for source in sources:
        results[source.source_id] = LifecycleItem(
            source.source_id, STATUS_UNCERTAIN, error=f"{error}{ledger_note}", next_action=STATUS_MANUAL_RECONCILE
        )
        _append_state(
            config.state_path,
            source.source_id,
            "",
            None,
            STATUS_UNCERTAIN,
            f"{error}{ledger_note}",
            STATUS_MANUAL_RECONCILE,
            attempt_id=attempt_id,
        )


def _append_refusal(
    config: LifecycleRunConfig,
    source_ids: list[str],
    status: str,
    error: str,
    next_action: str | None,
    attempt_id: str,
) -> None:
    """oracle B1：拒绝类状态只能在锁内条件写入。

    若该 source 的最新状态已被并发进程推进（submitting/submitted/...），
    不得追加可重提状态的拒绝记录——否则后续运行会把已提交任务当作可安全重发。
    """
    with _file_lock(_quota_lock_path(config)):
        fresh = _load_state(config.state_path)
        for source_id in source_ids:
            latest = _text(fresh.get(source_id, {}).get("status"))
            if latest not in RESUBMITTABLE_STATUSES:
                continue
            _append_state(
                config.state_path, source_id, "", None, status, error, next_action, attempt_id=attempt_id
            )


def _submit_chunk(config: LifecycleRunConfig, sources: list[LifecycleSource], model_version: str, results: dict[str, LifecycleItem]) -> None:
    # 契约 §5 强制顺序：attempt_id →（锁内过滤后）request_fingerprint → submitting intent(fsync) → 同锁预留 → POST
    attempt_id = uuid.uuid4().hex
    payload: dict[str, Json] | None = None
    fingerprint: str | None = None
    pages = sum(_estimate_pages(source) for source in sources)

    # 契约 §3：上传字节与审计哈希必须同源。此处一次性读取并计哈希，PUT 复用同一份字节，
    # 使 intent 的 source_sha256 与实际上传内容之间不存在 TOCTOU 窗口。
    # C1 修复：若调用方提供了批准哈希（allowlist.archive_sha256），读取字节立即核对；
    # 不符说明预检后文件被改动——绝不写 intent、绝不预留额度、绝不 POST。
    bodies: dict[str, bytes] = {}
    digests: dict[str, str] = {}
    for source in sources:
        body = source.path.read_bytes()
        digest = hashlib.sha256(body).hexdigest()
        if source.expected_sha256 is not None and digest != source.expected_sha256:
            error = _redact(
                f"authorization divergent: bytes no longer match approved archive_sha256 ({digest[:16]}…)",
                config.token,
            )
            for s in sources:
                results[s.source_id] = LifecycleItem(s.source_id, "authorization_divergent", error=error, next_action=STATUS_MANUAL_RECONCILE)
            _append_refusal(config, [s.source_id for s in sources], "authorization_divergent", error, STATUS_MANUAL_RECONCILE, attempt_id)
            return
        bodies[source.source_id] = body
        digests[source.source_id] = digest
    try:
        with _file_lock(_quota_lock_path(config)):
            # oracle H4（并发）：同 state 的提交决策在锁外读取——锁内复核最新状态，
            # 已被并发进程推进的条目绝不重复 POST
            fresh = _load_state(config.state_path)
            dropped = [
                s for s in sources
                if _text(fresh.get(s.source_id, {}).get("status")) not in RESUBMITTABLE_STATUSES
            ]
            if dropped:
                for s in dropped:
                    advanced = _text(fresh.get(s.source_id, {}).get("status"))
                    results[s.source_id] = LifecycleItem(
                        s.source_id, STATUS_MANUAL_RECONCILE,
                        error=_redact(f"concurrent run already advanced status to {advanced!r}", config.token),
                        next_action=STATUS_MANUAL_RECONCILE,
                    )
                sources = [s for s in sources if s not in dropped]
                pages = sum(_estimate_pages(s) for s in sources)
                if not sources:
                    return
            # oracle B2：payload 与指纹必须在过滤之后基于最终 sources 重建，
            # 否则 POST 会包含已被丢弃的条目（预留与请求不一致）
            payload = {
                "files": [{"name": source.path.name, "data_id": source.source_id} for source in sources],
                "model_version": model_version,
            }
            fingerprint = _request_fingerprint(payload)
            ledger = QuotaLedger.load(config.quota_ledger_path)
            epoch_date = _quota_gate(ledger.document, pages)
            for source in sources:
                _append_state(
                    config.state_path,
                    source.source_id,
                    "",
                    None,
                    "submitting",
                    fsync=True,
                    attempt_id=attempt_id,
                    request_fingerprint=fingerprint,
                    source_sha256=digests[source.source_id],
                    reserved_pages=pages,
                    quota_epoch=epoch_date,
                )
            _apply_reservation(ledger.document, attempt_id, [source.source_id for source in sources], pages, _utc_now_iso())
            _atomic_write_json(config.quota_ledger_path, ledger.document)
    except QuotaGateError as exc:
        # gate 拒绝发生在写 intent 之前：不产生 uncertain，修复账本后可全新 prepare
        # oracle B1：拒绝记录锁内条件写入，不覆盖并发进程已推进的状态
        error = _redact(f"quota gate refused submission: {exc}", config.token)
        for source in sources:
            results[source.source_id] = LifecycleItem(
                source.source_id, "quota_refused", error=error, next_action="fix quota ledger and rerun"
            )
        _append_refusal(
            config,
            [source.source_id for source in sources],
            "quota_refused",
            error,
            "fix quota ledger and rerun",
            attempt_id,
        )
        return

    # intent + 预留已落盘；此后任何失败都按 uncertain 处理（契约 §1：失败不返还额度）
    try:
        response = config.client.post_json(UPLOAD_URLS_ENDPOINT, payload, _headers(config.token))
    except Exception as exc:
        _mark_chunk_uncertain(config, sources, attempt_id, results, f"upload request failed: {exc}")
        return

    data = _mapping(response.get("data"))
    batch_id = _text(data.get("batch_id"))
    if not batch_id:
        message = _redact(_text(response.get("msg")) or "no batch id in response", config.token)
        _mark_chunk_uncertain(config, sources, attempt_id, results, f"upload request rejected: {message}")
        return

    # 契约 §5：收到 batch_id 立即持久化 submitted，再 PUT
    for source in sources:
        _append_state(config.state_path, source.source_id, batch_id, None, "submitted", fsync=True, attempt_id=attempt_id)

    urls = [_text(value) for value in _items(data.get("file_urls"))]
    task_ids = _mapping(data.get("task_ids"))
    if len(urls) != len(sources):
        # batch 已落盘：state 停留在 submitted，恢复时只 poll 对账（见契约 §5）
        error = _redact(f"upload url count mismatch: {len(urls)} != {len(sources)}", config.token)
        for source in sources:
            results[source.source_id] = LifecycleItem(
                source.source_id, STATUS_UNCERTAIN, error=error, next_action="poll reconciles on next run"
            )
        return

    for source, upload_url in zip(sources, urls):
        try:
            config.client.put_bytes(upload_url, bodies[source.source_id])
        except Exception as exc:
            # state 已是 submitted+batch_id：本 run 放弃，恢复时只 poll 对账，不重发 POST/PUT
            error = _redact(f"upload put failed: {exc}", config.token)
            results[source.source_id] = LifecycleItem(
                source.source_id, STATUS_UNCERTAIN, error=error, next_action="poll reconciles on next run"
            )
            for remaining in sources:
                results.setdefault(
                    remaining.source_id,
                    LifecycleItem(remaining.source_id, STATUS_UNCERTAIN, error=error, next_action="poll reconciles on next run"),
                )
            return
        _append_state(
            config.state_path,
            source.source_id,
            batch_id,
            _text(task_ids.get(source.source_id)),
            "uploaded",
            attempt_id=attempt_id,
        )

    _poll_batch(config, batch_id, sources, results, {source.source_id: attempt_id for source in sources})


def _poll_batch(
    config: LifecycleRunConfig,
    batch_id: str,
    sources: list[LifecycleSource],
    results: dict[str, LifecycleItem],
    attempts: dict[str, str] | None = None,
) -> None:
    attempts = attempts or {}
    target = f"{POLL_BATCH_ENDPOINT}/{batch_id}"
    deadline = time.monotonic() + config.max_poll_seconds
    pending = {source.source_id: source for source in sources}
    task_ids: dict[str, str] = {}

    while pending:
        try:
            response = config.client.get_json(target, _headers(config.token))
        except Exception as exc:
            # oracle M9/B6：轮询异常不得裸抛（traceback 可能携带 token/预签名 URL）；
            # 已有 batch_id 的条目转 poll_error（保留 attempt 关联），下轮只 poll，绝不重发
            error = _redact(f"poll request failed: {exc}", config.token)
            for source_id in pending:
                results[source_id] = LifecycleItem(source_id, "poll_error", error=error, next_action="poll retries on next run")
                _append_state(
                    config.state_path, source_id, batch_id, task_ids.get(source_id), "poll_error", error,
                    attempt_id=_text(attempts.get(source_id)),
                )
            return
        if response.get("code") != 0:
            _record_stale_or_failed(config, batch_id, list(pending.values()), response, results, attempts)
            return

        by_source = _poll_items_by_source(_mapping(response.get("data")).get("extract_result"))
        for source_id, source in list(pending.items()):
            item = by_source.get(source_id, {})
            state = _text(item.get("state"))
            task_ids[source_id] = _text(item.get("task_id"))
            attempt_id = _text(attempts.get(source_id))
            if state == "done":
                _complete_done_item(config, source, batch_id, item, results, attempt_id)
                pending.pop(source_id)
            elif state == "failed":
                error = _redact(_text(item.get("err_msg")), config.token)
                # 契约 §1：失败项条目转 uncertain，不返还额度
                _ledger_transition(config, attempt_id, QUOTA_ENTRY_UNCERTAIN, batch_id=batch_id)
                results[source_id] = LifecycleItem(source_id, "failed", error=error)
                _append_state(config.state_path, source_id, batch_id, task_ids[source_id], "failed", error, attempt_id=attempt_id)
                pending.pop(source_id)

        if not pending:
            return
        if time.monotonic() >= deadline:
            for source_id in pending:
                results[source_id] = LifecycleItem(source_id, "pending_timeout")
                _append_state(config.state_path, source_id, batch_id, task_ids.get(source_id), "pending_timeout", attempt_id=_text(attempts.get(source_id)))
            return
        time.sleep(config.poll_interval_seconds)


def _record_stale_or_failed(
    config: LifecycleRunConfig,
    batch_id: str,
    sources: list[LifecycleSource],
    response: dict[str, Json],
    results: dict[str, LifecycleItem],
    attempts: dict[str, str] | None = None,
) -> None:
    attempts = attempts or {}
    status = "stale_pending" if response.get("code") == -60012 else "failed"
    next_action = "resubmit" if status == "stale_pending" else None
    error = _redact(_text(response.get("msg")), config.token)
    for source in sources:
        attempt_id = _text(attempts.get(source.source_id))
        if status == "stale_pending":
            # 契约 §1/§5：stale 不返还额度，条目转 uncertain；恢复侧转 manual_reconcile
            _ledger_transition(config, attempt_id, QUOTA_ENTRY_UNCERTAIN, batch_id=batch_id)
        results[source.source_id] = LifecycleItem(source.source_id, status, error=error, next_action=next_action)
        _append_state(config.state_path, source.source_id, batch_id, None, status, error, next_action, attempt_id=attempt_id)


def _complete_done_item(
    config: LifecycleRunConfig,
    source: LifecycleSource,
    batch_id: str,
    item: dict[str, Json],
    results: dict[str, LifecycleItem],
    attempt_id: str,
) -> None:
    task_id = _text(item.get("task_id"))
    # 服务端 done 即已计费：先确认额度（幂等），再落地产物
    _ledger_transition(config, attempt_id, QUOTA_ENTRY_CONFIRMED, batch_id=batch_id)
    try:
        raw_dir = _extract_zip_to_raw(config, source.source_id, _text(item.get("full_zip_url")))
    except ZipSafetyError as exc:
        error = _redact(str(exc), config.token)
        results[source.source_id] = LifecycleItem(source.source_id, "failed", error=error)
        _append_state(config.state_path, source.source_id, batch_id, task_id, "failed", error, attempt_id=attempt_id)
        return
    results[source.source_id] = _remap_raw_artifacts(raw_dir, config.output_root, source)
    _append_state(config.state_path, source.source_id, batch_id, task_id, "done", attempt_id=attempt_id)


def _extract_zip_to_raw(config: LifecycleRunConfig, source_id: str, zip_url: str) -> Path:
    limits = config.zip_limits
    raw_dir = config.audit_dir / "raw" / source_id
    # oracle H5：rmtree 前做真实路径 containment（防状态/批次被篡改后越界删除）
    raw_root = (config.audit_dir / "raw").resolve()
    if not SOURCE_ID_PATTERN.match(source_id) or not raw_dir.resolve().is_relative_to(raw_root):
        raise ZipSafetyError(f"raw dir escapes audit raw root: {source_id!r}")
    _assert_safe_download_url(zip_url)
    archive_bytes = config.client.get_bytes(zip_url)
    if len(archive_bytes) > limits.total_zip_bytes:
        raise ZipSafetyError(f"zip download {len(archive_bytes)} bytes exceeds limit {limits.total_zip_bytes}")

    raw_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = raw_dir.parent / f".staging-{source_id}-{uuid.uuid4().hex[:8]}"
    staging.mkdir(parents=True)
    try:
        _safe_extract_archive(io.BytesIO(archive_bytes), staging, limits)
        if raw_dir.exists():
            shutil.rmtree(raw_dir)
        staging.rename(raw_dir)
    finally:
        # 清理仅限自建临时目录（契约 §6）
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
    return raw_dir


def _validate_member_name(name: str) -> None:
    if not name:
        raise ZipSafetyError("empty member name rejected")
    if name.startswith("/") or PurePosixPath(name).is_absolute():
        raise ZipSafetyError(f"absolute member path rejected: {name!r}")
    if ":" in name:
        raise ZipSafetyError(f"drive/alternate-stream member path rejected: {name!r}")
    if "\\" in name:
        raise ZipSafetyError(f"backslash member path rejected: {name!r}")
    if "\x00" in name:
        raise ZipSafetyError(f"member name contains NUL: {name!r}")
    if ".." in PurePosixPath(name).parts:
        raise ZipSafetyError(f"path traversal member rejected: {name!r}")


_DOWNLOAD_FORBIDDEN_SUFFIXES: Final = (".local", ".internal", ".lan", ".home", ".corp", ".intranet")


def _assert_safe_download_url(url: str) -> None:
    """oracle O6：结果 ZIP 下载 URL 的词法级防护。

    仅允许 https、无 userinfo、主机非 IP 字面量、非内网惯用域名。
    DNS 级校验（解析地址须为公网）由桥接适配层执行——runner 不做解析，
    保证注入式测试使用假 URL 时不产生网络副作用。
    """
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise ZipSafetyError(f"download url scheme rejected (https only): {parts.scheme!r}")
    if parts.username or parts.password:
        raise ZipSafetyError("download url userinfo rejected")
    host = (parts.hostname or "").lower().rstrip(".")
    if not host:
        raise ZipSafetyError("download url host missing")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ZipSafetyError(f"download url ip-literal host rejected: {host}")
    if host == "localhost" or any(host.endswith(suffix) for suffix in _DOWNLOAD_FORBIDDEN_SUFFIXES):
        raise ZipSafetyError(f"download url internal host rejected: {host}")


def _safe_extract_archive(stream: io.BytesIO, target: Path, limits: ZipLimits) -> None:
    """契约 §6：流式实际计量（不信任 header 声明），四项限额 + 路径/symlink 防护。"""
    with zipfile.ZipFile(stream) as archive:
        infos = archive.infolist()
        if len(infos) > limits.max_members:
            raise ZipSafetyError(f"member count {len(infos)} exceeds limit {limits.max_members}")
        target_resolved = target.resolve()
        total_written = 0
        for info in infos:
            _validate_member_name(info.filename)
            if stat.S_ISLNK(info.external_attr >> 16):
                raise ZipSafetyError(f"symlink member rejected: {info.filename!r}")
            destination = target.joinpath(*PurePosixPath(info.filename).parts)
            if not destination.resolve().is_relative_to(target_resolved):
                raise ZipSafetyError(f"member escapes target dir: {info.filename!r}")
            if info.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            if info.file_size > limits.max_member_bytes:
                raise ZipSafetyError(
                    f"member declared size {info.file_size} exceeds limit {limits.max_member_bytes}: {info.filename!r}"
                )
            destination.parent.mkdir(parents=True, exist_ok=True)
            written = 0
            try:
                with archive.open(info) as member, destination.open("wb") as output:
                    while True:
                        chunk = member.read(ZIP_STREAM_CHUNK_BYTES)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > limits.max_member_bytes:
                            raise ZipSafetyError(
                                f"member expanded bytes {written} exceed limit {limits.max_member_bytes}: {info.filename!r}"
                            )
                        if total_written + written > limits.total_expanded_bytes:
                            raise ZipSafetyError(
                                f"total expanded bytes {total_written + written} exceed limit {limits.total_expanded_bytes}"
                            )
                        output.write(chunk)
            except zipfile.BadZipFile as exc:
                raise ZipSafetyError(f"corrupt or tampered member {info.filename!r}: {exc}") from exc
            if written != info.file_size:
                raise ZipSafetyError(
                    f"member size mismatch (declared {info.file_size}, actual {written}): {info.filename!r}"
                )
            total_written += written


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
