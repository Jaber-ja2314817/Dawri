"""Serves the built frontend for paths no API route claimed."""

from __future__ import annotations

from pathlib import Path

from fastapi.responses import FileResponse, JSONResponse, Response

from backend import config


def _asset(root: Path, url_path: str) -> Path | None:
    """The real file under root for this path, or None. Nothing outside root."""
    try:
        target = (root / url_path.lstrip("/")).resolve()
        return target if target.is_file() and target.is_relative_to(root) else None
    except (OSError, ValueError):  # Too long a name, or a NUL byte from %00.
        return None


def serve(url_path: str) -> Response:
    root = config.static_dir().resolve()
    index = root / "index.html"
    if not index.is_file():
        return JSONResponse(
            status_code=404,
            content={"error": "frontend_not_built", "message": "The frontend is not built."},
        )
    asset = _asset(root, url_path)
    if asset is None or asset == index:
        return FileResponse(index, headers={"Cache-Control": "no-cache"})
    return FileResponse(asset)
