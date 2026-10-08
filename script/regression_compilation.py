"""Keep current Swift intermediates; publish the regression program only on success."""
import json
import hashlib
import os
from pathlib import Path
import shutil


def write_changed(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file() or path.read_bytes() != content:
        path.write_bytes(content)


def artifact_hashes(workspace):
    suffixes = (".o", ".swiftdeps", ".d", ".swiftmodule", ".swiftdoc", ".swiftsourceinfo", ".priors")
    return {path.relative_to(workspace).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(workspace.rglob("*")) if path.is_file() and path.suffix in suffixes}


def compile_program(compiler, inputs, build_cache, staging, configuration_key, run_process):
    workspace = build_cache / "incremental"
    state = workspace / "compiler.json"
    expected = {"configuration": configuration_key, "sources": sorted(inputs)}
    if workspace.is_symlink():
        raise ValueError("Incremental regression workspace must not be a symlink")
    try:
        if any(path.is_symlink() for path in workspace.rglob("*")):
            raise ValueError("Untrusted link in incremental workspace")
        stored = json.loads(state.read_text())
        reusable = (all(stored[key] == value for key, value in expected.items())
                    and stored["artifacts"] == artifact_hashes(workspace))
    except (OSError, ValueError, KeyError, TypeError):
        reusable = False
    if not reusable and workspace.exists():
        shutil.rmtree(workspace)
    workspace.mkdir(parents=True, exist_ok=True)
    output_map = {"": {"swift-dependencies": str(workspace / "master.swiftdeps")}}
    sources, objects = [], []
    for relative, content in sorted(inputs.items()):
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise ValueError("Regression inputs must stay inside the snapshot")
        source = workspace / "sources" / relative
        obj = workspace / "objects" / (relative + ".o")
        write_changed(source, content)
        obj.parent.mkdir(parents=True, exist_ok=True)
        sources.append(str(source))
        objects.append(str(obj))
        output_map[str(source)] = {"object": str(obj),
                                  "swift-dependencies": str(obj.with_suffix(".swiftdeps")),
                                  "dependencies": str(obj.with_suffix(".d"))}
    mapping = workspace / "outputs.json"
    write_changed(mapping, json.dumps(output_map, sort_keys=True).encode())
    env = dict(os.environ, TMPDIR=str(staging) + "/")
    binary = staging / "regression"
    try:
        output = run_process([*compiler.command, *compiler.flags,
                              "-emit-module-path", str(workspace / "HermesAppRegression.swiftmodule"),
                              "-output-file-map", str(mapping), "-c", *sources],
                             env=env, timeout=600, capture=True)
        output += run_process([*compiler.command, *compiler.link_flags, *objects, "-o", str(binary)],
                              env=env, timeout=180, capture=True)
        # A failed or interrupted build discards intermediate state, not the last good program.
        write_changed(state, json.dumps(dict(expected, artifacts=artifact_hashes(workspace)), sort_keys=True).encode())
    except BaseException:
        state.unlink(missing_ok=True)
        shutil.rmtree(workspace, ignore_errors=True)
        raise
    return binary, output
