"""Fixed static resources and HTTP composition for the management interface."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import stat

from router.management.api import ManagementAPI


MAX_STATIC_BYTES = 1_048_576
STATIC_RESOURCES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/static/styles.css": ("static/styles.css", "text/css; charset=utf-8"),
    "/static/app.js": ("static/app.js", "text/javascript; charset=utf-8"),
}


@dataclass(frozen=True, slots=True)
class Response:
    status: int
    content_type: str
    body: bytes


class StaticResources:
    """Read only explicitly mapped files below the trusted installed web tree."""

    def __init__(self, root: Path) -> None:
        self.root = root

    def get(self, path: str) -> Response | None:
        resource = STATIC_RESOURCES.get(path)
        if resource is None:
            return None
        relative, content_type = resource
        target = self.root / relative
        try:
            metadata = target.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                return None
            if metadata.st_size > MAX_STATIC_BYTES:
                return None
            body = target.read_bytes()
        except OSError:
            return None
        return Response(200, content_type, body)


class ManagementApplication:
    def __init__(self, api: ManagementAPI, static: StaticResources) -> None:
        self.api = api
        self.static = static

    @staticmethod
    def json_response(status: int, payload: dict[str, object]) -> Response:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return Response(status, "application/json", body)

    def dispatch(self, method: str, target: str) -> Response:
        path = target.partition("?")[0].partition("#")[0]
        if path.startswith("/api/"):
            status, payload = self.api.dispatch(method, path)
            return self.json_response(status, payload)
        if method != "GET":
            return self.json_response(405, {"detail": "method not allowed"})
        resource = self.static.get(path)
        if resource is not None:
            return resource
        return self.json_response(404, {"detail": "not found"})
