"""Source assembly and run isolation shared by tests/verify.py and tests/benchmark.py.

The GPU suite is one Swift program: production main.swift without its GUI entry point,
Sources/*.swift, then test files in a fixed order. Every cut uses a marker that must
occur exactly once, so a moved or renamed marker fails here instead of silently compiling
the application's `app.run()` (which would hang) or dropping checks.
"""
from pathlib import Path
import datetime
import fcntl
import os
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'
ENTRY_POINT = '// 5. App Entry Point'
GPU_HELPERS_END = '// verify.py: end of shared GPU helpers'
CONTROLLER_BEGIN = '// verify.py: begin studio controller'
CONTROLLER_END = '// verify.py: end studio controller'
# Per-run output directory for fixtures, previews and exported files (see output_directory()).
OUTPUT_VARIABLE = 'VIBE_TEST_OUTPUT'


class AssemblyError(SystemExit):
    pass


def split_once(text: str, marker: str, name: str) -> tuple:
    count = text.count(marker)
    if count != 1:
        raise AssemblyError(f'{name}: expected exactly one line "{marker}", found {count}')
    head, tail = text.split(marker)
    if not head.endswith('\n') and head:
        raise AssemblyError(f'{name}: "{marker}" must start a line')
    return head, tail


def production_source() -> str:
    """main.swift without the GUI entry point, followed by Sources/*.swift in name order."""
    main = (ROOT / 'main.swift').read_text()
    head, tail = split_once(main, ENTRY_POINT, 'main.swift')
    if 'app.run()' in head or 'app.run()' not in tail:
        raise AssemblyError(f'main.swift: app.run() must appear only after "{ENTRY_POINT}"')
    sources = sorted((ROOT / 'Sources').glob('*.swift'))
    if not sources:
        raise AssemblyError('Sources/*.swift: no production sources found')
    for path in sources:
        if 'app.run()' in path.read_text():
            raise AssemblyError(f'{path.relative_to(ROOT)}: the entry point belongs in main.swift')
    return head + '\n' + '\n'.join(p.read_text() for p in sources)


def test_file(name: str) -> str:
    path = TESTS / name
    if not path.is_file():
        raise AssemblyError(f'tests/{name} is missing')
    return path.read_text()


def gpu_helpers() -> str:
    """The renderer, readback and production-render helpers at the top of GPUChecks.swift."""
    return split_once(test_file('GPUChecks.swift'), GPU_HELPERS_END, 'tests/GPUChecks.swift')[0]


def studio_controller() -> str:
    """Only the StudioController construction from StudioChecks.swift."""
    text = test_file('StudioChecks.swift')
    tail = split_once(text, CONTROLLER_BEGIN, 'tests/StudioChecks.swift')[1]
    return split_once(tail, CONTROLLER_END, 'tests/StudioChecks.swift')[0]


def replace_once(text: str, old: str, new: str, name: str) -> str:
    count = text.count(old)
    if count != 1:
        raise AssemblyError(f'{name}: expected exactly one "{old.strip()}", found {count}')
    return text.replace(old, new)


def compile_swift(source: str, folder: Path, name: str) -> Path:
    swift = folder / 'main.swift'
    swift.write_text(source)
    binary = folder / name
    subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'VIBE_TESTING', '-target', platform.machine() + '-apple-macosx26.0',
                    '-module-cache-path', str(folder / 'cache'), str(swift), '-o', str(binary)], check=True)
    return binary


def suite_lock():
    """Serializes whole suite runs in this checkout (preparation, fixtures and GPU work)."""
    lock_directory = ROOT / 'build'
    lock_directory.mkdir(exist_ok=True)
    handle = open(lock_directory / 'verify.lock', 'a+')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Waiting for another test run in this checkout to finish…', flush=True)
        fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def output_directory(prefix: str, keep: int = 3) -> Path:
    """A fresh build/checks/runs/<prefix>-<time>-<pid> directory; build/checks/latest points to it.
    Older runs of the same prefix beyond `keep` are removed (callers hold suite_lock())."""
    runs = ROOT / 'build' / 'checks' / 'runs'
    runs.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    folder = runs / f'{prefix}-{stamp}-{os.getpid()}'
    folder.mkdir()
    previous = sorted(p for p in runs.glob(prefix + '-*') if p.is_dir() and p != folder)
    for stale in previous[:max(0, len(previous) - (keep - 1))]:
        shutil.rmtree(stale, ignore_errors=True)
    latest = ROOT / 'build' / 'checks' / 'latest'
    temporary = latest.with_name('.latest-' + str(os.getpid()))
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(folder.relative_to(latest.parent), target_is_directory=True)
    os.replace(temporary, latest)
    return folder
