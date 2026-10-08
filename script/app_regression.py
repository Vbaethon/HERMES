"""Compile the three app regressions once; always execute tests in fresh isolation."""
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from regression_compilation import compile_program

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path.home() / "Library/Caches/HERMESRegression"
SUITES = {
    "model": ("HermesModelRegression", "ModelSafetyRegression", "HermesModelSafetyRegression", 60),
    "uiux": ("HermesUIUXRegression", "UIUXRegression", "HermesUIUXRegression", 60),
    "native": ("HermesNativeMediaRegression", "NativeMediaRegression", "HermesNativeMediaRegression", 90),
}


@dataclass(frozen=True)
class Compiler:
    command: tuple
    identity: str
    sdk: str
    target: str

    @property
    def flags(self):
        # Swift tracks dependencies between files; debug checks remain enabled.
        return ("-incremental", "-j", "4", "-Onone", "-emit-dependencies", "-emit-module",
                "-swift-version", "6", "-parse-as-library",
                "-module-name", "HermesAppRegression", "-sdk", self.sdk,
                "-target", self.target)

    @property
    def link_flags(self):
        return ("-sdk", self.sdk, "-target", self.target)

    @classmethod
    def discover(cls):
        executable = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
        version = subprocess.check_output([executable, "--version"], stderr=subprocess.STDOUT, text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        settings = Path(sdk) / "SDKSettings.plist"
        sdk_identity = hashlib.sha256(settings.read_bytes()).hexdigest()
        tool_stat = Path(executable).stat()
        identity = json.dumps([executable, version, sdk_identity, tool_stat.st_size, tool_stat.st_mtime_ns])
        return cls((executable,), identity, sdk, f"{platform.machine()}-apple-macos27.0")


def source_snapshot(root):
    """Hash and compile the same bytes, even if files change during compilation."""
    inputs = {}
    for path in sorted((root / "Sources").rglob("*.swift")):
        if path.name == "tool.swift":
            continue
        content = path.read_bytes()
        if path.name == "HermesApp.swift":
            if content.count(b"@main\n") != 1:
                raise ValueError("Cannot isolate the HERMES application entry point")
            content = content.replace(b"@main\n", b"@MainActor\n", 1)
        inputs[str(path.relative_to(root))] = content
    for folder, entry, _, _ in SUITES.values():
        relative = f"Tests/{folder}/RegressionMain.swift"
        content = (root / relative).read_bytes()
        marker = f"@main enum {entry}".encode()
        if content.count(marker) != 1:
            raise ValueError(f"Cannot isolate the {folder} entry point")
        content = content.replace(marker, f"enum {entry}".encode(), 1)
        # The original UI entry points terminate their process themselves.
        # Clean only this invocation's unique preferences on those normal exits.
        content = content.replace(b"exit(0)", b"AppRegressionMain.finish(0)")
        content = content.replace(b"exit(1)", b"AppRegressionMain.finish(1)")
        # Swift uses each source basename to distinguish private declarations.
        inputs[f"Tests/{folder}/{entry}.swift"] = content
    inputs["script/AppRegressionMain.swift"] = (root / "script/AppRegressionMain.swift").read_bytes()
    return inputs


def fingerprint(compiler, inputs):
    environment = {name: os.environ.get(name) for name in (
        "DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT", "CPATH", "LIBRARY_PATH", "SWIFT_EXEC")}
    digest = hashlib.sha256(json.dumps({"schema": 2, "project": "HERMES/app-regressions",
        "command": compiler.command, "compiler": compiler.identity,
        "flags": compiler.flags, "link_flags": compiler.link_flags,
        "environment": environment}, sort_keys=True).encode())
    for relative, content in sorted(inputs.items()):
        digest.update(relative.encode() + b"\0" + str(len(content)).encode() + b"\0" + content)
    return digest.hexdigest()


def binary_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stop_process_group(process):
    # A fixture can leave descendants behind after its immediate parent exits.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_process(command, *, env=None, timeout=None, capture=False):
    process = subprocess.Popen(command, env=env, start_new_session=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None, text=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command, output=output)
        return output or ""
    finally:
        stop_process_group(process)


@contextmanager
def build_lock(build_cache):
    build_cache.mkdir(parents=True, exist_ok=True)
    with (build_cache / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def prepare_program(root, build_cache, compiler):
    """Caller holds build_lock through copying the executable for its tests."""
    inputs = source_snapshot(root)
    key = fingerprint(compiler, inputs)
    binary = build_cache / "regression"
    manifest = build_cache / "manifest.json"
    try:
        stored = json.loads(manifest.read_text())
        if (stored["key"] == key and not binary.is_symlink()
                and binary.is_file() and os.access(binary, os.X_OK)
                and stored["binary_sha256"] == binary_hash(binary)):
            return binary, key, True
    except (OSError, ValueError, KeyError, TypeError):
        pass
    print("BUILD: shared model/UI/native regression program (Swift incremental)", flush=True)
    with tempfile.TemporaryDirectory(prefix=".compile-", dir=build_cache) as directory:
        staging = Path(directory)
        built, output = compile_program(compiler, inputs, build_cache, staging,
                                        fingerprint(compiler, {}), run_process)
        for line in output.splitlines():
            if ": warning:" in line:
                print(line.replace(str(build_cache / "incremental/sources") + "/", "")
                          .replace(str(staging) + "/", ""), file=sys.stderr)
        built.chmod(0o700)
        staged_manifest = staging / "manifest.json"
        staged_manifest.write_text(json.dumps({"key": key, "binary_sha256": binary_hash(built)}))
        # Publish only a successful build; a failed rebuild leaves the old pair intact.
        # An interruption between these replacements yields a hash mismatch, never a hit.
        os.replace(built, binary)
        os.replace(staged_manifest, manifest)
    return binary, key, False


def run_suites(suites, *, root=ROOT, cache=CACHE, compiler=None, arguments=(), build_only=False):
    suites = tuple(suites)
    if not suites or any(suite not in SUITES for suite in suites):
        raise ValueError("Choose model, uiux or native regressions")
    start = time.monotonic()
    compiler = compiler or Compiler.discover()
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hermes-app-regressions-", dir=cache) as directory:
        temporary = Path(directory)
        executables = {}
        with build_lock(cache / "app-regression-build"):
            binary, key, reused = prepare_program(root, cache / "app-regression-build", compiler)
            if not build_only:
                for suite in suites:
                    folder = temporary / suite
                    folder.mkdir()
                    name = SUITES[suite][2] + "-" + uuid.uuid4().hex
                    executable = folder / name
                    shutil.copy2(binary, executable)
                    executables[suite] = executable
        prepared_seconds = time.monotonic() - start
        print(f"{'REUSE' if reused else 'READY'}: shared regression {key[:12]} ({prepared_seconds:.2f}s)", flush=True)
        for suite, executable in executables.items():
            folder = executable.parent
            domain = executable.name
            preview_title = None
            if suite == "native" and "--inspector-location-preview" in arguments:
                preview_title = "HERMES Location Preview"
            elif suite == "uiux" and "--arrangement-preview" in arguments:
                preview_title = "HERMES Arrangement Preview"
            if preview_title:
                contents = folder / f"{preview_title}.app/Contents"
                bundled = contents / "MacOS" / domain
                bundled.parent.mkdir(parents=True)
                with (contents / "Info.plist").open("wb") as stream:
                    plistlib.dump({"CFBundleIdentifier": domain, "CFBundleExecutable": domain,
                                  "CFBundleName": preview_title, "CFBundlePackageType": "APPL"}, stream)
                shutil.move(executable, bundled)
                executable = bundled
            scratch = folder / "tmp"
            scratch.mkdir()
            env = dict(os.environ, HERMES_REGRESSION_SUITE=suite, TMPDIR=str(scratch) + "/")
            suite_start = time.monotonic()
            try:
                run_process([str(executable), str(folder / "fixtures"), *arguments],
                            env=env, timeout=120 if suite == "uiux" and preview_title else SUITES[suite][3])
            finally:
                # Also clean this precise, unique domain after crashes or interruption.
                defaults = Path("/usr/bin/defaults")
                if defaults.is_file():
                    subprocess.run([str(defaults), "delete", domain], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=5, check=False)
            print(f"PASS: {suite} suite ({time.monotonic() - suite_start:.2f}s)", flush=True)
    return {"key": key, "reused": reused, "prepare_seconds": prepared_seconds}


@contextmanager
def catch_interruptions():
    def interrupted(number, _frame):
        raise SystemExit(128 + number)
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {number: signal.signal(number, interrupted) for number in signals}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def cli(suites, arguments=(), *, build_only=False):
    try:
        with catch_interruptions():
            run_suites(suites, arguments=arguments, build_only=build_only)
        return 0
    except subprocess.CalledProcessError as error:
        if error.output:
            print(error.output, file=sys.stderr)
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"HERMES regression failed: {error}", file=sys.stderr)
        return 1


def legacy_cli(suite):
    arguments = sys.argv[1:]
    return cli((suite,), arguments=() if arguments == ["--build-only"] else arguments,
               build_only=arguments == ["--build-only"])
