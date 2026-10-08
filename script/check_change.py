#!/usr/bin/env python3
"""Show or run the existing checks appropriate to a HERMES change."""
import argparse
from dataclasses import replace
import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

from change_checks import commands, make_plan
from app_regression import catch_interruptions, stop_process_group


ROOT = Path(__file__).resolve().parents[1]


def git(root, *args):
    return subprocess.check_output(("git", "-C", str(root), *args))


def resolve_base(root, base):
    return git(root, "rev-parse", "--verify", "--end-of-options", f"{base}^{{commit}}").decode().strip()


def changed_paths(root, base):
    fields = git(root, "diff", "--name-status", "-z", "--find-renames", base, "--").split(b"\0")
    paths, index = set(), 0
    while index < len(fields) and fields[index]:
        status = fields[index].decode("ascii")
        count = 2 if status.startswith(("R", "C")) else 1
        paths.update(os.fsdecode(path) for path in fields[index + 1:index + count + 1])
        index += count + 1
    paths.update(os.fsdecode(path) for path in git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if path)
    return tuple(sorted(paths))


def normalize_paths(root, paths):
    result = []
    for item in paths:
        path = Path(item)
        if path.is_absolute():
            path = path.relative_to(root)
        if ".." in path.parts or not path.parts or path.parts[0] == ".git":
            raise ValueError(f"请指定工作树内的文件路径：{item}")
        result.append(path.as_posix())
    return tuple(result)


def source_state(root):
    """Do not claim a pass for source that changed while checks were running."""
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    digest = hashlib.sha256()
    for value in sorted(set(paths)):
        path = root / os.fsdecode(value)
        if not value or (path.suffix not in (".swift", ".py", ".sh", ".command", ".xcconfig", ".pbxproj", ".plist", ".json")
                         and not value.startswith(b"Build/Assets/")):
            continue
        digest.update(value + b"\0")
        try:
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        except FileNotFoundError:
            digest.update(b"<deleted>")
    return digest.hexdigest()


def check_format(root, base, paths):
    subprocess.run(("git", "diff", "--check", base, "--", *paths), cwd=root, check=True)
    # git diff does not include untracked files. Check their text separately.
    untracked = {os.fsdecode(value) for value in git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if value}
    problems = []
    for relative in sorted(untracked.intersection(paths)):
        path = root / relative
        try:
            content = path.read_bytes()
            if b"\0" in content:
                continue
            lines = content.decode("utf-8").splitlines()
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        for number, line in enumerate(lines, 1):
            if line.rstrip(" \t") != line:
                problems.append(f"{relative}:{number}: 行末空白")
            if line.startswith(("<<<<<<< ", ">>>>>>> ")) or line == "=======":
                problems.append(f"{relative}:{number}: 未解决的合并标记")
        if content and not content.endswith(b"\n"):
            problems.append(f"{relative}: 文件末尾缺少换行")
    if problems:
        raise ValueError("\n".join(problems))


def run_plan(root, base, plan):
    before = source_state(root)
    started = time.monotonic()
    steps = (("format", ()), *commands(plan.checks, sys.executable, previously_checked=plan.previously_checked))
    for name, command in steps:
        step = time.monotonic()
        print(f"RUN: {name}", flush=True)
        if name == "format":
            check_format(root, base, plan.paths)
        else:
            process = subprocess.Popen(command, cwd=root, start_new_session=True)
            try:
                status = process.wait()
                if status:
                    raise subprocess.CalledProcessError(status, command)
            finally:
                stop_process_group(process)
        print(f"PASS: {name} ({time.monotonic() - step:.2f}s)", flush=True)
    if source_state(root) != before:
        raise ValueError("检查期间源码、测试或配置发生变化；请重新选择受影响的检查，当前结果不能代表最新内容。")
    print(f"PASS: 本轮 {len(steps)} 项检查，共 {time.monotonic() - started:.2f}s；结果仅适用于本次内容。", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="可选：明确指定工作树内的文件路径")
    parser.add_argument("--base", default="HEAD", help="比较基准；默认 HEAD，包括暂存、未暂存和新文件")
    final_mode = parser.add_mutually_exclusive_group()
    final_mode.add_argument("--final", action="store_true", help="运行本次范围的专项与最终候选检查")
    final_mode.add_argument("--final-only", action="store_true", help="仅补充集成检查；需此前专项已通过且内容未变")
    parser.add_argument("--run", action="store_true", help="执行计划；默认只显示")
    args = parser.parse_args(argv)
    try:
        base = resolve_base(ROOT, args.base)
        paths = normalize_paths(ROOT, args.paths) if args.paths else changed_paths(ROOT, base)
        plan = make_plan(paths, final=args.final)
        if args.final_only:
            if plan.unknown:
                raise ValueError("存在未映射代码，需先运行完整计划，不能只补充集成检查。")
            plan = replace(plan, checks=plan.final_extra, final_extra=frozenset(), previously_checked=plan.checks)
        if not paths:
            print("没有检测到改动。可用 --base <ref> 查看累计改动，或明确指定文件路径。")
            return 0
        mode = "最终补充" if args.final_only else "最终候选" if args.final else "专项"
        print(f"HERMES {mode}检查计划（基准 {args.base}）", flush=True)
        if args.final_only:
            print("本轮只补充集成检查；此前专项已通过且源码、测试、依赖、配置和工具链未变时才能复用。")
        for path, reason in plan.reasons:
            print(f"  {path}: {reason}")
        print("\n命令：\n  git diff --check（另检查所选新文件的文本格式）")
        for _, command in commands(plan.checks, sys.executable, previously_checked=plan.previously_checked):
            print("  " + shlex.join(command))
        if plan.final_extra:
            print("\n最终候选需补充：")
            for _, command in commands(plan.final_extra, sys.executable, previously_checked=plan.checks):
                print("  " + shlex.join(command))
        if any(key in plan.checks or key in plan.final_extra for key in ("download", "composition", "metadata")):
            print("\n真实平台样本及安装验收按当前任务授权另行执行。")
        if args.run:
            with catch_interruptions():
                run_plan(ROOT, base, plan)
        return 0
    except subprocess.CalledProcessError as error:
        print(f"FAIL: 检查命令退出 {error.returncode}", file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("检查已中断。", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
