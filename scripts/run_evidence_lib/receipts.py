"""Bounded completion receipts for request-safe terminal retries."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Any

from .bounded_io import _decode_json_bytes, _read_bounded_bytes
from .contracts import _safe_run_segment
from .safe_io import _json_bytes


MAX_FINALIZE_RECEIPT_BYTES = 1024
_FINALIZE_RECEIPT_NAME = "finalize-receipt.json"
_FINALIZE_RECEIPT_KEYS = {
    "schemaVersion",
    "operation",
    "attemptRoot",
    "requestFingerprint",
    "resultPath",
    "resultSha256",
}
_SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
_LEGACY_FINALIZE_REQUEST_DOMAIN = (
    b"zeno-mobile-runner:legacy-finalize-receipt-request:v1\x00"
)


def _valid_sha256(value: Any) -> bool:
    return isinstance(value, str) and _SHA256_RE.fullmatch(value) is not None


def _legacy_finalize_receipt_request_fingerprint(
    request_fingerprint: str,
) -> str:
    """Bind an upgraded receipt to a legacy WAL without impersonating v1 writes."""

    if not _valid_sha256(request_fingerprint):
        raise ValueError("legacy finalize request fingerprint is invalid")
    digest = hashlib.sha256(
        _LEGACY_FINALIZE_REQUEST_DOMAIN + request_fingerprint.encode("ascii")
    ).hexdigest()
    return "sha256:" + digest


def _finalize_receipt_relative(attempt_relative: str) -> str:
    parts = (
        attempt_relative.split("/")
        if isinstance(attempt_relative, str)
        else []
    )
    if (
        len(parts) != 2
        or parts[0] != "attempts"
        or not _safe_run_segment(parts[1])
    ):
        raise ValueError("finalize receipt attemptRoot must be attempts/<runId>")
    return attempt_relative + "/" + _FINALIZE_RECEIPT_NAME


def _attempt_relative_for_receipt(receipt_relative: str) -> str:
    suffix = "/" + _FINALIZE_RECEIPT_NAME
    if not isinstance(receipt_relative, str) or not receipt_relative.endswith(
        suffix
    ):
        raise ValueError("finalize receipt path is invalid")
    attempt_relative = receipt_relative[: -len(suffix)]
    if _finalize_receipt_relative(attempt_relative) != receipt_relative:
        raise ValueError("finalize receipt path is invalid")
    return attempt_relative


def _validate_finalize_receipt_value(
    receipt: Any, attempt_relative: str
) -> dict:
    if not isinstance(receipt, dict) or set(receipt) != _FINALIZE_RECEIPT_KEYS:
        raise ValueError("finalize receipt has an invalid object shape")
    if (
        type(receipt.get("schemaVersion")) is not int
        or receipt["schemaVersion"] != 1
    ):
        raise ValueError("finalize receipt schemaVersion must equal 1")
    if receipt.get("operation") != "finalize":
        raise ValueError("finalize receipt operation is invalid")
    if receipt.get("attemptRoot") != attempt_relative:
        raise ValueError("finalize receipt attemptRoot is invalid")
    if not _valid_sha256(receipt.get("requestFingerprint")):
        raise ValueError("finalize receipt requestFingerprint is invalid")
    if receipt.get("resultPath") != attempt_relative + "/run-summary.json":
        raise ValueError("finalize receipt resultPath is invalid")
    if not _valid_sha256(receipt.get("resultSha256")):
        raise ValueError("finalize receipt resultSha256 is invalid")
    return receipt


def _validate_finalize_receipt_content(
    receipt_relative: str, content: bytes
) -> dict:
    if not isinstance(content, bytes):
        raise ValueError("finalize receipt content must be bytes")
    if len(content) > MAX_FINALIZE_RECEIPT_BYTES:
        raise ValueError(
            f"finalize receipt exceeds {MAX_FINALIZE_RECEIPT_BYTES} bytes"
        )
    attempt_relative = _attempt_relative_for_receipt(receipt_relative)
    try:
        value = _decode_json_bytes(content)
    except ValueError as exc:
        raise ValueError(f"finalize receipt is invalid JSON: {exc}") from exc
    return _validate_finalize_receipt_value(value, attempt_relative)


def _make_finalize_receipt(
    attempt_relative: str,
    request_fingerprint: str,
    result_content: bytes,
) -> bytes:
    receipt_relative = _finalize_receipt_relative(attempt_relative)
    value = {
        "schemaVersion": 1,
        "operation": "finalize",
        "attemptRoot": attempt_relative,
        "requestFingerprint": request_fingerprint,
        "resultPath": attempt_relative + "/run-summary.json",
        "resultSha256": "sha256:" + hashlib.sha256(result_content).hexdigest(),
    }
    content = _json_bytes(value)
    _validate_finalize_receipt_content(receipt_relative, content)
    return content


def _read_finalize_receipt(path: Path, receipt_relative: str) -> dict:
    try:
        content = _read_bounded_bytes(Path(path), MAX_FINALIZE_RECEIPT_BYTES)
    except ValueError as exc:
        if str(exc).startswith("structured JSON exceeds"):
            raise ValueError(
                f"finalize receipt exceeds {MAX_FINALIZE_RECEIPT_BYTES} bytes"
            ) from exc
        raise
    return _validate_finalize_receipt_content(receipt_relative, content)


def _validate_finalize_receipt_binding(
    receipt: dict,
    *,
    request_fingerprint: str,
    result_sha256: str,
) -> None:
    if receipt["requestFingerprint"] != request_fingerprint:
        raise ValueError(
            "finalize receipt request fingerprint disagrees with transaction"
        )
    if receipt["resultSha256"] != result_sha256:
        raise ValueError("finalize receipt result hash disagrees with summary")


__all__ = (
    "MAX_FINALIZE_RECEIPT_BYTES",
    "_FINALIZE_RECEIPT_NAME",
    "_FINALIZE_RECEIPT_KEYS",
    "_legacy_finalize_receipt_request_fingerprint",
    "_finalize_receipt_relative",
    "_attempt_relative_for_receipt",
    "_validate_finalize_receipt_value",
    "_validate_finalize_receipt_content",
    "_make_finalize_receipt",
    "_read_finalize_receipt",
    "_validate_finalize_receipt_binding",
)
