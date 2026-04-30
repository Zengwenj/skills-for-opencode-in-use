from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Settings:
    token: str | None = None
    default_output_root: str = ""
    keep_raw_tree: bool = False


def _parse_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _load_env_file(path: Path) -> dict[str, object]:
    data: dict[str, object] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data


def _load_json_file(path: Path) -> dict[str, object]:
    loaded = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise ValueError("configuration json must contain an object")
    return loaded


def load_settings(config_path: str | Path | None = None) -> Settings:
    payload: dict[str, object] = {}
    if config_path:
        path = Path(config_path)
        if path.suffix.lower() == ".env":
            payload = _load_env_file(path)
        elif path.suffix.lower() == ".json":
            payload = _load_json_file(path)
        else:
            raise ValueError(f"unsupported config file: {path}")

    token = os.environ.get("MINERU_TOKEN") or payload.get("MINERU_TOKEN")
    default_output_root = str(
        os.environ.get("DEFAULT_OUTPUT_ROOT")
        or payload.get("DEFAULT_OUTPUT_ROOT")
        or ""
    )
    keep_raw_tree = _parse_bool(
        os.environ.get("KEEP_RAW_TREE")
        if "KEEP_RAW_TREE" in os.environ
        else payload.get("KEEP_RAW_TREE", False)
    )

    return Settings(
        token=str(token) if token else None,
        default_output_root=default_output_root,
        keep_raw_tree=keep_raw_tree,
    )
