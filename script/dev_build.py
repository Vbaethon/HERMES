#!/usr/bin/env python3
"""Build one current Debug candidate with a stable, worktree-local cache."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import time

from app_regression import catch_interruptions, run_process


ROOT = Path(__file__).resolve().parents[1]
APP_EXECUTABLE = "HERMES.app/Contents/MacOS/HERMES"
MANAGED_MARKER = ".hermes-managed-products"
MANAGED_CONTENT = "HERMES managed build products\n"


def running_executables():
    result = subprocess.run(("/usr/bin/pgrep", "-x", "HERMES"), capture_output=True, text=True)
    if result.returncode == 1:
        return ()
    if result.returncode:
        raise ValueError("无法核对 HERMES 进程，未开始构建。")
    paths = []
    for pid in result.stdout.split():
        process = subprocess.run(("/bin/ps", "-p", pid, "-o", "comm="), capture_output=True, text=True)
        # A process may have exited between pgrep and ps.
        if process.returncode and not process.stdout.strip():
            probe = subprocess.run(("/bin/ps", "-p", pid, "-o", "pid="), capture_output=True, text=True)
            if not probe.stdout.strip():
                continue
        value = process.stdout.strip()
        if process.returncode or not value.startswith("/"):
            raise ValueError(f"无法确认运行中 HERMES（PID {pid}）的路径，未开始构建。")
        paths.append(Path(value).resolve())
    return tuple(paths)


def assert_idle(products):
    for executable in running_executables():
        if executable.is_relative_to(products):
            raise ValueError(f"这个 Debug 候选仍在运行，请退出后再构建：{executable}")


@contextmanager
def build_locks(paths):
    handles = []
    try:
        for path in sorted(set(paths)):
            path.parent.mkdir(parents=True, exist_ok=True)
            handle = path.open("a")
            handles.append(handle)
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("另一次 Debug 构建正在使用相同目录，等待完成…", flush=True)
                fcntl.flock(handle, fcntl.LOCK_EX)
        yield
    finally:
        for handle in reversed(handles):
            handle.close()


def absolute_path(root, value):
    path = Path(value).expanduser()
    return (path if path.is_absolute() else root / path).resolve()


def build(root=ROOT, *, timing=False, launch=False, environment=None):
    root = Path(root).resolve()
    env = dict(os.environ if environment is None else environment)
    derived = absolute_path(root, env.get("HERMES_DERIVED_DATA_DIR", str(root / ".build/development/DerivedData")))
    custom = bool(env.get("HERMES_PRODUCTS_DIR"))
    identifier = hashlib.sha256(os.fsencode(root)).hexdigest()[:6]
    products = absolute_path(root, env["HERMES_PRODUCTS_DIR"]) if custom else derived / "Build/Products" / f"Debug.{identifier}"
    product_lock = products.parent / (".hermes-development-" + hashlib.sha256(os.fsencode(products)).hexdigest()[:12] + ".lock")
    locks = (derived / ".hermes-development.lock", product_lock)
    started = time.monotonic()
    # Check once before any output mutation, and again after waiting for the locks.
    assert_idle(products)
    with build_locks(locks):
        assert_idle(products)
        env.update(HERMES_BUILD_CONFIGURATION="Debug", HERMES_DERIVED_DATA_DIR=str(derived),
                   HERMES_PRODUCTS_DIR=str(products))
        env.pop("HERMES_MANAGED_PRODUCTS_DIR", None)
        active = products / ".hermes-active-build"
        if not custom:
            marker = products / MANAGED_MARKER
            if products.exists() and (products.is_symlink() or not marker.is_file() or marker.read_text() != MANAGED_CONTENT):
                raise ValueError(f"无法确认产品目录归属，未覆盖：{products}")
            products.mkdir(parents=True, exist_ok=True)
            marker.write_text(MANAGED_CONTENT)
            started_at = subprocess.check_output(("/bin/ps", "-p", str(os.getpid()), "-o", "lstart="),
                                                text=True, env=dict(env, LC_ALL="C")).rstrip("\n")
            active.write_text(f"{os.getpid()}\n{started_at}\n")
            env["HERMES_MANAGED_PRODUCTS_DIR"] = str(products)
        command = ("/bin/bash", str(root / "build.sh"), "--no-run", *(("--timing",) if timing else ()))
        print(f"Debug 缓存：{derived}\n当前候选：{products / 'HERMES.app'}", flush=True)
        try:
            run_process(command, env=env)
        finally:
            if not custom:
                active.unlink(missing_ok=True)
        app = products / "HERMES.app"
        if not (products / APP_EXECUTABLE).is_file():
            raise ValueError(f"构建未生成可执行文件：{app}")
        print(f"PASS: Debug 构建完成（{time.monotonic() - started:.2f}s）：{app}", flush=True)
        if launch:
            if running_executables():
                print(f"已有 HERMES 正在运行，保留其任务；新候选可稍后打开：{app}")
            else:
                subprocess.run(("/usr/bin/open", str(app)), check=True)
        return app


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timing", action="store_true", help="输出 Xcode 各构建阶段耗时")
    parser.add_argument("--run", action="store_true", help="构建后启动；已有 HERMES 运行时保留它")
    args = parser.parse_args(argv)
    try:
        with catch_interruptions():
            build(timing=args.timing, launch=args.run)
        return 0
    except subprocess.CalledProcessError as error:
        print(f"FAIL: Debug 构建退出 {error.returncode}", file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
