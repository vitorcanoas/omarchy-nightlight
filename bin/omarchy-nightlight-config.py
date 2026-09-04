#!/usr/bin/env python3
"""Safe, bounded persistence for omarchy-nightlight's per-output state."""

from __future__ import annotations

import os
import re
import secrets
import signal
import stat
import sys


CONFIG_BASENAME = "nightlight.conf"
MAX_CONFIG_BYTES = 64 * 1024
MAX_CONFIG_ENTRIES = 1024
KEY_RE = re.compile(rb"[A-Za-z0-9_-]+(?:\.brightness)?\Z")
LINE_RE = re.compile(
    rb"^[ \t]*([A-Za-z0-9_-]+(?:\.brightness)?)[ \t]*=[ \t]*([0-9]+)([ \t]*(?:#.*)?)$"
)

HEADER = b"""# Night light: per-output intensity, in percent.\n#\n# Same scale as the Windows slider: 0 = neutral, 100 = maximum.\n# Kelvin = 6500 - (53 x percent).\n#\n# Written by `omarchy-nightlight`. You can edit it by hand, but the easy way\n# is `omarchy-nightlight DP-2 40`, which also applies it right away.\n#\n# The output name is the same one `hyprctl monitors` prints.\n"""


class ConfigError(Exception):
    """An unsafe, malformed, or unavailable configuration boundary."""


def fail(message: str) -> None:
    raise ConfigError(message)


def config_parts(config_path: str) -> tuple[str, str]:
    path = os.path.abspath(os.path.expanduser(config_path))
    directory, basename = os.path.split(path)
    if basename != CONFIG_BASENAME:
        fail(f"unexpected configuration path: {config_path}")
    return directory, basename


def open_directory_path(directory: str, create: bool) -> int | None:
    """Walk an absolute path with openat-style no-following at every level."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    dirfd: int | None = None
    try:
        dirfd = os.open("/", flags)
        for component in directory.split("/"):
            if not component:
                continue
            try:
                nextfd = os.open(component, flags, dir_fd=dirfd)
            except FileNotFoundError:
                if not create:
                    os.close(dirfd)
                    return None
                try:
                    os.mkdir(component, 0o700, dir_fd=dirfd)
                except FileExistsError:
                    pass
                nextfd = os.open(component, flags, dir_fd=dirfd)
            os.close(dirfd)
            dirfd = nextfd
        return dirfd
    except OSError as error:
        if dirfd is not None:
            os.close(dirfd)
        fail(f"could not open configuration directory safely: {error}")


def open_config_dir(config_path: str, create: bool) -> int | None:
    directory, _ = config_parts(config_path)
    dirfd = open_directory_path(directory, create)
    if dirfd is None:
        return None

    directory_stat = os.fstat(dirfd)
    if not stat.S_ISDIR(directory_stat.st_mode):
        os.close(dirfd)
        fail("configuration parent is not a directory")
    if directory_stat.st_uid != os.geteuid():
        os.close(dirfd)
        fail("configuration parent is not owned by the current user")
    if directory_stat.st_mode & 0o022:
        os.close(dirfd)
        fail("configuration parent is writable by another user")
    return dirfd


def open_config_file(dirfd: int, basename: str) -> tuple[int | None, os.stat_result | None]:
    try:
        fd = os.open(
            basename,
            os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=dirfd,
        )
    except FileNotFoundError:
        return None, None
    except OSError as error:
        fail(f"could not open configuration without following a symlink: {error}")

    file_stat = os.fstat(fd)
    if not stat.S_ISREG(file_stat.st_mode):
        os.close(fd)
        fail("configuration is not a regular file")
    if file_stat.st_uid != os.geteuid():
        os.close(fd)
        fail("configuration is not owned by the current user")
    if file_stat.st_mode & 0o022:
        os.close(fd)
        fail("configuration is writable by another user")
    if file_stat.st_size > MAX_CONFIG_BYTES:
        os.close(fd)
        fail(f"configuration exceeds the {MAX_CONFIG_BYTES}-byte limit")
    return fd, file_stat


def read_bounded(fd: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(fd, min(8192, MAX_CONFIG_BYTES + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > MAX_CONFIG_BYTES:
            fail(f"configuration exceeds the {MAX_CONFIG_BYTES}-byte limit")
    return b"".join(chunks)


def read_config(config_path: str) -> bytes:
    dirfd = open_config_dir(config_path, create=False)
    if dirfd is None:
        return b""
    try:
        fd, _ = open_config_file(dirfd, CONFIG_BASENAME)
        if fd is None:
            return b""
        try:
            return read_bounded(fd)
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


def records(data: bytes) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in data.splitlines():
        stripped = line.lstrip(b" \t")
        if not stripped or stripped.startswith(b"#"):
            continue
        match = LINE_RE.fullmatch(line)
        if not match:
            fail("configuration contains an invalid line")
        key = match.group(1).decode("ascii")
        value = int(match.group(2))
        if value > 100:
            fail(f"configuration value for {key} is outside 0-100")
        result[key] = value
        if len(result) > MAX_CONFIG_ENTRIES:
            fail(f"configuration has more than {MAX_CONFIG_ENTRIES} entries")
    return result


def command_read(config_path: str) -> None:
    for key, value in sorted(records(read_config(config_path)).items()):
        print(f"{key}\t{value}")


def split_line_ending(line: bytes) -> tuple[bytes, bytes]:
    if line.endswith(b"\r\n"):
        return line[:-2], b"\r\n"
    if line.endswith(b"\n"):
        return line[:-1], b"\n"
    return line, b""


def rewrite(data: bytes, key: str, value: int) -> bytes:
    key_bytes = key.encode("ascii")
    output: list[bytes] = []
    found = False
    for raw_line in data.splitlines(keepends=True):
        body, ending = split_line_ending(raw_line)
        match = LINE_RE.fullmatch(body)
        if not match or match.group(1) != key_bytes:
            output.append(raw_line)
            continue
        rest = match.group(3)
        comment_at = rest.find(b"#")
        replacement = match.group(1)
        replacement += b"=" + str(value).encode("ascii")
        if comment_at >= 0:
            replacement += b" " + rest[comment_at:]
        output.append(replacement + ending)
        found = True

    rewritten = b"".join(output)
    if not found:
        if rewritten and not rewritten.endswith(b"\n"):
            rewritten += b"\n"
        rewritten += key_bytes + b"=" + str(value).encode("ascii") + b"\n"
    if len(rewritten) > MAX_CONFIG_BYTES:
        fail(f"updated configuration exceeds the {MAX_CONFIG_BYTES}-byte limit")
    return rewritten


def target_snapshot(dirfd: int) -> tuple[int | None, os.stat_result | None, bytes]:
    fd, file_stat = open_config_file(dirfd, CONFIG_BASENAME)
    if fd is None:
        return None, None, b""
    try:
        return fd, file_stat, read_bounded(fd)
    except Exception:
        os.close(fd)
        raise


def same_target(dirfd: int, original: os.stat_result | None) -> bool:
    try:
        current = os.stat(CONFIG_BASENAME, dir_fd=dirfd, follow_symlinks=False)
    except FileNotFoundError:
        return original is None
    if original is None:
        return False
    return (
        current.st_dev == original.st_dev
        and current.st_ino == original.st_ino
        and current.st_uid == original.st_uid
        and stat.S_IFMT(current.st_mode) == stat.S_IFMT(original.st_mode)
        and stat.S_IMODE(current.st_mode) == stat.S_IMODE(original.st_mode)
        and current.st_size == original.st_size
        and current.st_mtime_ns == original.st_mtime_ns
        and current.st_ctime_ns == original.st_ctime_ns
    )


def create_temp(dirfd: int) -> tuple[int, str]:
    for _ in range(16):
        name = f".nightlight.conf.{secrets.token_hex(16)}"
        try:
            fd = os.open(
                name,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | os.O_CLOEXEC
                | os.O_NOFOLLOW,
                0o600,
                dir_fd=dirfd,
            )
            return fd, name
        except FileExistsError:
            continue
        except OSError as error:
            fail(f"could not create a private temporary file: {error}")
    fail("could not create an unpredictable temporary file")


def write_all(fd: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        offset += os.write(fd, data[offset:])
    os.fsync(fd)


def command_write(config_path: str, key: str, value_text: str) -> None:
    if not KEY_RE.fullmatch(key.encode("ascii")):
        fail("invalid configuration key")
    try:
        value = int(value_text, 10)
    except ValueError:
        fail("configuration value is not an integer")
    if not 0 <= value <= 100:
        fail("configuration value is outside 0-100")

    dirfd = open_config_dir(config_path, create=True)
    if dirfd is None:
        fail("configuration directory is unavailable")
    old_fd: int | None = None
    temp_name: str | None = None
    try:
        old_fd, old_stat, old_data = target_snapshot(dirfd)
        records(old_data)
        updated = rewrite(old_data or HEADER, key, value)
        temp_fd, temp_name = create_temp(dirfd)
        try:
            write_all(temp_fd, updated)
        finally:
            os.close(temp_fd)

        if not same_target(dirfd, old_stat):
            fail("configuration changed while it was being updated")
        os.replace(
            temp_name,
            CONFIG_BASENAME,
            src_dir_fd=dirfd,
            dst_dir_fd=dirfd,
        )
        temp_name = None
        os.fsync(dirfd)
    finally:
        if old_fd is not None:
            os.close(old_fd)
        if temp_name is not None:
            try:
                os.unlink(temp_name, dir_fd=dirfd)
            except FileNotFoundError:
                pass
        os.close(dirfd)


def command_check(config_path: str) -> None:
    read_config(config_path)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: omarchy-nightlight-config.py {read|check|write} CONFIG [KEY VALUE]", file=sys.stderr)
        return 2
    try:
        command = sys.argv[1]
        if command == "read" and len(sys.argv) == 3:
            command_read(sys.argv[2])
        elif command == "check" and len(sys.argv) == 3:
            command_check(sys.argv[2])
        elif command == "write" and len(sys.argv) == 5:
            command_write(sys.argv[2], sys.argv[3], sys.argv[4])
        else:
            raise ConfigError("invalid arguments")
    except (ConfigError, OSError, ValueError) as error:
        print(f"omarchy-nightlight-config: {error}", file=sys.stderr)
        return 1
    return 0


def terminate(signum: int, _frame: object) -> None:
    raise SystemExit(128 + signum)


signal.signal(signal.SIGINT, terminate)
signal.signal(signal.SIGTERM, terminate)

if __name__ == "__main__":
    raise SystemExit(main())
