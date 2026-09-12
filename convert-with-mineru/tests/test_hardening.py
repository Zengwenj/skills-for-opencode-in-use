"""MinerU lifecycle runner 加固测试（契约 CONTRACTS-v1 §1/§5/§6）。

全部使用注入式 fake client，零真实网络调用；夹具均为临时目录合成数据。
"""

from __future__ import annotations

import importlib
import io
import json
import stat
import struct
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path


pytest = importlib.import_module("pytest")
module = importlib.import_module("scripts.mineru_lifecycle_runner")

Json = str | int | bool | None | list["Json"] | dict[str, "Json"]

FAKE_TOKEN = "secret-token-never-write"
SOURCE_ID = "src_hardening_0001"
SECOND_SOURCE_ID = "src_hardening_0002"
PRESIGNED_URL = "https://cdn.example/results/full.zip?X-Amz-Signature=deadbeef&Expires=9999"
UPLOAD_URL = f"https://upload.example/{SOURCE_ID}"


# ---------------------------------------------------------------- fakes / fixtures


@dataclass(slots=True)
class FakeClient:
    upload_responses: list[dict[str, Json]] = field(default_factory=list)
    poll_responses: list[dict[str, Json]] = field(default_factory=list)
    zip_by_url: dict[str, bytes] = field(default_factory=dict)
    calls: list[tuple[str, str]] = field(default_factory=list)
    lose_post_response: bool = False  # 服务端已接受请求，但响应丢失
    accepted_posts: int = 0
    post_payloads: list[dict[str, Json]] = field(default_factory=list)
    _poll_index: int = 0

    def post_json(self, target: str, payload: dict[str, Json], headers: dict[str, str]) -> dict[str, Json]:
        self.calls.append(("POST", target))
        self.post_payloads.append(payload)
        if self.lose_post_response:
            self.accepted_posts += 1
            raise RuntimeError("connection lost after server accepted request")
        if not self.upload_responses:
            raise AssertionError("unexpected POST without canned response")
        return self.upload_responses.pop(0)

    def put_bytes(self, target: str, body: bytes) -> None:
        self.calls.append(("PUT", target))

    def get_json(self, target: str, headers: dict[str, str]) -> dict[str, Json]:
        self.calls.append(("GET", target))
        if not self.poll_responses:
            return {"code": 0, "msg": "ok", "data": {"extract_result": []}}
        response = self.poll_responses[min(self._poll_index, len(self.poll_responses) - 1)]
        self._poll_index += 1
        return response

    def get_bytes(self, target: str) -> bytes:
        self.calls.append(("GET_BYTES", target))
        return self.zip_by_url[target]

    def count(self, method: str) -> int:
        return sum(1 for call in self.calls if call[0] == method)


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _yesterday() -> str:
    return (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")


def _ledger_document(
    limit: int = 100,
    *,
    timezone_known: bool = True,
    basis: str = "user_configured",
    billing: str | None = "per_page",
    epoch_date: str | None = None,
) -> dict[str, Json]:
    document: dict[str, Json] = {
        "schema_version": 1,
        "epoch": {
            "service_timezone_known": timezone_known,
            "epoch_date": epoch_date or _today(),
            "epoch_reset_basis": basis,
            "daily_page_limit": limit,
        },
        "reserved_pages": 0,
        "consumed_pages": 0,
        "uncertain_pages": 0,
        "entries": [],
    }
    if billing is not None:
        document["billing_basis"] = billing
    return document


def _ledger_with_reservation(attempt_id: str, pages: int = 12) -> dict[str, Json]:
    document = _ledger_document()
    document["reserved_pages"] = pages
    document["entries"] = [
        {
            "attempt_id": attempt_id,
            "batch_id": "",
            "source_ids": [SOURCE_ID],
            "reserved_pages": pages,
            "state": "reserved",
            "ts": "2026-09-10T00:00:00Z",
        }
    ]
    return document


def _ledger_path(tmp_path: Path) -> Path:
    return tmp_path / "audit" / "quota-ledger.json"


def _write_ledger(tmp_path: Path, document: dict[str, Json]) -> Path:
    path = _ledger_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def _load_ledger(tmp_path: Path) -> dict[str, Json]:
    return json.loads(_ledger_path(tmp_path).read_text(encoding="utf-8"))


def _state_path(tmp_path: Path) -> Path:
    return tmp_path / "audit" / "lifecycle-state.jsonl"


def _state_statuses(tmp_path: Path) -> list[str]:
    lines = _state_path(tmp_path).read_text(encoding="utf-8").splitlines()
    return [json.loads(line)["status"] for line in lines]


def _seed_state(tmp_path: Path, **record: Json) -> None:
    path = _state_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, Json] = {"source_id": SOURCE_ID}
    payload.update(record)
    path.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")


def _source(tmp_path: Path, source_id: str = SOURCE_ID, name: str = "report.pdf", pages: int | None = None):
    tmp_path.mkdir(parents=True, exist_ok=True)
    path = tmp_path / name
    path.write_bytes(b"%PDF-1.7 hardening fixture")
    return module.LifecycleSource(source_id=source_id, path=path, pages=pages)


def _upload_response(batch_id: str, source_ids: list[str]) -> dict[str, Json]:
    return {
        "code": 0,
        "msg": "ok",
        "data": {
            "batch_id": batch_id,
            "file_urls": [f"https://upload.example/{source_id}" for source_id in source_ids],
            "task_ids": {source_id: f"task-{source_id}" for source_id in source_ids},
        },
    }


def _poll_response(source_id: str, state: str, **extra: Json) -> dict[str, Json]:
    item: dict[str, Json] = {"data_id": source_id, "task_id": f"task-{source_id}", "state": state, **extra}
    return {"code": 0, "msg": "ok", "data": {"batch_id": "batch-1", "extract_result": [item]}}


def _zip_bytes(members: dict[str, bytes], compression: int = zipfile.ZIP_STORED) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression) as archive:
        for name, data in members.items():
            archive.writestr(name, data)
    return buffer.getvalue()


def _patch_central_size(zip_data: bytes, member_name: str, *, uncomp: int | None = None) -> bytes:
    """伪造 central directory 中成员的声明大小（local header 与实际数据保持原样）。"""
    data = bytearray(zip_data)
    signature = b"PK\x01\x02"
    index = 0
    while True:
        index = data.find(signature, index)
        if index < 0:
            break
        name_length = struct.unpack_from("<H", data, index + 28)[0]
        name = bytes(data[index + 46 : index + 46 + name_length]).decode("utf-8")
        if name == member_name and uncomp is not None:
            struct.pack_into("<I", data, index + 24, uncomp)
        index += 46 + name_length
    return bytes(data)


def _run(
    tmp_path: Path,
    client: FakeClient,
    *,
    sources=None,
    ledger_document: dict[str, Json] | None = None,
    ledger_path: Path | None = None,
    zip_limits: module.ZipLimits | None = None,
):
    sources = sources if sources is not None else [_source(tmp_path)]
    resolved_ledger = ledger_path or _write_ledger(tmp_path, ledger_document or _ledger_document())
    extra: dict[str, module.ZipLimits] = {}
    if zip_limits is not None:
        extra["zip_limits"] = zip_limits
    config = module.LifecycleRunConfig(
        sources=sources,
        output_root=tmp_path / "out",
        audit_dir=tmp_path / "audit",
        state_path=_state_path(tmp_path),
        token=FAKE_TOKEN,
        client=client,
        max_poll_seconds=1,
        poll_interval_seconds=0,
        quota_ledger_path=resolved_ledger,
        **extra,
    )
    return module.run_lifecycle(config)


def _healthy_client(source_id: str = SOURCE_ID, zip_data: bytes | None = None) -> FakeClient:
    zip_data = zip_data if zip_data is not None else _zip_bytes({"full.md": b"# Done\n", "content_list.json": b"[]"})
    url = "https://cdn.example/full.zip"
    return FakeClient(
        upload_responses=[_upload_response("batch-1", [source_id])],
        poll_responses=[_poll_response(source_id, "done", full_zip_url=url)],
        zip_by_url={url: zip_data},
    )


SMALL_ZIP_LIMITS = module.ZipLimits(total_zip_bytes=65536, max_member_bytes=64, total_expanded_bytes=128, max_members=3)


# ---------------------------------------------------------------- 1. intent 未落盘中断


def test_gate_refusal_before_intent_allows_fresh_prepare(tmp_path: Path):
    """额度 gate 拒绝发生在写 intent 之前：无 POST、无 submitting/uncertain 污染，修复后可全新提交。"""
    client = _healthy_client()
    bad_ledger = _ledger_document(timezone_known=False)

    summary = _run(tmp_path, client, sources=[_source(tmp_path, pages=10)], ledger_document=bad_ledger)

    assert client.count("POST") == 0
    assert summary.items[0].status == "quota_refused"
    assert _state_statuses(tmp_path) == ["quota_refused"]
    assert _load_ledger(tmp_path)["reserved_pages"] == 0
    assert _load_ledger(tmp_path)["entries"] == []

    summary_again = _run(tmp_path, client, sources=[_source(tmp_path, pages=10)], ledger_document=_ledger_document())

    assert client.count("POST") == 1
    assert summary_again.items[0].status == "done"
    assert "uncertain" not in _state_statuses(tmp_path)
    ledger = _load_ledger(tmp_path)
    assert ledger["consumed_pages"] == 10
    assert ledger["entries"][-1]["state"] == "confirmed"


# ---------------------------------------------------------------- 2. POST 结果未知 → uncertain


def test_post_accepted_response_lost_marks_uncertain_and_never_resubmits(tmp_path: Path):
    """POST 已被服务端接受但响应丢失：live 记 uncertain、额度不返还；重跑绝不自动重发。"""
    client = FakeClient(upload_responses=[_upload_response("batch-1", [SOURCE_ID])], lose_post_response=True)

    summary = _run(tmp_path, client, sources=[_source(tmp_path, pages=12)])

    assert client.accepted_posts == 1
    assert summary.items[0].status == "uncertain"
    assert summary.items[0].next_action == module.STATUS_MANUAL_RECONCILE
    statuses = _state_statuses(tmp_path)
    assert statuses == ["submitting", "uncertain"]
    ledger = _load_ledger(tmp_path)
    assert ledger["reserved_pages"] == 0
    assert ledger["uncertain_pages"] == 12
    assert ledger["entries"][-1]["state"] == "uncertain"

    healthy = _healthy_client()
    summary_again = _run(tmp_path, healthy, ledger_path=_ledger_path(tmp_path))

    assert healthy.count("POST") == 0
    assert summary_again.items[0].status == "uncertain"


def test_crash_after_intent_before_batch_persisted_recovers_as_uncertain(tmp_path: Path):
    """崩溃现场：submitting intent 与预留已落盘、batch 未落盘 → 恢复为 uncertain，不发 POST。"""
    attempt_id = "a" * 32
    _seed_state(tmp_path, attempt_id=attempt_id, batch_id="", status="submitting")
    client = _healthy_client()

    summary = _run(tmp_path, client, ledger_document=_ledger_with_reservation(attempt_id))

    assert client.calls == []
    assert summary.items[0].status == "uncertain"
    assert summary.items[0].next_action == module.STATUS_MANUAL_RECONCILE
    # 人工核查前预留额度保持占用（保守，防超发）
    ledger = _load_ledger(tmp_path)
    assert ledger["reserved_pages"] == 12
    assert ledger["entries"][-1]["state"] == "reserved"


# ---------------------------------------------------------------- 3. PUT 中途中断


def test_put_interrupted_after_batch_persisted_resumes_by_polling_only(tmp_path: Path):
    """PUT 中途中断但 batch_id 已落盘：恢复只 poll 对账续跑，不发新 POST/PUT。"""
    attempt_id = "b" * 32
    _seed_state(tmp_path, attempt_id=attempt_id, batch_id="batch-9", status="submitted")
    client = _healthy_client()

    summary = _run(tmp_path, client, ledger_document=_ledger_with_reservation(attempt_id))

    assert client.count("POST") == 0
    assert client.count("PUT") == 0
    assert client.count("GET") == 1
    assert summary.items[0].status == "done"
    ledger = _load_ledger(tmp_path)
    assert ledger["consumed_pages"] == 12
    assert ledger["entries"][-1]["state"] == "confirmed"
    assert ledger["entries"][-1]["batch_id"] == "batch-9"


# ---------------------------------------------------------------- 4. 已知 batch 只 poll


@pytest.mark.parametrize(
    "status",
    ["uploaded", "submitted", "waiting-file", "pending", "running", "converting", "pending_timeout"],
)
def test_known_batch_statuses_resume_poll_only_without_new_post(tmp_path: Path, status: str):
    attempt_id = "c" * 32
    _seed_state(tmp_path, attempt_id=attempt_id, batch_id="batch-1", status=status)
    client = _healthy_client()

    summary = _run(tmp_path, client, ledger_document=_ledger_with_reservation(attempt_id))

    assert client.count("POST") == 0
    assert client.count("PUT") == 0
    assert client.count("GET") == 1
    assert summary.items[0].status == "done"
    assert _load_ledger(tmp_path)["consumed_pages"] == 12


# ---------------------------------------------------------------- 5. stale_pending → manual_reconcile


def test_stale_pending_becomes_manual_reconcile_without_resubmit(tmp_path: Path):
    _seed_state(tmp_path, attempt_id="d" * 32, batch_id="batch-1", status="stale_pending")
    client = FakeClient()  # 任何 client 调用都会因无 canned 响应而失败

    summary = _run(tmp_path, client)

    assert client.calls == []
    assert summary.items[0].status == "manual_reconcile"
    assert summary.items[0].next_action is not None
    assert "authorization" in summary.items[0].next_action


# ---------------------------------------------------------------- 6. 额度边界（契约 §1 五个 fail-closed 条件）


def test_quota_exactly_at_limit_still_submits(tmp_path: Path):
    client = _healthy_client()

    summary = _run(tmp_path, client, sources=[_source(tmp_path, pages=100)], ledger_document=_ledger_document(limit=100))

    assert client.count("POST") == 1
    assert summary.items[0].status == "done"
    ledger = _load_ledger(tmp_path)
    assert ledger["consumed_pages"] == 100
    assert ledger["reserved_pages"] == 0


def test_quota_one_page_over_limit_refuses(tmp_path: Path):
    client = _healthy_client()

    summary = _run(tmp_path, client, sources=[_source(tmp_path, pages=101)], ledger_document=_ledger_document(limit=100))

    assert client.count("POST") == 0
    assert summary.items[0].status == "quota_refused"
    ledger = _load_ledger(tmp_path)
    assert ledger["reserved_pages"] == 0
    assert ledger["entries"] == []


def test_quota_unknown_timezone_refuses(tmp_path: Path):
    client = _healthy_client()

    summary = _run(tmp_path, client, ledger_document=_ledger_document(timezone_known=False))

    assert client.count("POST") == 0
    assert summary.items[0].status == "quota_refused"
    assert "timezone" in (summary.items[0].error or "")


@pytest.mark.parametrize("billing", ["per_file", None])
def test_quota_unclear_billing_basis_refuses(tmp_path: Path, billing):
    client = _healthy_client()

    summary = _run(tmp_path, client, ledger_document=_ledger_document(billing=billing))

    assert client.count("POST") == 0
    assert summary.items[0].status == "quota_refused"
    assert "billing" in (summary.items[0].error or "")


def test_quota_epoch_misaligned_refuses(tmp_path: Path):
    """账本 epoch 是昨日：当日剩余未知 → 拒绝提交。"""
    client = _healthy_client()

    summary = _run(tmp_path, client, ledger_document=_ledger_document(epoch_date=_yesterday()))

    assert client.count("POST") == 0
    assert summary.items[0].status == "quota_refused"
    assert "aligned" in (summary.items[0].error or "")


def test_quota_missing_ledger_file_refuses(tmp_path: Path):
    client = _healthy_client()

    summary = _run(tmp_path, client, ledger_path=tmp_path / "audit" / "missing-ledger.json")

    assert client.count("POST") == 0
    assert summary.items[0].status == "quota_refused"
    assert "ledger" in (summary.items[0].error or "")


def test_failed_pages_are_not_returned(tmp_path: Path):
    """失败项记 uncertain 不返还：60 页失败后，41 页被拒、40 页恰好放行。"""
    failed_client = FakeClient(
        upload_responses=[_upload_response("batch-1", [SOURCE_ID])],
        poll_responses=[_poll_response(SOURCE_ID, "failed", err_msg="broken")],
    )
    _run(tmp_path, failed_client, sources=[_source(tmp_path, pages=60)])
    assert _load_ledger(tmp_path)["uncertain_pages"] == 60

    refused_client = _healthy_client(SECOND_SOURCE_ID)
    summary_refused = _run(
        tmp_path,
        refused_client,
        sources=[_source(tmp_path, SECOND_SOURCE_ID, "second.pdf", pages=41)],
        ledger_path=_ledger_path(tmp_path),
    )
    assert refused_client.count("POST") == 0
    assert summary_refused.items[0].status == "quota_refused"

    allowed_client = _healthy_client(SECOND_SOURCE_ID)
    summary_allowed = _run(
        tmp_path,
        allowed_client,
        sources=[_source(tmp_path, SECOND_SOURCE_ID, "second.pdf", pages=40)],
        ledger_path=_ledger_path(tmp_path),
    )
    assert allowed_client.count("POST") == 1
    assert summary_allowed.items[0].status == "done"
    ledger = _load_ledger(tmp_path)
    assert ledger["uncertain_pages"] == 60
    assert ledger["consumed_pages"] == 40


# ---------------------------------------------------------------- 7. ZIP 防护（契约 §6）


def _run_zip_case(tmp_path: Path, zip_data: bytes, limits: module.ZipLimits):
    client = _healthy_client(zip_data=zip_data)
    summary = _run(tmp_path, client, zip_limits=limits)
    return summary, client


def _assert_no_partial_done(tmp_path: Path) -> None:
    assert not (tmp_path / "out" / f"{SOURCE_ID}.md").exists()
    assert not (tmp_path / "audit" / "raw" / SOURCE_ID / "full.md").exists()
    staging = [p for p in (tmp_path / "audit" / "raw").glob(".staging-*")] if (tmp_path / "audit" / "raw").exists() else []
    assert staging == []


def test_zip_member_count_at_limit_passes_over_fails(tmp_path: Path):
    ok = _zip_bytes({"full.md": b"# H\n", "a.json": b"{}", "b.json": b"{}"})
    summary, _ = _run_zip_case(tmp_path / "ok", ok, SMALL_ZIP_LIMITS)
    assert summary.items[0].status == "done"

    bad = _zip_bytes({"full.md": b"# H\n", "a.json": b"{}", "b.json": b"{}", "c.json": b"{}"})
    summary_bad, _ = _run_zip_case(tmp_path / "bad", bad, SMALL_ZIP_LIMITS)
    assert summary_bad.items[0].status == "failed"
    assert "member count" in (summary_bad.items[0].error or "")
    _assert_no_partial_done(tmp_path / "bad")


def test_zip_member_size_at_limit_passes_over_fails(tmp_path: Path):
    ok = _zip_bytes({"full.md": b"# " + b"a" * 62})  # 恰好 64 字节
    summary, _ = _run_zip_case(tmp_path / "ok", ok, SMALL_ZIP_LIMITS)
    assert summary.items[0].status == "done"

    bad = _zip_bytes({"full.md": b"# " + b"a" * 63})  # 65 字节，超限 1
    summary_bad, _ = _run_zip_case(tmp_path / "bad", bad, SMALL_ZIP_LIMITS)
    assert summary_bad.items[0].status == "failed"
    _assert_no_partial_done(tmp_path / "bad")


def test_zip_total_expanded_at_limit_passes_over_fails(tmp_path: Path):
    limits = module.ZipLimits(total_zip_bytes=65536, max_member_bytes=64, total_expanded_bytes=100, max_members=3)
    ok = _zip_bytes({"full.md": b"x" * 64, "extra.json": b"y" * 36})  # 64+36 = 100
    summary, _ = _run_zip_case(tmp_path / "ok", ok, limits)
    assert summary.items[0].status == "done"

    bad = _zip_bytes({"full.md": b"x" * 64, "extra.json": b"y" * 37})  # 64+37 = 101 > 100
    summary_bad, _ = _run_zip_case(tmp_path / "bad", bad, limits)
    assert summary_bad.items[0].status == "failed"
    assert "total expanded" in (summary_bad.items[0].error or "")
    _assert_no_partial_done(tmp_path / "bad")


def test_zip_download_bytes_over_limit_rejected(tmp_path: Path):
    limits = module.ZipLimits(total_zip_bytes=8, max_member_bytes=64, total_expanded_bytes=128, max_members=3)
    summary_bad, _ = _run_zip_case(tmp_path, _zip_bytes({"full.md": b"# H\n"}), limits)
    assert summary_bad.items[0].status == "failed"
    assert "exceeds limit" in (summary_bad.items[0].error or "")
    _assert_no_partial_done(tmp_path)


def test_zip_forged_declared_size_over_limit_rejected(tmp_path: Path):
    """伪造 header 声明超限（实际数据仅 40 字节）：预检即拒绝，不信任声明。"""
    honest = _zip_bytes({"full.md": b"A" * 40})
    forged = _patch_central_size(honest, "full.md", uncomp=5000)
    summary, _ = _run_zip_case(tmp_path, forged, SMALL_ZIP_LIMITS)
    assert summary.items[0].status == "failed"
    assert "declared size" in (summary.items[0].error or "")
    _assert_no_partial_done(tmp_path)


def test_zip_forged_size_mismatch_rejected(tmp_path: Path):
    """伪造 header 声明 50 字节、实际 40 字节（两者都低于限额）：实际计数与声明不符即拒绝。"""
    honest = _zip_bytes({"full.md": b"B" * 40})
    forged = _patch_central_size(honest, "full.md", uncomp=50)
    summary, _ = _run_zip_case(tmp_path, forged, SMALL_ZIP_LIMITS)
    assert summary.items[0].status == "failed"
    assert "size mismatch" in (summary.items[0].error or "")
    _assert_no_partial_done(tmp_path)


@pytest.mark.parametrize(
    "member_name",
    ["../evil.txt", "a/../../evil.txt", "/etc/passwd", "C:/evil.txt"],
)
def test_zip_path_traversal_members_rejected(tmp_path: Path, member_name: str):
    zip_data = _zip_bytes({member_name: b"evil", "full.md": b"# H\n"})
    summary, _ = _run_zip_case(tmp_path, zip_data, SMALL_ZIP_LIMITS)
    assert summary.items[0].status == "failed"
    _assert_no_partial_done(tmp_path)
    assert not (tmp_path / "audit" / "evil.txt").exists()


def test_zip_backslash_member_name_rejected():
    """Windows 上 zipfile 写入时会把 os.sep 规范化为 /，无法通过 writestr 构造，
    直接对解析层防线做单元验证（真实攻击来自手工构造的 zip 字节）。"""
    with pytest.raises(module.ZipSafetyError):
        module._validate_member_name("dir\\evil.txt")


def test_zip_symlink_member_rejected(tmp_path: Path):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        info = zipfile.ZipInfo("link.txt")
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(info, b"target-file")
        archive.writestr("full.md", b"# H\n")
    summary, _ = _run_zip_case(tmp_path, buffer.getvalue(), SMALL_ZIP_LIMITS)
    assert summary.items[0].status == "failed"
    assert "symlink" in (summary.items[0].error or "")
    _assert_no_partial_done(tmp_path)


def test_zip_rejection_still_confirms_consumed_pages(tmp_path: Path):
    """ZIP 被拒时服务端已计费：额度按 consumed 结算，不冒充 done。"""
    zip_data = _zip_bytes({"full.md": b"# H\n", "a.json": b"{}", "b.json": b"{}", "c.json": b"{}"})
    summary, _ = _run_zip_case(tmp_path, zip_data, SMALL_ZIP_LIMITS)
    assert summary.items[0].status == "failed"
    ledger = _load_ledger(tmp_path)
    assert ledger["consumed_pages"] == 1  # junk PDF 保守按 1 页预留
    assert ledger["reserved_pages"] == 0


# ---------------------------------------------------------------- 8. 脱敏（token + 预签名 URL）


def test_presigned_url_and_token_redacted_from_state_and_ledger(tmp_path: Path):
    client = FakeClient(
        upload_responses=[_upload_response("batch-1", [SOURCE_ID])],
        poll_responses=[
            _poll_response(SOURCE_ID, "failed", err_msg=f"failed after fetching {PRESIGNED_URL} with {FAKE_TOKEN}")
        ],
    )

    summary = _run(tmp_path, client)

    item = summary.items[0]
    assert FAKE_TOKEN not in (item.error or "")
    assert "https://" not in (item.error or "")
    state_text = _state_path(tmp_path).read_text(encoding="utf-8")
    assert FAKE_TOKEN not in state_text
    assert PRESIGNED_URL not in state_text
    assert "https://" not in state_text
    ledger_text = _ledger_path(tmp_path).read_text(encoding="utf-8")
    assert FAKE_TOKEN not in ledger_text
    assert "https://" not in ledger_text


def test_done_flow_never_persists_urls_in_state(tmp_path: Path):
    url = PRESIGNED_URL
    client = FakeClient(
        upload_responses=[_upload_response("batch-1", [SOURCE_ID])],
        poll_responses=[_poll_response(SOURCE_ID, "done", full_zip_url=url)],
        zip_by_url={url: _zip_bytes({"full.md": b"# Done\n"})},
    )

    summary = _run(tmp_path, client)

    assert summary.items[0].status == "done"
    state_text = _state_path(tmp_path).read_text(encoding="utf-8")
    assert "http" not in state_text
    assert FAKE_TOKEN not in state_text


# ---------------------------------------------------------------- fail-closed 配置


def test_config_requires_quota_ledger_path(tmp_path: Path):
    """旧调用方不传额度账本必须显式失败——不存在默认放行的兼容路径。"""
    with pytest.raises(TypeError):
        module.LifecycleRunConfig(
            sources=[_source(tmp_path)],
            output_root=tmp_path / "out",
            audit_dir=tmp_path / "audit",
            state_path=_state_path(tmp_path),
            token=FAKE_TOKEN,
            client=FakeClient(),
            max_poll_seconds=1,
            poll_interval_seconds=0,
        )


# --------------------------------- oracle 补审回归（2026-09-12）---------------------------------


def test_authorization_divergent_blocks_submission(tmp_path: Path):
    """oracle C1：批准哈希不符 → 零 POST、零 PUT、零预留，状态 authorization_divergent。"""
    base = _source(tmp_path, pages=5)
    tampered = module.LifecycleSource(
        source_id=base.source_id, path=base.path, pages=5, expected_sha256="0" * 64
    )
    client = _healthy_client()

    summary = _run(tmp_path, client, sources=[tampered])

    assert client.count("POST") == 0
    assert client.count("PUT") == 0
    assert summary.items[0].status == "authorization_divergent"
    assert summary.items[0].next_action == module.STATUS_MANUAL_RECONCILE
    assert _load_ledger(tmp_path)["reserved_pages"] == 0
    assert _state_statuses(tmp_path) == ["authorization_divergent"]


def test_authorization_matching_hash_allows_submission(tmp_path: Path):
    """oracle C1 对照组：批准哈希一致 → 正常提交。"""
    base = _source(tmp_path, pages=5)
    import hashlib as _hashlib

    approved = module.LifecycleSource(
        source_id=base.source_id,
        path=base.path,
        pages=5,
        expected_sha256=_hashlib.sha256(base.path.read_bytes()).hexdigest(),
    )
    client = _healthy_client()

    summary = _run(tmp_path, client, sources=[approved])

    assert summary.items[0].status == "done"
    assert client.count("POST") == 1


def test_quota_hard_cap_above_1000_refuses(tmp_path: Path):
    """oracle H4：账本 daily_page_limit 超 1000 硬上限即拒绝（防手改账本放宽）。"""
    with pytest.raises(module.QuotaGateError, match="hard cap"):
        module._quota_gate(_ledger_document(limit=1001), 5)


def test_quota_zero_requested_pages_refuses(tmp_path: Path):
    """oracle H4：零/负页请求拒绝（零页不产生有效预留）。"""
    with pytest.raises(module.QuotaGateError, match="positive"):
        module._quota_gate(_ledger_document(), 0)
    with pytest.raises(module.QuotaGateError, match="positive"):
        module._quota_gate(_ledger_document(), -3)


def test_unsafe_source_id_rejected_before_any_path_use(tmp_path: Path):
    """oracle H5：含路径语义的 source_id 在进入路径拼接前被拒。"""
    for bad_id in ("../evil", "a/b", "a\b", "", ".hidden", "sp ace"):
        with pytest.raises(ValueError, match="unsafe source_id"):
            base = _source(tmp_path)
            _run(
                tmp_path,
                _healthy_client(),
                sources=[module.LifecycleSource(source_id=bad_id, path=base.path, pages=1)],
            )


def test_unknown_status_becomes_manual_reconcile(tmp_path: Path):
    """oracle B-S4：未识别状态 → 人工对账，绝不落入重新提交。"""
    _seed_state(tmp_path, status="weird_future_status")
    client = _healthy_client()

    summary = _run(tmp_path, client)

    assert client.count("POST") == 0
    assert summary.items[0].status == module.STATUS_MANUAL_RECONCILE


def test_done_without_artifacts_or_batch_manual_reconcile(tmp_path: Path):
    """oracle B-S4：done 但产物与 batch 双缺失 → 人工对账，不得重发。"""
    _seed_state(tmp_path, status="done")
    client = _healthy_client()

    summary = _run(tmp_path, client)

    assert client.count("POST") == 0
    assert summary.items[0].status == module.STATUS_MANUAL_RECONCILE


def test_poll_exception_yields_poll_error_without_crash(tmp_path: Path):
    """oracle M9：轮询网络异常不裸抛，条目转 poll_error（下轮只 poll），错误已脱敏。"""
    import os as _os

    class ExplodingClient(FakeClient):
        def get_json(self, target, headers):
            self.calls.append(("GET", target))
            raise RuntimeError(f"poll boom url=https://x/y?sig={FAKE_TOKEN}")

    _seed_state(tmp_path, status="submitted", batch_id="batch-1")
    client = ExplodingClient()

    summary = _run(tmp_path, client)

    assert client.count("POST") == 0
    assert summary.items[0].status == "poll_error"
    assert FAKE_TOKEN not in (summary.items[0].error or "")
    assert "poll_error" in _state_statuses(tmp_path)
    state_text = _state_path(tmp_path).read_text(encoding="utf-8")
    assert FAKE_TOKEN not in state_text
    assert _os is not None


HOLD_LOCK_SNIPPET = """
import msvcrt, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR)
msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
print("held", flush=True)
time.sleep(float(sys.argv[2]))
"""


def test_lock_held_by_live_process_blocks_until_timeout(tmp_path: Path):
    """oracle B3：持有者进程存活期间，另一进程在超时内拿不到锁。"""
    import subprocess
    import sys

    lock = tmp_path / "q.lock"
    holder = subprocess.Popen(
        [sys.executable, "-c", HOLD_LOCK_SNIPPET, str(lock), "5"],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        assert holder.stdout.readline().strip() == "held"  # 持锁已确认
        with pytest.raises(TimeoutError):
            with module._file_lock(lock, timeout_seconds=1.0):
                pass
    finally:
        holder.kill()
        holder.wait()


def test_lock_auto_released_when_holder_process_dies(tmp_path: Path):
    """oracle B3：持有者进程死亡后，锁由内核自动释放——无需任何接管逻辑即可获取。"""
    import subprocess
    import sys

    lock = tmp_path / "q.lock"
    holder = subprocess.Popen(
        [sys.executable, "-c", HOLD_LOCK_SNIPPET, str(lock), "30"],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        assert holder.stdout.readline().strip() == "held"
    finally:
        holder.kill()  # 模拟崩溃：不给释放机会
        holder.wait()
    with module._file_lock(lock, timeout_seconds=5.0):
        pass  # 能进入即证明内核已自动释放


def test_lock_is_exclusive_between_two_local_contexts(tmp_path: Path):
    """同进程两个上下文（不同 fd）互斥：内层拿不到外层持有的锁。"""
    import threading

    lock = tmp_path / "q.lock"
    acquired_inner = []

    def try_inner():
        try:
            with module._file_lock(lock, timeout_seconds=0.5):
                acquired_inner.append(True)
        except TimeoutError:
            acquired_inner.append(False)

    with module._file_lock(lock):
        thread = threading.Thread(target=try_inner)
        thread.start()
        thread.join()

    assert acquired_inner == [False]


def test_quota_lock_binds_ledger_not_state(tmp_path: Path):
    """oracle H4：锁路径绑定账本文件，两个不同 state 共账本时共用同一把锁。"""
    from dataclasses import replace

    base = _source(tmp_path)
    common = dict(
        sources=[base],
        output_root=tmp_path / "out",
        audit_dir=tmp_path / "audit",
        token="t",
        client=FakeClient(),
        max_poll_seconds=1,
        poll_interval_seconds=0,
        quota_ledger_path=tmp_path / "shared" / "quota-ledger.json",
    )
    cfg_a = module.LifecycleRunConfig(state_path=tmp_path / "state-a.jsonl", **common)
    cfg_b = module.LifecycleRunConfig(state_path=tmp_path / "state-b.jsonl", **common)
    assert cfg_a.sources == cfg_b.sources
    assert module._quota_lock_path(cfg_a) == module._quota_lock_path(cfg_b)
    assert module._quota_lock_path(cfg_a).name == "quota-ledger.json.lock"


def test_submit_chunk_drops_sources_advanced_by_concurrent_run(tmp_path: Path):
    """oracle H4（并发）：锁内复核最新状态，已被并发进程推进的条目绝不重复 POST。"""
    src = _source(tmp_path, pages=5)
    _seed_state(tmp_path, status="submitted", batch_id="batch-9")
    ledger_path = _write_ledger(tmp_path, _ledger_document())
    client = _healthy_client()
    config = module.LifecycleRunConfig(
        sources=[src],
        output_root=tmp_path / "out",
        audit_dir=tmp_path / "audit",
        state_path=_state_path(tmp_path),
        token=FAKE_TOKEN,
        client=client,
        max_poll_seconds=1,
        poll_interval_seconds=0,
        quota_ledger_path=ledger_path,
    )
    results: dict[str, module.LifecycleItem] = {}
    module._submit_chunk(config, [src], "vlm", results)

    assert client.count("POST") == 0
    assert results[src.source_id].status == module.STATUS_MANUAL_RECONCILE
    assert _load_ledger(tmp_path)["reserved_pages"] == 0


# --------------------------------- oracle O6：下载 URL 防护 ---------------------------------


def test_download_url_lexical_guards():
    """oracle O6：词法层拒绝 http/IP 字面量/内网域名/userinfo；接受正常 https 域名。"""
    bad = [
        "http://cdn.example/full.zip",
        "https://127.0.0.1/full.zip",
        "https://192.168.1.5/full.zip",
        "https://10.0.0.1/full.zip",
        "https://localhost/full.zip",
        "https://results.internal/full.zip",
        "https://user:pass@cdn.example/full.zip",
        "ftp://cdn.example/full.zip",
        "https:///full.zip",
        "not-a-url",
    ]
    for url in bad:
        with pytest.raises(module.ZipSafetyError):
            module._assert_safe_download_url(url)
    module._assert_safe_download_url("https://cdn.example/results/full.zip?X-Amz-Signature=abc")


def test_zip_download_rejects_unsafe_url_before_any_request(tmp_path: Path):
    """oracle O6：内网下载地址在发起 get_bytes 前即被拒（零网络副作用）。"""
    _seed_state(tmp_path, status="submitted", batch_id="batch-1")
    evil_url = "https://192.168.0.9/evil.zip"
    client = FakeClient(
        upload_responses=[_upload_response("batch-1", [SOURCE_ID])],
        poll_responses=[_poll_response(SOURCE_ID, "done", full_zip_url=evil_url)],
        zip_by_url={evil_url: b"PK"},
    )

    summary = _run(tmp_path, client)

    assert summary.items[0].status == "failed"
    assert "ip-literal" in (summary.items[0].error or "") or "rejected" in (summary.items[0].error or "")
    assert ("GET_BYTES", "https://192.168.0.9/evil.zip") not in client.calls


def test_partial_drop_rebuilds_post_payload_and_reservation(tmp_path: Path):
    """oracle B2：并发丢弃部分条目后，POST 载荷/指纹/预留必须只含存活条目。"""
    src_a = _source(tmp_path, source_id=SOURCE_ID, name="a.pdf", pages=5)
    src_b = _source(tmp_path, source_id=SECOND_SOURCE_ID, name="b.pdf", pages=7)
    # 仅 a 已被并发进程推进（submitted + batch），b 仍是全新
    _seed_state(tmp_path, status="submitted", batch_id="batch-9")

    url = "https://cdn.example/full.zip"
    client = FakeClient(
        upload_responses=[_upload_response("batch-1", [SECOND_SOURCE_ID])],
        poll_responses=[_poll_response(SECOND_SOURCE_ID, "done", full_zip_url=url)],
        zip_by_url={url: _zip_bytes({"full.md": b"# Done\n"})},
    )
    ledger_path = _write_ledger(tmp_path, _ledger_document())
    config = module.LifecycleRunConfig(
        sources=[src_a, src_b],
        output_root=tmp_path / "out",
        audit_dir=tmp_path / "audit",
        state_path=_state_path(tmp_path),
        token=FAKE_TOKEN,
        client=client,
        max_poll_seconds=1,
        poll_interval_seconds=0,
        quota_ledger_path=ledger_path,
    )
    results: dict[str, module.LifecycleItem] = {}
    module._submit_chunk(config, [src_a, src_b], "vlm", results)

    assert client.count("POST") == 1
    posted = client.post_payloads[0]
    assert [f["data_id"] for f in posted["files"]] == [SECOND_SOURCE_ID], "POST 载荷必须只含存活条目"
    ledger = _load_ledger(tmp_path)
    # poll 即返回 done：条目已从 reserved 流转为 confirmed，核对终态条目即可
    assert len(ledger["entries"]) == 1
    assert ledger["entries"][0]["source_ids"] == [SECOND_SOURCE_ID]
    assert ledger["entries"][0]["reserved_pages"] == 7
    assert ledger["entries"][0]["state"] == "confirmed"
    assert ledger["consumed_pages"] == 7
    assert results[src_a.source_id].status == module.STATUS_MANUAL_RECONCILE
