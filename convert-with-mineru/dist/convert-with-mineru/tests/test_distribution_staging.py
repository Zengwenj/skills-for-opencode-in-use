from pathlib import Path

from scripts.stage_distribution import build_distribution_tree


def _assert_value_error_with_message(callable_obj, message: str) -> None:
    try:
        callable_obj()
    except ValueError as exc:
        assert message in str(exc)
        return
    raise AssertionError("expected ValueError")


def test_build_distribution_tree_filters_isolated_entries(tmp_path: Path):
    source = tmp_path / "skill"
    source.mkdir()

    (source / "SKILL.md").write_text("# skill\n", encoding="utf-8")
    (source / ".venv").mkdir()
    (source / ".venv" / "pyvenv.cfg").write_text("x", encoding="utf-8")
    (source / ".pytest_cache").mkdir()
    (source / ".pytest_cache" / "state").write_text("x", encoding="utf-8")
    (source / "mineru..env").write_text("MINERU_TOKEN=secret\n", encoding="utf-8")
    (source / "HANDOFF-2026-04-01.md").write_text("handoff\n", encoding="utf-8")
    (source / "live-repeat-output").mkdir()
    (source / "live-repeat-output" / "sample.md").write_text("x", encoding="utf-8")
    (source / "scripts").mkdir()
    (source / "scripts" / "tool.py").write_text("print('ok')\n", encoding="utf-8")
    (source / "scripts" / "__pycache__").mkdir()
    (source / "scripts" / "__pycache__" / "tool.pyc").write_bytes(b"x")

    staged = build_distribution_tree(source, tmp_path / "dist" / "stage")

    assert (staged / "SKILL.md").exists()
    assert (staged / "scripts" / "tool.py").exists()
    assert (staged / ".venv").exists() is False
    assert (staged / ".pytest_cache").exists() is False
    assert (staged / "mineru..env").exists() is False
    assert (staged / "HANDOFF-2026-04-01.md").exists() is False
    assert (staged / "live-repeat-output").exists() is False
    assert (staged / "scripts" / "__pycache__").exists() is False


def test_build_distribution_tree_replaces_existing_destination(tmp_path: Path):
    source = tmp_path / "skill"
    source.mkdir()
    (source / "SKILL.md").write_text("# next\n", encoding="utf-8")

    destination = tmp_path / "stage"
    destination.mkdir()
    (destination / "stale.txt").write_text("old\n", encoding="utf-8")

    build_distribution_tree(source, destination)

    assert (destination / "SKILL.md").read_text(encoding="utf-8") == "# next\n"
    assert (destination / "stale.txt").exists() is False


def test_build_distribution_tree_rejects_source_root_as_destination(tmp_path: Path):
    source = tmp_path / "skill"
    source.mkdir()
    (source / "SKILL.md").write_text("# skill\n", encoding="utf-8")

    _assert_value_error_with_message(
        lambda: build_distribution_tree(source, source), "source root"
    )


def test_build_distribution_tree_rejects_unsafe_in_tree_destination(tmp_path: Path):
    source = tmp_path / "skill"
    source.mkdir()
    (source / "SKILL.md").write_text("# skill\n", encoding="utf-8")

    _assert_value_error_with_message(
        lambda: build_distribution_tree(source, source / "stage"),
        "safe staging directories",
    )
