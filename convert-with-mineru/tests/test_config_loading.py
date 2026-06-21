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


def test_load_settings_reads_audit_dir_from_environment(monkeypatch, tmp_path: Path):
    monkeypatch.setattr(Path, "home", lambda: tmp_path / "fake_home")
    monkeypatch.setattr(Path, "cwd", lambda: tmp_path / "fake_cwd")
    monkeypatch.delenv("MINERU_CONFIG_PATH", raising=False)
    monkeypatch.setenv("MINERU_AUDIT_DIR", "C:/audit/env")

    settings = load_settings()

    assert settings.audit_dir == "C:/audit/env"


def test_load_settings_reads_audit_dir_from_config_file(tmp_path: Path):
    config_path = tmp_path / "mineru.env"
    config_path.write_text("AUDIT_DIR=C:/audit/config\n", encoding="utf-8")

    settings = load_settings(config_path)

    assert settings.audit_dir == "C:/audit/config"


def test_load_settings_reads_default_values_from_environment(monkeypatch, tmp_path: Path):
    # 隔离：mock home/cwd 避免读到真实 mineru.env 污染断言
    monkeypatch.setattr(Path, "home", lambda: tmp_path / "fake_home")
    monkeypatch.setattr(Path, "cwd", lambda: tmp_path / "fake_cwd")
    monkeypatch.delenv("MINERU_TOKEN", raising=False)
    monkeypatch.delenv("MINERU_CONFIG_PATH", raising=False)
    monkeypatch.setenv("DEFAULT_OUTPUT_ROOT", "C:/tmp/out")
    monkeypatch.setenv("KEEP_RAW_TREE", "true")

    settings = load_settings()

    assert settings.token is None
    assert settings.default_output_root == "C:/tmp/out"
    assert settings.keep_raw_tree is True


def test_load_settings_auto_discovers_home_mineru_env(monkeypatch, tmp_path: Path):
    fake_home = tmp_path / "fake_home"
    local_dir = fake_home / ".config" / "opencode" / "local"
    local_dir.mkdir(parents=True)
    (local_dir / "mineru.env").write_text(
        "MINERU_TOKEN=auto-discovered\nKEEP_RAW_TREE=true\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(Path, "home", lambda: fake_home)
    monkeypatch.setattr(Path, "cwd", lambda: tmp_path / "empty_cwd")
    monkeypatch.delenv("MINERU_TOKEN", raising=False)
    monkeypatch.delenv("MINERU_CONFIG_PATH", raising=False)

    settings = load_settings()

    assert settings.token == "auto-discovered"
    assert settings.keep_raw_tree is True


def test_load_settings_prefers_cwd_mineru_env_over_home(monkeypatch, tmp_path: Path):
    fake_home = tmp_path / "fake_home"
    local_dir = fake_home / ".config" / "opencode" / "local"
    local_dir.mkdir(parents=True)
    (local_dir / "mineru.env").write_text("MINERU_TOKEN=from-home\n", encoding="utf-8")

    fake_cwd = tmp_path / "fake_cwd"
    fake_cwd.mkdir()
    (fake_cwd / "mineru.env").write_text("MINERU_TOKEN=from-cwd\n", encoding="utf-8")

    monkeypatch.setattr(Path, "home", lambda: fake_home)
    monkeypatch.setattr(Path, "cwd", lambda: fake_cwd)
    monkeypatch.delenv("MINERU_TOKEN", raising=False)
    monkeypatch.delenv("MINERU_CONFIG_PATH", raising=False)

    settings = load_settings()

    assert settings.token == "from-cwd"


def test_load_settings_respects_mineru_config_path_env(monkeypatch, tmp_path: Path):
    custom = tmp_path / "custom.env"
    custom.write_text("MINERU_TOKEN=from-custom\n", encoding="utf-8")

    fake_cwd = tmp_path / "fake_cwd"
    fake_cwd.mkdir()
    (fake_cwd / "mineru.env").write_text("MINERU_TOKEN=from-cwd\n", encoding="utf-8")

    monkeypatch.setattr(Path, "cwd", lambda: fake_cwd)
    monkeypatch.setenv("MINERU_CONFIG_PATH", str(custom))
    monkeypatch.delenv("MINERU_TOKEN", raising=False)

    settings = load_settings()

    assert settings.token == "from-custom"


def test_load_settings_no_config_when_no_default_exists(monkeypatch, tmp_path: Path):
    monkeypatch.setattr(Path, "home", lambda: tmp_path / "fake_home")
    monkeypatch.setattr(Path, "cwd", lambda: tmp_path / "fake_cwd")
    monkeypatch.delenv("MINERU_TOKEN", raising=False)
    monkeypatch.delenv("MINERU_CONFIG_PATH", raising=False)

    settings = load_settings()

    assert settings.token is None
    assert settings.default_output_root == ""
    assert settings.keep_raw_tree is False
