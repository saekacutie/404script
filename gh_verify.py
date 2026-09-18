#!/usr/bin/env python3
"""
gh_verify.py — Accurate multi-format syntax verifier for deployment repos.

Walks a directory (a cloned GitHub repo, or any folder), finds every file it
knows how to check, and validates syntax file-by-file, line-by-line where the
underlying tool supports it. Built to catch the stuff that breaks CI/CD and
deployment *before* you push:

  - GitHub Actions workflows (.github/workflows/*.yml)      -> YAML + Actions schema checks
  - Generic YAML / YML                                       -> YAML parse
  - JSON                                                      -> JSON parse
  - Python (.py)                                              -> py_compile (AST + syntax)
  - Shell scripts (.sh, .bash)                                -> bash -n (syntax-only, no execution)
  - JavaScript (.js, .mjs, .cjs)                               -> node --check
  - Dockerfile / Dockerfile.*                                  -> internal Dockerfile linter
  - HAProxy config (haproxy.cfg, *.cfg under haproxy/, etc.)   -> haproxy -c -f if available,
                                                                   else structural linter
  - nginx / OpenResty config (nginx.conf, conf.d/*.conf, etc.) -> nginx -t if available,
                                                                   else structural linter
  - Envoy config (envoy.yaml, *envoy*.yml)                     -> envoy --mode validate if available,
                                                                   else YAML + schema-aware structural checks
  - .env files                                                 -> KEY=VALUE syntax check
  - TOML (.toml)                                               -> tomllib parse (py3.11+)

Exit code: 0 if everything is clean, 1 if any file has errors.

Usage:
    python3 gh_verify.py [path]              # defaults to current directory
    python3 gh_verify.py [path] --json        # machine-readable output
    python3 gh_verify.py [path] --only yaml,python
    python3 gh_verify.py [path] --exclude node_modules,vendor
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import py_compile
import tempfile
from dataclasses import dataclass, field, asdict
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

try:
    import tomllib
except ImportError:
    tomllib = None


DEFAULT_EXCLUDES = {
    ".git", "node_modules", "vendor", "__pycache__", ".venv", "venv",
    "dist", "build", ".next", ".cache",
}

GITHUB_ACTIONS_TOP_KEYS = {"name", "run-name", "on", "permissions", "env", "defaults",
                            "concurrency", "jobs", "secrets", "outputs"}
GITHUB_ACTIONS_JOB_KEYS = {
    "name", "needs", "if", "runs-on", "permissions", "environment", "concurrency",
    "outputs", "env", "defaults", "steps", "timeout-minutes", "strategy",
    "continue-on-error", "container", "services", "uses", "with", "secrets",
}
GITHUB_ACTIONS_STEP_KEYS = {
    "id", "if", "name", "uses", "run", "working-directory", "shell", "with",
    "env", "continue-on-error", "timeout-minutes",
}


@dataclass
class Issue:
    line: int          # 1-indexed, 0 = whole-file issue
    col: int            # 1-indexed, 0 = unknown
    severity: str        # "error" | "warning"
    message: str


@dataclass
class FileResult:
    path: str
    checker: str
    ok: bool
    issues: list = field(default_factory=list)

    def add(self, line, col, severity, message):
        self.issues.append(Issue(line, col, severity, message))
        if severity == "error":
            self.ok = False


# --------------------------------------------------------------------------
# Individual checkers. Each takes (path: Path, text: str) -> FileResult
# --------------------------------------------------------------------------

def check_yaml(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "yaml", True)
    if yaml is None:
        res.add(0, 0, "error", "PyYAML not installed — cannot validate YAML")
        return res
    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        line = (mark.line + 1) if mark else 0
        col = (mark.column + 1) if mark else 0
        problem = getattr(e, "problem", str(e))
        context = getattr(e, "context", None)
        msg = problem or str(e)
        if context:
            msg = f"{context}; {msg}"
        res.add(line, col, "error", f"YAML syntax error: {msg}")
        return res

    is_workflow = ".github/workflows" in str(path).replace("\\", "/")
    if is_workflow and docs:
        _check_github_workflow_semantics(docs[0], text, res)
    return res


def _line_of_key(text: str, key: str, start_line: int = 0) -> int:
    """Best-effort: find the 1-indexed line where a top-level-ish key appears."""
    lines = text.splitlines()
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*:")
    for i, line in enumerate(lines):
        if i < start_line:
            continue
        if pattern.match(line):
            return i + 1
    return 0


def _check_github_workflow_semantics(doc, text: str, res: FileResult):
    """Structural checks that mirror what GitHub Actions itself enforces,
    so errors surface locally instead of after a push."""
    if not isinstance(doc, dict):
        res.add(0, 0, "error", "Workflow file root must be a mapping (key: value), not a list/scalar")
        return

    # normalize 'on' vs True (YAML 1.1 quirk: unquoted `on:` can parse as bool True)
    keys = set(doc.keys())
    if True in keys and "on" not in keys:
        # Note: GitHub's own workflow parser special-cases the bare `on:` key and
        # handles it correctly — this is NOT actually broken on github.com. It's
        # flagged as a warning only because strict YAML tooling (PyYAML included)
        # parses it as boolean `true` under YAML 1.1, which can bite you in any
        # *other* YAML-based tool that touches this file (linters, custom parsers,
        # yq, etc). Quoting "on": is harmless and removes the ambiguity either way.
        res.add(_line_of_key(text, "on") or 1, 0, "warning",
                "'on:' parses as boolean `true` under strict YAML (YAML 1.1). GitHub Actions "
                "itself handles this fine, but other YAML tooling may not. Quoting \"on\": "
                "removes the ambiguity.")
    elif "on" not in keys:
        res.add(0, 0, "error", "Missing required top-level key: 'on' (workflow triggers)")

    if "jobs" not in keys:
        res.add(0, 0, "error", "Missing required top-level key: 'jobs'")
        return

    unknown_top = keys - GITHUB_ACTIONS_TOP_KEYS - {True}
    for k in unknown_top:
        res.add(_line_of_key(text, str(k)), 0, "warning",
                f"Unrecognized top-level key '{k}' — not a documented GitHub Actions workflow key")

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        res.add(_line_of_key(text, "jobs"), 0, "error", "'jobs:' must be a non-empty mapping of job_id -> job")
        return

    job_ids = set(jobs.keys())
    for job_id, job in jobs.items():
        jline = _line_of_key(text, str(job_id))
        if not isinstance(job, dict):
            res.add(jline, 0, "error", f"Job '{job_id}' must be a mapping")
            continue

        has_uses = "uses" in job
        has_runs_on = "runs-on" in job
        if not has_uses and not has_runs_on:
            res.add(jline, 0, "error",
                    f"Job '{job_id}' is missing 'runs-on' (required unless the job calls a reusable "
                    f"workflow via 'uses')")

        unknown = set(job.keys()) - GITHUB_ACTIONS_JOB_KEYS
        for k in unknown:
            res.add(_line_of_key(text, str(k), jline), 0, "warning",
                    f"Job '{job_id}': unrecognized key '{k}'")

        needs = job.get("needs")
        if needs is not None:
            need_list = [needs] if isinstance(needs, str) else needs
            if isinstance(need_list, list):
                for n in need_list:
                    if n not in job_ids:
                        res.add(jline, 0, "error",
                                f"Job '{job_id}' needs '{n}', but no job with that id exists in this file")

        steps = job.get("steps")
        if not has_uses:
            if steps is None:
                res.add(jline, 0, "error", f"Job '{job_id}' has no 'steps' and does not call a reusable workflow")
            elif not isinstance(steps, list):
                res.add(jline, 0, "error", f"Job '{job_id}': 'steps' must be a list")
            else:
                for idx, step in enumerate(steps):
                    if not isinstance(step, dict):
                        res.add(jline, 0, "error", f"Job '{job_id}' step #{idx+1} must be a mapping")
                        continue
                    if "uses" not in step and "run" not in step:
                        res.add(jline, 0, "error",
                                f"Job '{job_id}' step #{idx+1} has neither 'uses' nor 'run' — "
                                f"a step must do one or the other")
                    if "uses" in step and "run" in step:
                        res.add(jline, 0, "error",
                                f"Job '{job_id}' step #{idx+1} has BOTH 'uses' and 'run' — only one is allowed")
                    uses = step.get("uses")
                    if isinstance(uses, str):
                        if uses.startswith("./"):
                            pass  # local action, can't validate ref
                        elif "@" not in uses:
                            res.add(jline, 0, "warning",
                                    f"Job '{job_id}' step #{idx+1}: action '{uses}' has no pinned "
                                    f"@version/@sha — unpinned actions can break or be a supply-chain risk")
                        elif re.match(r".+@[0-9a-f]{40}$", uses):
                            pass  # pinned to full SHA, best practice
                    unknown_step = set(step.keys()) - GITHUB_ACTIONS_STEP_KEYS
                    for k in unknown_step:
                        res.add(jline, 0, "warning",
                                f"Job '{job_id}' step #{idx+1}: unrecognized key '{k}'")

    # ${{ }} expression brace balance check across whole file
    for i, line in enumerate(text.splitlines(), start=1):
        opens = line.count("${{")
        closes = line.count("}}")
        if opens != closes:
            res.add(i, 0, "error",
                    f"Unbalanced GitHub expression syntax on this line ({opens} '${{{{' vs {closes} '}}}}')")


def check_json(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "json", True)
    try:
        json.loads(text)
    except json.JSONDecodeError as e:
        res.add(e.lineno, e.colno, "error", f"JSON syntax error: {e.msg}")
    return res


def check_python(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "python", True)
    with tempfile.NamedTemporaryFile(suffix=".py", delete=False, mode="w") as tmp:
        tmp.write(text)
        tmp_path = tmp.name
    try:
        py_compile.compile(tmp_path, doraise=True)
    except py_compile.PyCompileError as e:
        exc = e.exc_value
        line = getattr(exc, "lineno", 0) or 0
        col = getattr(exc, "offset", 0) or 0
        msg = getattr(exc, "msg", str(exc))
        res.add(line, col, "error", f"Python syntax error: {msg}")
    finally:
        os.unlink(tmp_path)
    return res


def check_bash(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "shell", True)
    bash = shutil.which("bash")
    if not bash:
        res.add(0, 0, "error", "bash not found on PATH — cannot syntax-check shell scripts")
        return res
    proc = subprocess.run([bash, "-n"], input=text, capture_output=True, text=True)
    if proc.returncode != 0:
        for line in proc.stderr.strip().splitlines():
            m = re.search(r"line (\d+):\s*(.*)", line)
            if m:
                res.add(int(m.group(1)), 0, "error", f"Shell syntax error: {m.group(2)}")
            else:
                res.add(0, 0, "error", f"Shell syntax error: {line.strip()}")
    if text and not text.startswith("#!"):
        res.add(1, 1, "warning", "No shebang line — script may not run as expected when executed directly")
    return res


def check_node(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "javascript", True)
    node = shutil.which("node")
    if not node:
        res.add(0, 0, "error", "node not found on PATH — cannot syntax-check JS")
        return res
    with tempfile.NamedTemporaryFile(suffix=".js", delete=False, mode="w") as tmp:
        tmp.write(text)
        tmp_path = tmp.name
    try:
        proc = subprocess.run([node, "--check", tmp_path], capture_output=True, text=True)
        if proc.returncode != 0:
            err = proc.stderr.strip()
            m = re.search(rf"{re.escape(tmp_path)}:(\d+)", err)
            line = int(m.group(1)) if m else 0
            first_msg = err.splitlines()[-1] if err else "syntax error"
            # node prints a caret-pointed snippet; grab the SyntaxError line
            se_line = next((l for l in err.splitlines() if "Error" in l), first_msg)
            res.add(line, 0, "error", f"JavaScript syntax error: {se_line.strip()}")
    finally:
        os.unlink(tmp_path)
    return res


def check_toml(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "toml", True)
    if tomllib is None:
        res.add(0, 0, "error", "tomllib unavailable (needs Python 3.11+) — cannot validate TOML")
        return res
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        m = re.search(r"line (\d+), column (\d+)", str(e))
        line = int(m.group(1)) if m else 0
        col = int(m.group(2)) if m else 0
        res.add(line, col, "error", f"TOML syntax error: {e}")
    return res


def check_dockerfile(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "dockerfile", True)
    lines = text.splitlines()
    valid_instructions = {
        "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD",
        "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD",
        "STOPSIGNAL", "HEALTHCHECK", "SHELL",
    }
    seen_from = False
    open_continuation = False
    for i, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            open_continuation = False
            continue
        if open_continuation:
            open_continuation = stripped.endswith("\\")
            continue
        m = re.match(r"^([A-Za-z]+)(\s|$)", stripped)
        if not m:
            res.add(i, 1, "error", "Line does not start with a recognizable Dockerfile instruction")
            continue
        instr = m.group(1).upper()
        if instr not in valid_instructions:
            res.add(i, 1, "error", f"Unknown Dockerfile instruction '{m.group(1)}'")
            continue
        if instr == "FROM":
            seen_from = True
        elif not seen_from and instr not in ("ARG",):
            res.add(i, 1, "error",
                    f"'{instr}' appears before any 'FROM' — first instruction (besides ARG) must be FROM")
        if instr in ("RUN", "CMD", "ENTRYPOINT") and stripped.count('"') % 2 != 0:
            res.add(i, 1, "error", f"Unbalanced quotes in {instr} instruction")
        open_continuation = stripped.endswith("\\")
    if not seen_from:
        res.add(0, 0, "error", "No 'FROM' instruction found — every Dockerfile needs at least one")
    return res


def check_dotenv(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "dotenv", True)
    for i, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            res.add(i, 1, "error", "Line is not blank/comment and has no '=' — invalid KEY=VALUE syntax")
            continue
        key = stripped.split("=", 1)[0]
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key.strip()):
            res.add(i, 1, "error", f"Invalid environment variable name '{key.strip()}'")
    return res


def check_haproxy(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "haproxy", True)
    haproxy_bin = shutil.which("haproxy")
    if haproxy_bin:
        with tempfile.NamedTemporaryFile(suffix=".cfg", delete=False, mode="w") as tmp:
            tmp.write(text)
            tmp_path = tmp.name
        try:
            proc = subprocess.run([haproxy_bin, "-c", "-f", tmp_path], capture_output=True, text=True)
            if proc.returncode != 0:
                for line in (proc.stdout + proc.stderr).splitlines():
                    m = re.search(r":(\d+)]", line) or re.search(r"line (\d+)", line)
                    ln = int(m.group(1)) if m else 0
                    res.add(ln, 0, "error", line.strip())
        finally:
            os.unlink(tmp_path)
        return res

    # Fallback structural linter (haproxy binary not present in this env)
    lines = text.splitlines()
    section_re = re.compile(r"^\s*(global|defaults|frontend|backend|listen)\b")
    known_top = {"global", "defaults", "frontend", "backend", "listen"}
    current_section = None
    backend_names = set()
    referenced_backends = {}
    for i, raw in enumerate(lines, start=1):
        line = raw.split("#", 1)[0].rstrip()
        stripped = line.strip()
        if not stripped:
            continue
        m = section_re.match(line)
        if m:
            current_section = m.group(1)
            parts = stripped.split()
            if current_section == "backend" and len(parts) >= 2:
                backend_names.add(parts[1])
            continue
        if current_section is None:
            res.add(i, 1, "error", "Directive appears before any section header "
                                     "(global/defaults/frontend/backend/listen)")
            continue
        m2 = re.match(r"use_backend\s+(\S+)", stripped)
        if m2:
            referenced_backends[m2.group(1)] = i
        if stripped.startswith("server ") and current_section not in ("backend", "listen"):
            res.add(i, 1, "error", f"'server' directive used inside a '{current_section}' section "
                                     f"(only valid in backend/listen)")
        # unbalanced braces from ACL conditions using { }
        if line.count("{") != line.count("}"):
            res.add(i, 1, "error", "Unbalanced '{' '}' in ACL condition")
    for name, ln in referenced_backends.items():
        if name not in backend_names:
            res.add(ln, 0, "error", f"use_backend references '{name}', which has no matching 'backend {name}' section")
    if not any(True for _ in section_re.finditer(text)):
        res.add(0, 0, "error", "No recognized HAProxy sections found (global/defaults/frontend/backend/listen)")
    res.add(0, 0, "warning", "haproxy binary not found — used a structural fallback linter, "
                             "not a full HAProxy config parse. Install haproxy for a definitive check.")
    return res


NGINX_BLOCK_DIRECTIVES = {
    "http", "server", "location", "events", "stream", "upstream", "if",
    "map", "types", "geo", "limit_except", "server_names_hash_bucket_size",
}


def check_nginx(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "nginx", True)

    nginx_bin = shutil.which("nginx")
    looks_like_main_conf = bool(re.search(r"^\s*events\s*\{", text, re.MULTILINE)) and \
        bool(re.search(r"^\s*http\s*\{", text, re.MULTILINE))

    if nginx_bin and looks_like_main_conf:
        # Run against the REAL file path (not an isolated temp copy) so relative
        # `include` directives (mime.types, conf.d/*.conf, etc.) resolve against
        # the file's actual sibling files in the repo, same as they would for
        # the real deployed config.
        proc = subprocess.run([nginx_bin, "-t", "-c", str(path)], capture_output=True, text=True)
        if proc.returncode != 0:
            saw_real_error = False
            for line in (proc.stdout + proc.stderr).splitlines():
                if not line.strip():
                    continue
                m = re.search(r":(\d+)\]", line) or re.search(r"line (\d+)", line)
                ln = int(m.group(1)) if m else 0
                missing_file_m = re.search(r'open\(\) "([^"]+)" failed \(2: No such file or directory\)', line)
                if missing_file_m:
                    # This is very commonly a file the base image/package provides at
                    # build/runtime (e.g. mime.types shipped by nginx/openresty) rather
                    # than something checked into the repo — a static scan can't see
                    # those, so treat it as informational rather than a hard failure.
                    res.add(ln, 0, "warning",
                            f"nginx -t couldn't find '{missing_file_m.group(1)}'. If this file is "
                            f"provided by your base image (e.g. a package-shipped mime.types) rather "
                            f"than committed to this repo, this is expected and NOT a real error. If "
                            f"it should exist in the repo, that's the actual bug.")
                elif re.search(r"configuration file .* test (failed|is successful)$", line) or \
                        re.search(r"the configuration file .* syntax is ok$", line):
                    # Generic nginx summary/trailer lines — redundant once we've already
                    # reported (or not) the specific diagnostic(s) above; skip to avoid a
                    # duplicate, less-informative "error" with no new information.
                    continue
                elif "[emerg]" in line or "[alert]" in line or "[crit]" in line or "nginx:" in line:
                    saw_real_error = True
                    res.add(ln, 0, "error", line.strip())
            if not saw_real_error and not any(i.severity == "error" for i in res.issues):
                pass  # only missing-file warnings — leave as a warning-only result, not a failure
        return res

    # Structural fallback — used for included snippets (conf.d/*.conf, site
    # fragments) since `nginx -t` needs a full valid top-level config (events{}
    # + http{}) to run at all, and for environments without the nginx binary.
    depth = 0
    line_no_opened_at = []
    in_block_comment = False  # nginx has no block comments, but keep symmetry
    for i, raw in enumerate(text.splitlines(), start=1):
        line = raw
        # strip inline comments (naive: '#' not inside quotes)
        if "#" in line:
            # don't strip '#' inside quoted strings
            in_q = None
            cut = len(line)
            for idx, ch in enumerate(line):
                if ch in ("'", '"'):
                    if in_q is None:
                        in_q = ch
                    elif in_q == ch:
                        in_q = None
                elif ch == "#" and in_q is None:
                    cut = idx
                    break
            line = line[:cut]
        stripped = line.strip()
        if not stripped:
            continue

        opens = stripped.count("{")
        closes = stripped.count("}")
        depth += opens
        for _ in range(opens):
            line_no_opened_at.append(i)
        for _ in range(closes):
            if line_no_opened_at:
                line_no_opened_at.pop()
        depth -= closes
        if depth < 0:
            res.add(i, 1, "error", "Unmatched closing '}' — no corresponding open brace")
            depth = 0
            continue

        ends_with_block = stripped.endswith("{")
        ends_with_close = stripped == "}" or stripped.endswith("}")
        if ends_with_block:
            continue
        if ends_with_close:
            continue
        if not stripped.endswith(";"):
            res.add(i, len(raw), "error",
                    "Directive is not terminated with ';' (and does not open/close a block)")

    if depth != 0:
        unclosed_line = line_no_opened_at[0] if line_no_opened_at else 0
        res.add(unclosed_line, 0, "error", f"{depth} unclosed '{{' block(s) — missing matching '}}'")

    if not looks_like_main_conf:
        res.add(0, 0, "warning",
                "This doesn't look like a complete nginx main config (no top-level 'events {}' + "
                "'http {}'), so only brace/semicolon structure was checked, not a full 'nginx -t' — "
                "normal for included conf.d/*.conf snippets.")
    elif not nginx_bin:
        res.add(0, 0, "warning", "nginx binary not found — used a structural fallback linter, "
                                 "not a full 'nginx -t'. Install nginx for a definitive check.")

    return res


ENVOY_TOP_KEYS = {
    "admin", "static_resources", "dynamic_resources", "node", "cluster_manager",
    "hds_config", "flags_path", "stats_sinks", "stats_config", "watchdogs",
    "tracing", "layered_runtime", "bootstrap_extensions", "fatal_actions",
    "config_sources", "default_config_source", "default_socket_interface",
    "application_log_config", "overload_manager", "header_prefix", "stats_flush_on_admin",
}


def check_envoy(path: Path, text: str) -> FileResult:
    res = FileResult(str(path), "envoy", True)
    if yaml is None:
        res.add(0, 0, "error", "PyYAML not installed — cannot validate Envoy config")
        return res

    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        line = (mark.line + 1) if mark else 0
        col = (mark.column + 1) if mark else 0
        problem = getattr(e, "problem", str(e))
        res.add(line, col, "error", f"YAML syntax error: {problem}")
        return res

    envoy_bin = shutil.which("envoy")
    if envoy_bin:
        with tempfile.NamedTemporaryFile(suffix=".yaml", delete=False, mode="w") as tmp:
            tmp.write(text)
            tmp_path = tmp.name
        try:
            proc = subprocess.run(
                [envoy_bin, "--mode", "validate", "-c", tmp_path, "--log-level", "critical"],
                capture_output=True, text=True, timeout=30,
            )
            if proc.returncode != 0:
                out = (proc.stdout + proc.stderr).strip()
                for line in out.splitlines():
                    if line.strip():
                        res.add(0, 0, "error", line.strip())
                if not out:
                    res.add(0, 0, "error", "envoy --mode validate failed (no diagnostic output captured)")
            return res
        except subprocess.TimeoutExpired:
            res.add(0, 0, "warning", "envoy --mode validate timed out — falling back to structural checks")
        finally:
            os.unlink(tmp_path)

    # Structural / schema-aware fallback
    if not isinstance(doc, dict):
        res.add(0, 0, "error", "Envoy config root must be a mapping")
        return res

    keys = set(doc.keys())
    if not (keys & {"static_resources", "dynamic_resources", "admin", "node"}):
        res.add(0, 0, "warning",
                "Doesn't look like an Envoy bootstrap config — none of 'static_resources', "
                "'dynamic_resources', 'admin', or 'node' are present at the top level")

    unknown_top = keys - ENVOY_TOP_KEYS
    for k in unknown_top:
        res.add(_line_of_key(text, str(k)), 0, "warning",
                f"Unrecognized top-level key '{k}' for an Envoy bootstrap config")

    static = doc.get("static_resources")
    if isinstance(static, dict):
        listeners = static.get("listeners")
        if listeners is not None:
            if not isinstance(listeners, list):
                res.add(_line_of_key(text, "listeners"), 0, "error", "'listeners' must be a list")
            else:
                for idx, lst in enumerate(listeners):
                    if not isinstance(lst, dict):
                        res.add(0, 0, "error", f"listeners[{idx}] must be a mapping")
                        continue
                    if "name" not in lst:
                        res.add(0, 0, "warning", f"listeners[{idx}] has no 'name' — harder to identify in logs/stats")
                    if "address" not in lst:
                        res.add(0, 0, "error", f"listeners[{idx}] is missing required field 'address'")
                    if "filter_chains" not in lst and "filter_chain" not in lst:
                        res.add(0, 0, "error",
                                f"listeners[{idx}] is missing 'filter_chains' — a listener with no "
                                f"filter chain will accept connections and do nothing with them")

        clusters = static.get("clusters")
        if clusters is not None:
            if not isinstance(clusters, list):
                res.add(_line_of_key(text, "clusters"), 0, "error", "'clusters' must be a list")
            else:
                cluster_names = set()
                for idx, cl in enumerate(clusters):
                    if not isinstance(cl, dict):
                        res.add(0, 0, "error", f"clusters[{idx}] must be a mapping")
                        continue
                    if "name" not in cl:
                        res.add(0, 0, "error", f"clusters[{idx}] is missing required field 'name'")
                    else:
                        cluster_names.add(cl["name"])
                    if "type" not in cl and "cluster_type" not in cl:
                        res.add(0, 0, "warning",
                                f"clusters[{idx}] has no 'type' (e.g. STATIC/STRICT_DNS/LOGICAL_DNS/EDS) — "
                                f"Envoy will reject this at startup")
                    has_load_assignment = "load_assignment" in cl
                    has_legacy_hosts = "hosts" in cl
                    if not has_load_assignment and not has_legacy_hosts and cl.get("type") != "EDS":
                        res.add(0, 0, "warning",
                                f"clusters[{idx}] has no 'load_assignment' (or legacy 'hosts') — "
                                f"no upstream endpoints are defined for this cluster")

                # cross-check listener filter_chains referencing clusters, best-effort
                listeners = static.get("listeners") or []
                referenced = set()
                for lst in listeners if isinstance(listeners, list) else []:
                    referenced |= set(re.findall(r"cluster:\s*([A-Za-z0-9_.\-]+)", yaml.safe_dump(lst)))
                for name in referenced:
                    if name not in cluster_names:
                        res.add(0, 0, "error",
                                f"A filter chain references cluster '{name}', which has no matching "
                                f"entry in 'clusters'")

    admin = doc.get("admin")
    if isinstance(admin, dict) and "address" not in admin:
        res.add(_line_of_key(text, "admin"), 0, "warning", "'admin' block is present but has no 'address'")

    if not envoy_bin:
        res.add(0, 0, "warning", "envoy binary not found — used a structural/schema fallback linter, "
                                 "not a full 'envoy --mode validate'. Install envoy for a definitive check.")

    return res


# --------------------------------------------------------------------------
# File dispatch
# --------------------------------------------------------------------------

def classify(path: Path):
    name = path.name
    suffix = path.suffix.lower()
    posix = str(path).replace("\\", "/")

    if name.startswith("Dockerfile"):
        return "dockerfile"
    if name == ".env" or name.startswith(".env."):
        return "dotenv"
    if "haproxy" in posix.lower() and suffix in (".cfg", ".conf", ""):
        return "haproxy"
    if "envoy" in posix.lower() and suffix in (".yml", ".yaml"):
        return "envoy"
    if name in ("nginx.conf", "openresty.conf") or (
        suffix == ".conf" and re.search(r"/(nginx|openresty|conf\.d|sites-(available|enabled))/", posix.lower())
    ):
        return "nginx"
    if suffix in (".yml", ".yaml"):
        return "yaml"
    if suffix == ".json":
        return "json"
    if suffix == ".py":
        return "python"
    if suffix in (".sh", ".bash"):
        return "shell"
    if suffix in (".js", ".mjs", ".cjs"):
        return "javascript"
    if suffix == ".toml":
        return "toml"
    return None


CHECKERS = {
    "yaml": check_yaml,
    "json": check_json,
    "python": check_python,
    "shell": check_bash,
    "javascript": check_node,
    "toml": check_toml,
    "dockerfile": check_dockerfile,
    "dotenv": check_dotenv,
    "haproxy": check_haproxy,
    "nginx": check_nginx,
    "envoy": check_envoy,
}


def iter_files(root: Path, excludes: set):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in excludes and not d.startswith(".") or d == ".github"]
        for fn in filenames:
            yield Path(dirpath) / fn


def run(root: Path, only=None, excludes=None):
    excludes = excludes or set(DEFAULT_EXCLUDES)
    results = []
    for f in sorted(iter_files(root, excludes)):
        kind = classify(f)
        if kind is None:
            continue
        if only and kind not in only:
            continue
        try:
            text = f.read_text(encoding="utf-8", errors="strict")
        except UnicodeDecodeError:
            r = FileResult(str(f), kind, True)
            r.add(0, 0, "warning", "File is not valid UTF-8 — skipped content check")
            results.append(r)
            continue
        except OSError as e:
            r = FileResult(str(f), kind, False)
            r.add(0, 0, "error", f"Could not read file: {e}")
            results.append(r)
            continue
        checker = CHECKERS[kind]
        results.append(checker(f, text))
    return results


def print_human(results, root: Path):
    total = len(results)
    bad = [r for r in results if not r.ok]
    warn_only = [r for r in results if r.ok and any(i.severity == "warning" for i in r.issues)]
    clean = total - len(bad) - len(warn_only)

    print(f"\n{'='*70}")
    print(f"  GitHub / Deployment Syntax Verifier")
    print(f"  Root: {root}")
    print(f"{'='*70}\n")

    for r in results:
        if not r.issues:
            continue
        rel = os.path.relpath(r.path, root)
        header_mark = "✗" if not r.ok else "⚠"
        print(f"{header_mark} {rel}  [{r.checker}]")
        for issue in r.issues:
            loc = ""
            if issue.line:
                loc = f"line {issue.line}" + (f", col {issue.col}" if issue.col else "")
            tag = "ERROR" if issue.severity == "error" else "WARN "
            prefix = f"  [{tag}] "
            if loc:
                prefix += f"({loc}) "
            print(f"{prefix}{issue.message}")
        print()

    print(f"{'-'*70}")
    print(f"Files scanned: {total}   Clean: {clean}   Warnings only: {len(warn_only)}   Errors: {len(bad)}")
    print(f"{'-'*70}\n")

    if bad:
        print("Result: FAIL — fix the errors above before deploying.\n")
    else:
        print("Result: PASS — no syntax errors found.\n")


def print_json(results, root: Path):
    out = []
    for r in results:
        d = asdict(r)
        d["path"] = os.path.relpath(r.path, root)
        out.append(d)
    print(json.dumps({"root": str(root), "results": out}, indent=2))


def main():
    ap = argparse.ArgumentParser(description="Line-by-line syntax verifier for deployment repos.")
    ap.add_argument("path", nargs="?", default=".", help="Directory to scan (default: current dir)")
    ap.add_argument("--json", action="store_true", help="Machine-readable JSON output")
    ap.add_argument("--only", help="Comma-separated list of checkers to run "
                                    "(yaml,json,python,shell,javascript,toml,dockerfile,dotenv,"
                                    "haproxy,nginx,envoy)")
    ap.add_argument("--exclude", help="Comma-separated extra directory names to exclude")
    args = ap.parse_args()

    root = Path(args.path).resolve()
    if not root.exists():
        print(f"Path not found: {root}", file=sys.stderr)
        sys.exit(2)

    only = set(args.only.split(",")) if args.only else None
    excludes = set(DEFAULT_EXCLUDES)
    if args.exclude:
        excludes |= set(args.exclude.split(","))

    results = run(root, only=only, excludes=excludes)

    if args.json:
        print_json(results, root)
    else:
        print_human(results, root)

    sys.exit(1 if any(not r.ok for r in results) else 0)


if __name__ == "__main__":
    main()
