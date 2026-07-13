"""Resource-bounded semantic scanning for publishable evidence bundles."""

from __future__ import annotations

import re
import stat
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from . import bounded_io
from . import constants as _limits
from .journal import _ATOMIC_WRITE_TEMP_RE
from .sanitization import _sanitization_roots, _utf8_byte_length


_PUBLIC_DENY_SUBSTRINGS = (
    "bri" + "ck",
    "uk.co." + "ren" + "tly",
    "ren" + "tly" + "test",
    "zig" + "-mobile-runner",
    "zig" + " mobile runner",
    "zig" + "_mobile_runner",
    "cod" + "ex",
    "clau" + "de fable",
    "noreply@" + "anthropic.com",
    "co-authored-by:" + " claude",
    "clau" + "de code",
    "clau" + "de mcp add",
    "app" + "ium",
    "mae" + "stro",
    "det" + "ox",
    "browser" + "stack",
    "sauce" + "labs",
    "sauce" + " labs",
    "firebase" + " test " + "lab",
    "kobi" + "ton",
    "perfect" + "o",
    "testri" + "gor",
    "kata" + "lon",
    "lambda" + "test",
)
_PUBLIC_BOUNDARY_DENY_RE = re.compile(
    r"(?:^|[^a-z])" + "ren" + r"tly(?:[^a-z]|$)", re.IGNORECASE
)

_FILE_URL_BYTES_RE = re.compile(
    rb"file:(?://[^/\s\x00\"'<>|,;]*/|/)"
    rb"(?:[^\s\x00\"'<>|,;]+)",
    re.IGNORECASE,
)
_WINDOWS_ABSOLUTE_BYTES_RE = re.compile(
    rb"(?<![A-Za-z0-9_])(?:[A-Za-z]:[\\/]|\\\\)[^\s\x00\"'<>|,;]+"
)
_POSIX_ABSOLUTE_BYTES_RE = re.compile(
    rb"(?<![A-Za-z0-9_}$/<])/(?!/)(?:[^\s\x00\"'<>|,;]+)"
)
_POSIX_NETWORK_ABSOLUTE_BYTES_RE = re.compile(
    rb"(?<![A-Za-z0-9_}$/:<])//(?:[^\s\x00\"'<>|,;]+)"
)
_WINDOWS_START_BYTES_RE = re.compile(
    rb"(?<![A-Za-z0-9_])(?:[A-Za-z]:[\\/]|\\\\)"
)
_POSIX_START_BYTES_RE = re.compile(
    rb"(?<![A-Za-z0-9_}$/<])/(?!/)[^\s\x00\"'<>|,;]"
)
_POSIX_NETWORK_START_BYTES_RE = re.compile(
    rb"(?<![A-Za-z0-9_}$/:<])//[^\s\x00\"'<>|,;]"
)
_TOKEN_FRAGMENT_RE = re.compile(rb"[^\s\x00\"<>|]+")
_TOKEN_DELIMITER_BYTES = frozenset(b" \t\r\n\v\f\x00\"<>|")
_TOKEN_STATE_MARKERS = (b":", b"/", b"\\", b"@", b"?", b"#")
_ASCII_LETTERS = frozenset(range(ord("a"), ord("z") + 1))
_POSIX_DISALLOWED_PREDECESSORS = frozenset(
    (
        *range(ord("a"), ord("z") + 1),
        *range(ord("A"), ord("Z") + 1),
        *range(ord("0"), ord("9") + 1),
        ord("_"),
        ord("$"),
        ord("}"),
        ord("/"),
        ord("<"),
    )
)


def _contains_public_deny_pattern(text: str) -> bool:
    lowered = text.lower()
    return _PUBLIC_BOUNDARY_DENY_RE.search(text) is not None or any(
        term in lowered for term in _PUBLIC_DENY_SUBSTRINGS
    )


def _iter_json_strings(value: Any) -> Iterator[str]:
    """Yield decoded object keys and values without recursive Python frames."""

    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, str):
            yield item
        elif isinstance(item, list):
            pending.extend(reversed(item))
        elif isinstance(item, dict):
            yield from item.keys()
            pending.extend(item.values())


def _json_strings(value: Any) -> list[str]:
    """Compatibility collector for callers that require a concrete list."""

    return list(_iter_json_strings(value))


def _scan_semantic_text(
    relative: str, text: str, secrets: list[str], errors: list[str]
) -> None:
    if any(
        secret in text
        for secret in secrets
        if isinstance(secret, str) and secret
    ):
        errors.append(f"{relative}: contains a current known secret value")
    if _utf8_byte_length(text) is None:
        errors.append(f"{relative}: contains non-Unicode scalar text")
        return
    scanner = _RawSemanticScanner(roots={}, secrets=[])
    encoded = text.encode("utf-8")
    for offset in range(0, len(encoded), _limits._BUNDLE_SCAN_CHUNK_BYTES):
        scanner.feed(encoded[offset : offset + _limits._BUNDLE_SCAN_CHUNK_BYTES])
    flags = scanner.finish()
    if "credential_url" in flags:
        errors.append(f"{relative}: contains a credential URL")
    if "absolute_path" in flags:
        errors.append(f"{relative}: contains a raw absolute path")
    if "deny" in flags:
        errors.append(f"{relative}: contains a public safety deny pattern")
    if "semantic_limit" in flags:
        errors.append(f"{relative}: semantic token exceeds scan limit")


def _scan_publishable_entry_name(
    relative: str, secrets: list[str], errors: list[str]
) -> bool:
    """Reject unsafe relative entry names without reflecting their contents."""

    unsafe = any(
        secret in relative
        for secret in secrets
        if isinstance(secret, str) and secret
    ) or _contains_public_deny_pattern(relative)
    components = relative.split("/")
    for index, component in enumerate(components):
        if any(
            ord(character) < 0x20
            or ord(character) == 0x7F
            or 0xD800 <= ord(character) <= 0xDFFF
            for character in component
        ):
            unsafe = True
        if (
            len(component) >= 3
            and component[0].isascii()
            and component[0].isalpha()
            and component[1] == ":"
            and component[2] == "\\"
        ) or component.startswith("\\\\") or (
            len(component) == 2
            and component[0].isascii()
            and component[0].isalpha()
            and component[1] == ":"
            and index < len(components) - 1
        ):
            unsafe = True
    if unsafe:
        errors.append("$: unsafe publishable entry name detected")
    return unsafe


class _RawSemanticScanner:
    """Scan arbitrary bytes with bounded dynamic overlap and token state."""

    _TAIL_BYTES = 64

    def __init__(self, *, roots: dict[str, str], secrets: list[str]) -> None:
        self._secrets = sorted(
            {
                value.encode("utf-8")
                for value in secrets
                if isinstance(value, str)
                and value
                and _utf8_byte_length(value) is not None
            },
            key=lambda value: (-len(value), value),
        )
        carry_terms = [
            *self._secrets,
            *(
                value.encode("utf-8")
                for value in roots.values()
                if isinstance(value, str)
                and value
                and _utf8_byte_length(value) is not None
            ),
            *(term.encode("ascii") for term in _PUBLIC_DENY_SUBSTRINGS),
            b"ren" + b"tly",
            b"file:///",
            b"https://",
            b"C:\\",
        ]
        configured = max((len(value) for value in carry_terms), default=0)
        self.carry_bytes = max(
            _limits._BUNDLE_SCAN_OVERLAP_BYTES, configured + 4
        )
        self._overlap = b""
        self._total_bytes = 0
        self._flags: set[str] = set()
        self._token_length = 0
        self._token_sensitive = False
        self._token_tail = b""
        self._token_prefix = b""
        self._scheme_state = 0
        self._scheme_prefix = bytearray()
        self._authority_active = False
        self._authority_is_file = False
        self._authority_characters = 0
        self._posix_prefix_allowed = True

    @staticmethod
    def _is_new_match(
        match: re.Match[bytes], *, absolute_start: int, new_start: int
    ) -> bool:
        return absolute_start + match.end() > new_start

    def _mark_regex(
        self,
        name: str,
        pattern: re.Pattern[bytes],
        window: bytes,
        *,
        absolute_start: int,
        new_start: int,
        needs_predecessor: bool = False,
    ) -> None:
        if name in self._flags:
            return
        for match in pattern.finditer(window):
            if not self._is_new_match(
                match, absolute_start=absolute_start, new_start=new_start
            ):
                continue
            if needs_predecessor and match.start() == 0 and absolute_start > 0:
                continue
            self._flags.add(name)
            return

    def _mark_secrets(
        self, window: bytes, *, absolute_start: int, new_start: int
    ) -> None:
        if "secret" in self._flags:
            return
        for secret in self._secrets:
            position = window.find(secret)
            while position >= 0:
                if absolute_start + position + len(secret) > new_start:
                    self._flags.add("secret")
                    return
                position = window.find(secret, position + 1)

    def _mark_deny_terms(
        self,
        window: bytes,
        *,
        absolute_start: int,
        new_start: int,
        final: bool,
    ) -> None:
        if "deny" in self._flags:
            return
        lowered = window.lower()
        for term in _PUBLIC_DENY_SUBSTRINGS:
            encoded = term.encode("ascii")
            position = lowered.find(encoded)
            while position >= 0:
                if absolute_start + position + len(encoded) > new_start:
                    self._flags.add("deny")
                    return
                position = lowered.find(encoded, position + 1)

        boundary = b"ren" + b"tly"
        position = lowered.find(boundary)
        while position >= 0:
            before_known = position > 0 or absolute_start == 0
            before = lowered[position - 1] if position > 0 else None
            after_index = position + len(boundary)
            after_known = after_index < len(lowered) or (
                final and absolute_start + after_index == self._total_bytes
            )
            after = lowered[after_index] if after_index < len(lowered) else None
            if (
                before_known
                and after_known
                and (before is None or before not in _ASCII_LETTERS)
                and (after is None or after not in _ASCII_LETTERS)
            ):
                self._flags.add("deny")
                return
            position = lowered.find(boundary, position + 1)

    def _scan_window(
        self, window: bytes, *, absolute_start: int, new_start: int, final: bool
    ) -> None:
        self._mark_secrets(
            window, absolute_start=absolute_start, new_start=new_start
        )
        self._mark_regex(
            "absolute_path",
            _FILE_URL_BYTES_RE,
            window,
            absolute_start=absolute_start,
            new_start=new_start,
        )
        self._mark_regex(
            "absolute_path",
            _WINDOWS_ABSOLUTE_BYTES_RE,
            window,
            absolute_start=absolute_start,
            new_start=new_start,
            needs_predecessor=True,
        )
        self._mark_regex(
            "absolute_path",
            _POSIX_ABSOLUTE_BYTES_RE,
            window,
            absolute_start=absolute_start,
            new_start=new_start,
            needs_predecessor=True,
        )
        self._mark_regex(
            "absolute_path",
            _POSIX_NETWORK_ABSOLUTE_BYTES_RE,
            window,
            absolute_start=absolute_start,
            new_start=new_start,
            needs_predecessor=True,
        )
        self._mark_deny_terms(
            window,
            absolute_start=absolute_start,
            new_start=new_start,
            final=final,
        )

    def _reset_token(self, predecessor: int | None = None) -> None:
        self._token_length = 0
        self._token_sensitive = False
        self._token_tail = b""
        self._token_prefix = b""
        self._scheme_state = 0
        self._scheme_prefix.clear()
        self._authority_active = False
        self._authority_is_file = False
        self._authority_characters = 0
        self._posix_prefix_allowed = (
            predecessor is None
            or predecessor not in _POSIX_DISALLOWED_PREDECESSORS
        )

    @staticmethod
    def _is_scheme_character(value: int) -> bool:
        return (
            ord("a") <= value <= ord("z")
            or ord("A") <= value <= ord("Z")
            or ord("0") <= value <= ord("9")
            or value in (ord("+"), ord("-"), ord("."))
        )

    def _mark_absolute_prefix(self, fragment: bytes) -> None:
        if len(self._token_prefix) < 3:
            needed = 3 - len(self._token_prefix)
            self._token_prefix += fragment[:needed]
        prefix = self._token_prefix
        if self._posix_prefix_allowed and prefix.startswith(b"/"):
            self._token_sensitive = True
            self._flags.add("absolute_path")
        elif prefix.startswith(b"\\\\"):
            self._token_sensitive = True
            self._flags.add("absolute_path")
        elif (
            len(prefix) >= 3
            and (
                ord("a") <= prefix[0] <= ord("z")
                or ord("A") <= prefix[0] <= ord("Z")
            )
            and prefix[1:2] == b":"
            and prefix[2:3] in (b"/", b"\\")
        ):
            self._token_sensitive = True
            self._flags.add("absolute_path")

    def _restart_scheme(self, value: int) -> None:
        self._scheme_prefix.clear()
        if (
            ord("a") <= value <= ord("z")
            or ord("A") <= value <= ord("Z")
        ):
            self._scheme_prefix.append(value)
            self._scheme_state = 1
        else:
            self._scheme_state = 0

    def _track_unbounded_scheme(self, fragment: bytes) -> None:
        """Recognize URI schemes without retaining or limiting their length."""

        for value in fragment:
            if self._authority_active:
                if value == ord("@") and self._authority_characters:
                    self._flags.add("credential_url")
                if value in (ord("/"), ord("?"), ord("#")):
                    if (
                        value == ord("/")
                        and self._authority_is_file
                        and self._authority_characters == 0
                    ):
                        self._flags.add("absolute_path")
                    self._authority_active = False
                else:
                    self._authority_characters += 1

            if self._scheme_state == 0:
                self._restart_scheme(value)
            elif self._scheme_state == 1:
                if self._is_scheme_character(value):
                    if len(self._scheme_prefix) <= 4:
                        self._scheme_prefix.append(value)
                elif value == ord(":"):
                    self._scheme_state = 2
                else:
                    self._restart_scheme(value)
            elif self._scheme_state == 2:
                if value == ord("/"):
                    if bytes(self._scheme_prefix).lower() == b"file":
                        self._token_sensitive = True
                        self._flags.add("absolute_path")
                    self._scheme_state = 3
                else:
                    self._restart_scheme(value)
            elif self._scheme_state == 3:
                if value == ord("/"):
                    self._token_sensitive = True
                    self._authority_active = True
                    self._authority_is_file = (
                        bytes(self._scheme_prefix).lower() == b"file"
                    )
                    self._authority_characters = 0
                    self._scheme_state = 0
                    self._scheme_prefix.clear()
                else:
                    self._restart_scheme(value)

    def _track_fragment(self, fragment: bytes) -> None:
        self._mark_absolute_prefix(fragment)
        self._track_unbounded_scheme(fragment)
        combined = self._token_tail + fragment
        if not self._token_sensitive and (
            _WINDOWS_START_BYTES_RE.search(combined)
            or _POSIX_START_BYTES_RE.search(combined)
            or _POSIX_NETWORK_START_BYTES_RE.search(combined)
        ):
            self._token_sensitive = True
        self._token_length += len(fragment)
        if self._token_sensitive and self._token_length > self.carry_bytes:
            self._flags.add("semantic_limit")
        self._token_tail = combined[-self._TAIL_BYTES :]

    def _track_tokens(self, chunk: bytes) -> None:
        if (
            chunk
            and chunk[-1] in _TOKEN_DELIMITER_BYTES
            and not self._token_sensitive
            and not self._authority_active
            and not any(marker in chunk for marker in _TOKEN_STATE_MARKERS)
        ):
            self._reset_token(chunk[-1])
            return
        cursor = 0
        for match in _TOKEN_FRAGMENT_RE.finditer(chunk):
            if match.start() > cursor:
                self._reset_token(chunk[match.start() - 1])
            fragment = match.group(0)
            self._track_fragment(fragment)
            cursor = match.end()
        if cursor < len(chunk):
            self._reset_token(chunk[-1])

    def feed(self, chunk: bytes) -> None:
        previous_total = self._total_bytes
        self._track_tokens(chunk)
        window = self._overlap + chunk
        absolute_start = previous_total - len(self._overlap)
        self._total_bytes += len(chunk)
        self._scan_window(
            window,
            absolute_start=absolute_start,
            new_start=previous_total,
            final=False,
        )
        self._overlap = window[-self.carry_bytes :]

    def finish(self) -> set[str]:
        absolute_start = self._total_bytes - len(self._overlap)
        self._scan_window(
            self._overlap,
            absolute_start=absolute_start,
            new_start=self._total_bytes,
            final=True,
        )
        return set(self._flags)


def _scan_raw_file(
    path: Path,
    metadata: Any,
    *,
    roots: dict[str, str],
    secrets: list[str],
) -> set[str]:
    scanner = _RawSemanticScanner(roots=roots, secrets=secrets)
    for chunk in bounded_io._iter_regular_chunks(
        path, expected_metadata=metadata
    ):
        scanner.feed(chunk)
    return scanner.finish()


def _scan_structured_file(
    path: Path,
    metadata: Any,
    relative: str,
    secrets: list[str],
    errors: list[str],
) -> bool:
    """Scan decoded JSON semantics and report whether decoding was complete."""

    suffix = path.suffix.lower()
    if suffix == ".json":
        try:
            value, _byte_count = bounded_io._read_json_bounded(
                path, expected_metadata=metadata
            )
        except ValueError as exc:
            errors.append(f"{relative}: {exc}")
            return False
        for text in _iter_json_strings(value):
            _scan_semantic_text(relative, text, secrets, errors)
        return True
    elif suffix == ".jsonl":
        complete = True
        for line_number, line in bounded_io._iter_bounded_jsonl_lines(
            path, expected_metadata=metadata
        ):
            if line is None:
                complete = False
                errors.append(
                    f"{relative}:{line_number}: JSONL line exceeds "
                    f"{_limits.MAX_JSONL_LINE_BYTES} bytes"
                )
                continue
            if not line.strip():
                continue
            try:
                value = bounded_io._decode_json_bytes(line)
            except ValueError as exc:
                complete = False
                errors.append(f"{relative}:{line_number}: invalid JSON: {exc}")
                continue
            for text in _iter_json_strings(value):
                _scan_semantic_text(relative, text, secrets, errors)
        return complete
    return False


def _scan_publishable_files(
    root: Path, secrets: list[str], errors: list[str]
) -> bool:
    roots = _sanitization_roots(root)
    inspected_bytes = 0
    file_count = 0
    publishable_names_safe = True
    try:
        entries = bounded_io._iter_rooted_tree(
            root,
            maximum_directories=max(4096, _limits.MAX_BUNDLE_FILE_COUNT),
        )
        for path, metadata in entries:
            relative = path.relative_to(root).as_posix()
            is_directory = stat.S_ISDIR(metadata.st_mode)
            is_regular = stat.S_ISREG(metadata.st_mode)
            if not is_directory:
                file_count += 1
                if file_count > _limits.MAX_BUNDLE_FILE_COUNT:
                    errors.append(
                        "$: publishable bundle exceeds maximum file count "
                        f"({_limits.MAX_BUNDLE_FILE_COUNT})"
                    )
                    return False
                if is_regular:
                    if (
                        inspected_bytes + metadata.st_size
                        > _limits.MAX_BUNDLE_INSPECTED_BYTES
                    ):
                        errors.append(
                            "$: publishable bundle exceeds maximum inspected bytes "
                            f"({_limits.MAX_BUNDLE_INSPECTED_BYTES})"
                        )
                        return False
                    inspected_bytes += metadata.st_size
            if _scan_publishable_entry_name(relative, secrets, errors):
                publishable_names_safe = False
                continue
            if _ATOMIC_WRITE_TEMP_RE.fullmatch(path.name):
                errors.append(
                    f"{relative}: publishable bundle contains an atomic-write temporary"
                )
            if stat.S_ISLNK(metadata.st_mode):
                errors.append(f"{relative}: publishable bundle contains a symlink")
                continue
            if is_directory:
                continue
            if not is_regular:
                errors.append(
                    f"{relative}: publishable bundle contains an unsupported file type"
                )
                continue
            structured_complete = _scan_structured_file(
                path, metadata, relative, secrets, errors
            )
            flags = _scan_raw_file(
                path, metadata, roots=roots, secrets=secrets
            )
            if not structured_complete and "secret" in flags:
                errors.append(f"{relative}: contains a current known secret value")
            if not structured_complete and "credential_url" in flags:
                errors.append(f"{relative}: contains a credential URL")
            if not structured_complete and "absolute_path" in flags:
                errors.append(f"{relative}: contains a raw absolute path")
            if not structured_complete and "deny" in flags:
                errors.append(f"{relative}: contains a public safety deny pattern")
            if "semantic_limit" in flags:
                errors.append(f"{relative}: semantic token exceeds scan limit")
    except bounded_io._EntryLimitExceeded:
        errors.append(
            "$: publishable bundle exceeds maximum directory count "
            f"({max(4096, _limits.MAX_BUNDLE_FILE_COUNT)})"
        )
        return False
    return publishable_names_safe


__all__ = (
    "_PUBLIC_DENY_SUBSTRINGS",
    "_PUBLIC_BOUNDARY_DENY_RE",
    "_POSIX_DISALLOWED_PREDECESSORS",
    "_contains_public_deny_pattern",
    "_iter_json_strings",
    "_json_strings",
    "_scan_semantic_text",
    "_scan_publishable_entry_name",
    "_RawSemanticScanner",
    "_scan_publishable_files",
)
