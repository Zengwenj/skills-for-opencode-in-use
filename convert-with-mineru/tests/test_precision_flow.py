import inspect
import io
import json
import zipfile
from pathlib import Path

import pytest

from scripts.mineru_manifest import PER_FILE_MANIFEST_FIELDS
from scripts.mineru_precision import convert_files, persist_precision_result


class FakeResult:
    def __init__(self):
        self.markdown = "# ok\n\n![](images/img1.png)\n"
        self.content_list = [{"type": "text", "text": "hello"}]
        self._zip_bytes = self._make_zip_bytes()
        self.save_all_calls: list[Path] = []

    def save_markdown(self, path: str, with_images: bool = True):
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(self.markdown, encoding="utf-8")
        if with_images:
            images = target.parent / "images"
            images.mkdir(exist_ok=True)
            (images / "img1.png").write_bytes(b"png")
        return target

    def save_all(self, directory: str):
        target = Path(directory)
        self.save_all_calls.append(target)
        target.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(self._zip_bytes)) as zf:
            zf.extractall(target)
        return target

    @staticmethod
    def _make_zip_bytes() -> bytes:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as zf:
            zf.writestr("full.md", "# ok\n\n![](images/img1.png)\n")
            zf.writestr("report_content_list.json", '[{"type":"text","text":"hello"}]')
            zf.writestr("report_content_list_v2.json", '{"version": 2}')
            zf.writestr("model.json", '{"pages": 1}')
            zf.writestr("layout.json", '{"blocks": []}')
            zf.writestr("report_origin.pdf", b"pdf")
            zf.writestr("images/img1.png", b"png")
        return buffer.getvalue()


class FakeResultWithoutImages(FakeResult):
    def save_markdown(self, path: str, with_images: bool = True):
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(self.markdown, encoding="utf-8")
        return target


class FakeResultWithEmptyImages(FakeResult):
    def save_markdown(self, path: str, with_images: bool = True):
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(self.markdown, encoding="utf-8")
        if with_images:
            (target.parent / "images").mkdir(exist_ok=True)
        return target


def test_persist_precision_result_writes_source_named_outputs(tmp_path: Path):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=True
    )

    assert targets.json_dir is not None
    assert (
        targets.markdown.read_text(encoding="utf-8")
        == "# ok\n\n![](report.images/img1.png)\n"
    )
    assert targets.json_dir.name == "report.json"
    assert (
        targets.json_files["content_list"].read_text(encoding="utf-8").startswith("[")
    )
    assert (
        targets.json_files["content_list_v2"].read_text(encoding="utf-8")
        == '{\n  "version": 2\n}'
    )
    assert (targets.images_dir / "img1.png").read_bytes() == b"png"
    assert (tmp_path / "out" / "report.raw").exists() is False
    assert targets.manifest.exists() is False


def test_persist_precision_result_writes_manifest_and_archives_raw_stage(
    tmp_path: Path,
):
    source = tmp_path / "report.pdf"
    result = FakeResult()
    audit_dir = tmp_path / "_review"

    targets = persist_precision_result(
        source,
        result,
        tmp_path / "out",
        audit_dir=audit_dir,
        batch_id="fixed",
    )

    assert targets.manifest.exists()
    manifest = json.loads(targets.manifest.read_text(encoding="utf-8"))
    assert set(PER_FILE_MANIFEST_FIELDS).issubset(manifest.keys())
    assert manifest["batch_id"] == "fixed"
    assert manifest["allocated_stem"] == "report"
    assert manifest["route"] == "mineru"
    assert manifest["model"] == "default"
    assert manifest["conversion_status"] == "success"
    assert manifest["quality_gate"] == {
        "status": "not_run",
        "passed": None,
        "failed_gates": [],
    }
    assert manifest["raw_archive_status"] == "archived"
    assert manifest["image_status"] == "ok"
    assert manifest["image_count"] == 1

    for field in (
        "output_md",
        "output_json_dir",
        "output_images_dir",
        "per_file_manifest",
        "raw_archive_path",
    ):
        assert manifest[field]
        assert "\\" not in manifest[field]

    assert manifest["per_file_manifest"] == str(targets.manifest).replace("\\", "/")

    raw_archive = Path(manifest["raw_archive_path"])
    assert raw_archive.exists()
    assert raw_archive == audit_dir / "raw" / "report"
    assert (raw_archive / "full.md").exists()
    assert (raw_archive / "layout.json").exists()
    assert (raw_archive / "model.json").exists()
    assert (raw_archive / "images" / "img1.png").read_bytes() == b"png"
    assert (raw_archive / "report_origin.pdf").read_bytes() == b"pdf"

    assert targets.json_dir is not None
    assert {path.name for path in targets.json_dir.iterdir()} == {
        "report.content_list.json",
        "report.content_list_v2.json",
        "report.layout.json",
        "report.model.json",
    }
    assert (tmp_path / "out" / "report.raw").exists() is False

    save_all_by_name = {path.name: path for path in result.save_all_calls}
    assert {"json", "raw"}.issubset(save_all_by_name)
    assert save_all_by_name["raw"].parent == save_all_by_name["json"].parent


def test_persist_precision_result_skips_manifest_and_raw_archive_without_audit_dir(
    tmp_path: Path,
):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    targets = persist_precision_result(source, result, tmp_path / "out")

    assert targets.manifest.exists() is False
    assert (tmp_path / "_review").exists() is False
    assert [path.name for path in result.save_all_calls] == ["json"]


def test_persist_precision_result_manifest_records_no_images_produced(
    tmp_path: Path,
):
    source = tmp_path / "report.pdf"

    targets = persist_precision_result(
        source,
        FakeResultWithoutImages(),
        tmp_path / "out",
        audit_dir=tmp_path / "_review",
        batch_id="fixed",
    )

    manifest = json.loads(targets.manifest.read_text(encoding="utf-8"))
    assert manifest["conversion_status"] == "success"
    assert manifest["image_status"] == "none_produced"
    assert manifest["image_count"] == 0


def test_persist_precision_result_manifest_records_empty_images_dir(tmp_path: Path):
    source = tmp_path / "report.pdf"

    targets = persist_precision_result(
        source,
        FakeResultWithEmptyImages(),
        tmp_path / "out",
        audit_dir=tmp_path / "_review",
        batch_id="fixed",
    )

    manifest = json.loads(targets.manifest.read_text(encoding="utf-8"))
    assert manifest["conversion_status"] == "success"
    assert manifest["image_status"] == "empty"
    assert manifest["image_count"] == 0


def test_persist_precision_result_manifest_records_path_too_long_raw_archive(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_manifest as manifest_module

    source = tmp_path / "report.pdf"
    result = FakeResult()
    audit_dir = tmp_path / ("a" * 100) / ("b" * 100) / ("c" * 100)

    monkeypatch.setattr(manifest_module.os, "name", "nt")

    targets = persist_precision_result(
        source,
        result,
        tmp_path / "out",
        audit_dir=audit_dir,
        batch_id="fixed",
    )

    manifest = json.loads(targets.manifest.read_text(encoding="utf-8"))
    assert targets.markdown.read_text(encoding="utf-8") == "# ok\n\n![](report.images/img1.png)\n"
    assert manifest["conversion_status"] == "success"
    assert manifest["raw_archive_status"] == "path_too_long"
    assert manifest["raw_archive_path"] is None


def test_persist_precision_result_manifest_records_failed_raw_archive_when_audit_dir_creation_fails(
    monkeypatch, tmp_path: Path
):
    import pathlib

    source = tmp_path / "report.pdf"
    result = FakeResult()
    audit_dir = tmp_path / "audit"
    original_mkdir = pathlib.Path.mkdir

    def fail_raw_archive_parent_mkdir(self, *args, **kwargs):
        if self == audit_dir / "raw":
            raise PermissionError("audit denied")
        return original_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(pathlib.Path, "mkdir", fail_raw_archive_parent_mkdir)

    targets = persist_precision_result(
        source,
        result,
        tmp_path / "out",
        audit_dir=audit_dir,
        batch_id="fixed",
    )

    manifest = json.loads(targets.manifest.read_text(encoding="utf-8"))
    assert targets.markdown.exists()
    assert targets.json_files["content_list"].exists()
    assert (targets.images_dir / "img1.png").exists()
    assert manifest["conversion_status"] == "success"
    assert manifest["raw_archive_status"] == "failed"
    assert manifest["raw_archive_path"] is None


def test_persist_precision_result_keeps_content_list_in_source_json(tmp_path: Path):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=True
    )

    assert (
        targets.json_files["content_list"].read_text(encoding="utf-8")
        == '[\n  {\n    "type": "text",\n    "text": "hello"\n  }\n]'
    )
    assert (
        targets.json_files["content_list_v2"].read_text(encoding="utf-8")
        == '{\n  "version": 2\n}'
    )
    assert (
        targets.json_files["layout"].read_text(encoding="utf-8")
        == '{\n  "blocks": []\n}'
    )
    assert (
        targets.json_files["model"].read_text(encoding="utf-8") == '{\n  "pages": 1\n}'
    )
    assert (tmp_path / "out" / "report.raw").exists() is False
    assert (tmp_path / "out" / "report.json" / "report_origin.pdf").exists() is False


def test_existing_contract_rewrites_images_prefix_to_stem_images(tmp_path: Path):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=True
    )

    markdown = targets.markdown.read_text(encoding="utf-8")
    assert "![](report.images/img1.png)" in markdown
    assert "![](images/img1.png)" not in markdown


def test_existing_contract_copies_image_into_stem_images_dir(tmp_path: Path):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=True
    )

    assert targets.images_dir.name == "report.images"
    assert (targets.images_dir / "img1.png").exists()
    assert (targets.images_dir / "img1.png").read_bytes() == b"png"


def test_existing_contract_writes_four_json_artifacts_to_stem_json_dir(
    tmp_path: Path,
):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=True
    )
    assert targets.json_dir is not None
    json_dir = targets.json_dir

    assert json_dir.name == "report.json"
    assert {"content_list", "content_list_v2", "layout", "model"}.issubset(
        targets.json_files.keys()
    )
    for json_type in ("content_list", "content_list_v2", "layout", "model"):
        assert targets.json_files[json_type].exists(), json_type


def test_existing_contract_formal_output_has_no_raw_dir(tmp_path: Path):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    persist_precision_result(source, result, tmp_path / "out", keep_raw_tree=True)

    assert (tmp_path / "out" / "report.raw").exists() is False
    raw_dirs = [
        p.name
        for p in (tmp_path / "out").iterdir()
        if p.is_dir() and p.name.endswith(".raw")
    ]
    assert raw_dirs == []


def test_existing_contract_excludes_origin_pdf_from_json_dir(tmp_path: Path):
    source = tmp_path / "report.pdf"
    result = FakeResult()

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=True
    )
    assert targets.json_dir is not None
    json_dir = targets.json_dir

    assert (json_dir / "report_origin.pdf").exists() is False
    non_json = [p.name for p in json_dir.iterdir() if p.suffix != ".json"]
    assert non_json == []


def test_persist_precision_result_clears_stale_json_dir(tmp_path: Path):
    source = tmp_path / "report.pdf"
    result = FakeResult()
    stale_dir = tmp_path / "out" / "report.json"
    stale_dir.mkdir(parents=True)
    (stale_dir / "report.legacy.json").write_text('{"stale": true}', encoding="utf-8")
    (stale_dir / "report.content_list_v2.json").write_text(
        '{"stale": true}', encoding="utf-8"
    )

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=False
    )

    assert (stale_dir / "report.legacy.json").exists() is False
    assert (stale_dir / "report.content_list_v2.json").read_text(
        encoding="utf-8"
    ) == '{\n  "version": 2\n}'
    assert targets.json_files["content_list"].exists()


def test_persist_precision_result_retries_transient_rmtree_permission_error(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_precision as precision

    source = tmp_path / "report.pdf"
    result = FakeResult()
    stale_dir = tmp_path / "out" / "report.json"
    stale_dir.mkdir(parents=True)
    (stale_dir / "report.legacy.json").write_text('{"stale": true}', encoding="utf-8")

    calls = {"count": 0}
    real_rmtree = precision.shutil.rmtree

    def flaky_rmtree(path, *args, **kwargs):
        calls["count"] += 1
        if calls["count"] == 1:
            raise PermissionError("transient lock")
        return real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(precision.shutil, "rmtree", flaky_rmtree)
    monkeypatch.setattr(precision.time, "sleep", lambda _: None)

    targets = persist_precision_result(
        source, result, tmp_path / "out", keep_raw_tree=False
    )

    assert calls["count"] >= 2
    assert (stale_dir / "report.legacy.json").exists() is False
    assert targets.json_files["content_list"].exists()


def test_persist_precision_result_falls_back_to_powershell_remove_on_windows(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_precision as precision

    stale_dir = tmp_path / "out" / "report.json"
    stale_dir.mkdir(parents=True)
    (stale_dir / "report.legacy.json").write_text('{"stale": true}', encoding="utf-8")

    real_rmtree = precision.shutil.rmtree
    calls = {"shell": 0}

    def locked_rmtree(path, *args, **kwargs):
        raise PermissionError("persistent lock")

    def fake_run(command, check):
        calls["shell"] += 1
        real_rmtree(stale_dir)
        return None

    monkeypatch.setattr(precision.shutil, "rmtree", locked_rmtree)
    monkeypatch.setattr(precision.time, "sleep", lambda _: None)
    monkeypatch.setattr(precision.os, "name", "nt", raising=False)
    monkeypatch.setattr(precision.subprocess, "run", fake_run)

    precision._reset_json_dir(stale_dir, retries=2, delay_seconds=0)

    assert calls["shell"] == 1
    assert (stale_dir / "report.legacy.json").exists() is False


class FakeMinerU:
    def __init__(self, token: str):
        self.token = token

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def extract(self, source: str, *, model: str | None = None):
        name = Path(source).stem
        result = FakeResult()
        result.markdown = f"# {name}\n\n![](images/img1.png)\n"
        result.content_list = [{"name": name}]
        return result

    def extract_batch(self, sources):
        raise AssertionError("batch API should not be used for source-name mapping")


def test_convert_files_uses_stable_source_mapping_for_multiple_inputs(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_precision as precision

    monkeypatch.setattr(precision, "MinerUClient", FakeMinerU)

    first = tmp_path / "alpha.pdf"
    second = tmp_path / "beta.pdf"
    first.write_bytes(b"a")
    second.write_bytes(b"b")

    rendered = convert_files([first, second], tmp_path / "out", token="token")

    assert [item.markdown.name for item in rendered] == ["alpha.md", "beta.md"]
    assert (
        rendered[0].markdown.read_text(encoding="utf-8")
        == "# alpha\n\n![](alpha.images/img1.png)\n"
    )
    assert (
        rendered[1].markdown.read_text(encoding="utf-8")
        == "# beta\n\n![](beta.images/img1.png)\n"
    )
    assert rendered[0].json_files["content_list"].name == "alpha.content_list.json"
    assert rendered[1].json_files["content_list"].name == "beta.content_list.json"


def test_convert_files_passes_keep_raw_tree_setting_to_persist(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_precision as precision

    calls: list[bool] = []

    class FakeClient:
        def __init__(self, token: str):
            self.token = token

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract(self, source: str, *, model: str | None = None):
            return FakeResult()

    def fake_persist(
        source,
        result,
        output_root,
        keep_raw_tree=False,
        used_stems=None,
        relative_root=None,
        audit_dir=None,
        batch_id=None,
        route="mineru",
        model="default",
        allocated_stem=None,
    ):
        calls.append(keep_raw_tree)
        return persist_precision_result(
            source,
            result,
            output_root,
            keep_raw_tree=keep_raw_tree,
            used_stems=used_stems,
            relative_root=relative_root,
            audit_dir=audit_dir,
            batch_id=batch_id,
            route=route,
            model=model,
            allocated_stem=allocated_stem,
        )

    monkeypatch.setattr(precision, "MinerUClient", FakeClient)
    monkeypatch.setattr(precision, "persist_precision_result", fake_persist)

    source = tmp_path / "report.pdf"
    source.write_bytes(b"pdf")

    convert_files([source], tmp_path / "out", token="token", keep_raw_tree=True)

    assert calls == [True]


class RecordingMinerU:
    def __init__(self, token: str):
        self.token = token
        self.calls: list[dict] = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def extract(self, source: str, *, model: str | None = None, **kwargs):
        if "model_version" in kwargs:
            raise AssertionError("model_version must not be passed to SDK extract")
        call = {"source": source}
        if model is not None:
            call["model"] = model
        self.calls.append(call)
        name = Path(source).stem
        result = FakeResult()
        result.markdown = f"# {name}\n\n![](images/img1.png)\n"
        result.content_list = [{"name": name}]
        return result


def test_convert_files_html_receives_html_model(monkeypatch, tmp_path: Path):
    import scripts.mineru_precision as precision

    client = RecordingMinerU("token")
    monkeypatch.setattr(precision, "MinerUClient", lambda t: client)

    html = tmp_path / "page.html"
    html.write_text("<html><body>hello</body></html>", encoding="utf-8")

    convert_files([html], tmp_path / "out", token="token")

    assert len(client.calls) == 1
    assert client.calls[0]["model"] == "html"
    assert "model_version" not in client.calls[0]


def test_convert_files_pdf_no_model_version(monkeypatch, tmp_path: Path):
    import scripts.mineru_precision as precision

    client = RecordingMinerU("token")
    monkeypatch.setattr(precision, "MinerUClient", lambda t: client)

    pdf = tmp_path / "doc.pdf"
    pdf.write_bytes(b"%PDF")

    convert_files([pdf], tmp_path / "out", token="token")

    assert len(client.calls) == 1
    assert "model_version" not in client.calls[0]
    assert "model" not in client.calls[0]


def test_convert_files_mixed_html_and_pdf(monkeypatch, tmp_path: Path):
    import scripts.mineru_precision as precision

    client = RecordingMinerU("token")
    monkeypatch.setattr(precision, "MinerUClient", lambda t: client)

    html = tmp_path / "page.html"
    html.write_text("<html><body>hello</body></html>", encoding="utf-8")
    pdf = tmp_path / "doc.pdf"
    pdf.write_bytes(b"%PDF")

    convert_files([html, pdf], tmp_path / "out", token="token")

    assert len(client.calls) == 2
    html_call = next(c for c in client.calls if c["source"].endswith("page.html"))
    pdf_call = next(c for c in client.calls if c["source"].endswith("doc.pdf"))
    assert html_call["model"] == "html"
    assert "model_version" not in html_call
    assert "model_version" not in pdf_call
    assert "model" not in pdf_call


class ExtractWithModelOnly:
    def __init__(self, token: str):
        self.token = token

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def extract(self, source: str, *, model: str | None = None, timeout: int = 300):
        assert model == "html"
        name = Path(source).stem
        result = FakeResult()
        result.markdown = f"# {name}\n\n"
        result.content_list = [{"name": name}]
        return result


def test_convert_files_html_uses_sdk_model_keyword_when_model_version_is_absent(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_precision as precision

    monkeypatch.setattr(precision, "MinerUClient", ExtractWithModelOnly)

    html = tmp_path / "page.html"
    html.write_text("<html><body>hello</body></html>", encoding="utf-8")

    rendered = convert_files([html], tmp_path / "out", token="token")

    assert rendered[0].markdown.read_text(encoding="utf-8") == "# page\n\n"


def test_convert_files_forwards_audit_kwargs_to_persist(monkeypatch, tmp_path: Path):
    import scripts.mineru_precision as precision

    captured = []

    class FakeClient:
        def __init__(self, token: str):
            self.token = token

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract(self, source: str, *, model: str | None = None):
            return FakeResult()

    def fake_persist(source, result, output_root, **kwargs):
        captured.append(kwargs)
        return persist_precision_result(source, result, output_root, **kwargs)

    monkeypatch.setattr(precision, "MinerUClient", FakeClient)
    monkeypatch.setattr(precision, "persist_precision_result", fake_persist)

    source = tmp_path / "report.pdf"
    source.write_bytes(b"pdf")
    audit_dir = tmp_path / "audit"

    convert_files(
        [source],
        tmp_path / "out",
        token="token",
        audit_dir=audit_dir,
        batch_id="fixed",
        route="mineru_html",
        model="MinerU-HTML",
    )

    assert captured[0]["audit_dir"] == audit_dir
    assert captured[0]["batch_id"] == "fixed"
    assert captured[0]["route"] == "mineru_html"
    assert captured[0]["model"] == "MinerU-HTML"


def test_convert_files_failure_collector_catches_per_file_exception(monkeypatch, tmp_path: Path):
    import scripts.mineru_precision as precision

    class FailingThenPassingClient:
        def __init__(self, token: str):
            self.token = token

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract(self, source: str, *, model: str | None = None):
            if Path(source).name == "bad.pdf":
                raise RuntimeError("boom")
            return FakeResult()

    monkeypatch.setattr(precision, "MinerUClient", FailingThenPassingClient)
    bad = tmp_path / "bad.pdf"
    good = tmp_path / "good.pdf"
    bad.write_bytes(b"bad")
    good.write_bytes(b"good")
    failures = []

    rendered = convert_files([bad, good], tmp_path / "out", token="token", route="mineru", failure_collector=failures)

    assert [target.stem for target in rendered] == ["good"]
    assert failures == [{"source_path": bad, "error": "boom", "route": "mineru"}]


def test_convert_files_same_stem_batch_allocates_distinct_manifests_and_batch_keys(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_convert as convert
    import scripts.mineru_precision as precision

    monkeypatch.setattr(precision, "MinerUClient", FakeMinerU)

    dir_a = tmp_path / "dir_a"
    dir_b = tmp_path / "dir_b"
    first = dir_a / "report.pdf"
    second = dir_b / "report.pdf"
    dir_a.mkdir()
    dir_b.mkdir()
    first.write_bytes(b"a")
    second.write_bytes(b"b")
    audit_dir = tmp_path / "audit"

    rendered = convert_files(
        [first, second],
        tmp_path / "out",
        token="token",
        keep_raw_tree=True,
        relative_root=tmp_path,
        audit_dir=audit_dir,
        batch_id="fixed",
    )
    quality_gate = {"status": "passed", "passed": True, "failed_gates": []}
    for target in rendered:
        convert._upsert_rendered_manifest(audit_dir, target, quality_gate)

    assert [target.manifest.name for target in rendered] == [
        "report.manifest.json",
        "report__2.manifest.json",
    ]
    batch = json.loads((audit_dir / "mineru_manifest.json").read_text(encoding="utf-8"))
    assert set(batch) == {"dir_a/report.pdf", "dir_b/report.pdf"}
    assert batch["dir_a/report.pdf"]["allocated_stem"] == "report"
    assert batch["dir_b/report.pdf"]["allocated_stem"] == "report__2"


def test_convert_files_rerun_reuses_allocated_stem_and_upserts_batch_manifest(
    monkeypatch, tmp_path: Path
):
    import scripts.mineru_convert as convert
    import scripts.mineru_precision as precision

    monkeypatch.setattr(precision, "MinerUClient", FakeMinerU)
    source = tmp_path / "report.pdf"
    source.write_bytes(b"pdf")
    output_root = tmp_path / "out"
    audit_dir = tmp_path / "audit"
    quality_gate = {"status": "passed", "passed": True, "failed_gates": []}

    first = convert_files(
        [source], output_root, token="token", audit_dir=audit_dir, batch_id="first"
    )[0]
    convert._upsert_rendered_manifest(audit_dir, first, quality_gate)
    first_manifest_text = first.manifest.read_text(encoding="utf-8")

    second = convert_files(
        [source], output_root, token="token", audit_dir=audit_dir, batch_id="second"
    )[0]
    convert._upsert_rendered_manifest(audit_dir, second, quality_gate)

    batch = json.loads((audit_dir / "mineru_manifest.json").read_text(encoding="utf-8"))
    assert first.manifest == second.manifest
    assert second.stem == "report"
    assert set(batch) == {"report.pdf"}
    assert batch["report.pdf"]["allocated_stem"] == "report"
    assert batch["report.pdf"]["batch_id"] == "second"
    assert first.manifest.read_text(encoding="utf-8") != first_manifest_text
    assert not (output_root / "report__2.manifest.json").exists()
    assert not (output_root / "report__2.md").exists()


def test_convert_files_without_failure_collector_propagates_exception(monkeypatch, tmp_path: Path):
    import scripts.mineru_precision as precision

    class FailingClient:
        def __init__(self, token: str):
            self.token = token

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract(self, source: str, *, model: str | None = None):
            raise RuntimeError("boom")

    monkeypatch.setattr(precision, "MinerUClient", FailingClient)
    source = tmp_path / "bad.pdf"
    source.write_bytes(b"bad")

    with pytest.raises(RuntimeError, match="boom"):
        convert_files([source], tmp_path / "out", token="token")
