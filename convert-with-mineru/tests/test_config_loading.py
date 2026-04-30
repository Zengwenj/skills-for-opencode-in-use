from pathlib import Path

from scripts.mineru_config import load_settings


def test_load_settings_prefers_environment(monkeypatch, tmp_path: Path):
    config_path = tmp_path / "mineru.env"
    config_path.write_text("MINERU_TOKEN=from-config\n", encoding="utf-8")
    monkeypatch.setenv("MINERU_TOKEN", "from-env")

    settings = load_settings(config_path)
    assert settings.token == "from-env"


def test_load_settings_reads_env_file(tmp_path: Path):
    config_path = tmp_path / "mineru.env"
    config_path.write_text(
        "# comment\nMINERU_TOKEN=from-config\nKEEP_RAW_TREE=false\n",
        encoding="utf-8",
    )

    settings = load_settings(config_path)
    assert settings.token == "from-config"
    assert settings.keep_raw_tree is False


def test_load_settings_reads_json_file(tmp_path: Path):
    config_path = tmp_path / "mineru.json"
    config_path.write_text(
        '{"MINERU_TOKEN":"from-json","KEEP_RAW_TREE":true}',
        encoding="utf-8",
    )

    settings = load_settings(config_path)
    assert settings.token == "from-json"
    assert settings.keep_raw_tree is True


def test_load_settings_reads_default_values_from_environment(monkeypatch):
    monkeypatch.setenv("DEFAULT_OUTPUT_ROOT", "C:/tmp/out")
    monkeypatch.setenv("KEEP_RAW_TREE", "true")

    settings = load_settings()

    assert settings.default_output_root == "C:/tmp/out"
    assert settings.keep_raw_tree is True
