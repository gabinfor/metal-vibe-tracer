"""Shared helpers for the runtime preparation scripts (CPython 3.9 compatible)."""
import contextlib
import ctypes
import fcntl
import hashlib
import os
import pathlib
import shutil
import tempfile

# File Provider (iCloud Drive) skips items carrying this attribute, so the large
# build tree inside a synced ~/Documents checkout stays local and is not uploaded.
SYNC_IGNORE = b"com.apple.fileprovider.ignore#P"


def exclude_from_sync(path):
    """Mark a directory as local-only for iCloud Drive; a no-op elsewhere."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        name = os.fsencode(str(path))
        if libc.getxattr(name, SYNC_IGNORE, None, 0, 0, 0) >= 0:
            return
        libc.setxattr(name, SYNC_IGNORE, b"1", 1, 0, 0)
    except (OSError, AttributeError):
        pass


def build_directory(root):
    """Create the build tree, excluded from iCloud syncing, and return it."""
    build = pathlib.Path(root) / "build"
    build.mkdir(parents=True, exist_ok=True)
    exclude_from_sync(build)
    return build


@contextlib.contextmanager
def locked(path):
    """Serialize concurrent build.sh and tests/verify.py preparation runs."""
    with open(path, "a+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write(path, data):
    """Write bytes through a unique temporary file and rename it into place."""
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".partial", dir=str(path.parent))
    try:
        with os.fdopen(handle, "wb") as output:
            output.write(data)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


def atomic_write_text(path, text):
    atomic_write(path, text.encode("utf-8"))


def file_table(directory, subdirectories):
    """Map every file below the given subdirectories to its SHA-256 or symlink target."""
    directory = pathlib.Path(directory)
    table = {}
    for subdirectory in subdirectories:
        base = directory / subdirectory
        if not base.is_dir() or base.is_symlink():
            continue
        for path in sorted(base.rglob("*")):
            relative = path.relative_to(directory).as_posix()
            if path.is_symlink():
                table[relative] = "link:" + os.readlink(str(path))
            elif path.is_file():
                table[relative] = sha256_file(path)
    return table


def replace_directory(stage, destination):
    """Publish a staged directory; an existing directory or symlink is moved aside first."""
    destination = pathlib.Path(destination)
    retired = destination.with_name("." + destination.name + "-retired-" + str(os.getpid()))
    if destination.exists() or destination.is_symlink():
        os.replace(str(destination), str(retired))
    os.replace(str(stage), str(destination))
    if retired.is_symlink():
        retired.unlink()
    elif retired.exists():
        shutil.rmtree(str(retired))
