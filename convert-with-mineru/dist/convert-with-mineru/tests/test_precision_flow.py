import io
import zipfile
from pathlib import Path

from scripts.mineru_precision import convert_files, persist_precision_result


class FakeResult:
    def __init__(self):
        self.markdown = "# ok\n\n![](images/img1.png)\n"
        self.content_list = [{"type": "text", "text": "hello"}]
        self._zip_bytes = self._make_zip_bytes()

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
            zf.writestr("report_model.json", '{"pages": 1}')
            zf.writestr("layout.json", '{"blocks": []}')
            zf.writestr("report_origin.pdf", b"pdf")
            zf.writestr("images/img1.png", b"png")
        return buffer.getvalue()


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

    def extract(self, source: str):
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

        def extract(self, source: str):
            return FakeResult()

    def fake_persist(source, result, output_root, keep_raw_tree=False, used_stems=None):
        calls.append(keep_raw_tree)
        return persist_precision_result(
            source,
            result,
            output_root,
            keep_raw_tree=keep_raw_tree,
            used_stems=used_stems,
        )

    monkeypatch.setattr(precision, "MinerUClient", FakeClient)
    monkeypatch.setattr(precision, "persist_precision_result", fake_persist)

    source = tmp_path / "report.pdf"
    source.write_bytes(b"pdf")

    convert_files([source], tmp_path / "out", token="token", keep_raw_tree=True)

    assert calls == [True]
