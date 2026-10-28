"""Behavior gate for the bash-shortening autoimprove task cases. It prints {"score": 1} or {"score": 0, "failed": [...]}.

The contract inlines this file as the `task` grader argv. The workspace holds one fixture `evals/files/NAME.sh`
and the candidate `output/NAME.sh`. The gate checks two hard rules:
1. `output/NAME.sh` exists and `bash -n` accepts it.
2. For each recorded run in RUNS, the candidate and the original give the same exit status, the same stdout,
   and the same final file tree in the working directory. The gate does not compare stderr.
The task never sees RUNS, so the runs act as a held-out behavior test. Each run starts from a clean tree at the
same absolute path, so `$0`, `$HOME`, and the working directory are equal for both scripts.
On a failure, stderr names the run and the first difference, for the gate diagnostic.
"""

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

TIMEOUT = 5

LOGS = {
    "logs/a.log": "1\n2\n3\n",
    "logs/b c.log": "x\ny\n",
    "logs/sub/d.log": "z\n",
    "logs/empty.log": "",
    "logs/x.txt": "no\n",
}
REPORT = "name,email,status\nann,ann@x.io,active\nbob,bob@x.io,disabled\ndee,dee@x.io,active,admin\n"

RUNS: dict[str, list[dict[str, object]]] = {
    "sorted-diff.sh": [
        {
            "files": {
                "old list.txt": "pear\napple\nfig\n",
                "new.txt": "apple\nkiwi\npear\nplum\n",
            },
            "args": ["old list.txt", "new.txt"],
        },
        {"files": {"a": "x\ny\n", "b": "y\nx\n"}, "args": ["a", "b"]},
        {"files": {"a": "", "b": "one\n"}, "args": ["a", "b"]},
        {"files": {"a": "one\n"}, "args": ["a", "missing"]},
    ],
    "log-summary.sh": [
        {"files": LOGS, "args": ["logs"]},
        {"files": LOGS, "args": []},
        {"files": LOGS, "args": ["nowhere"]},
    ],
    "compare-dirs.sh": [
        {
            "files": {"a/x": "", "a/y": "", "a/with space": "", "b/y": ""},
            "args": ["a", "b"],
        },
        {"files": {"a/x": "", "a/y": "", "b/y": ""}, "args": ["b", "a"]},
        {"files": {"a/x": ""}, "args": ["a", "a"]},
    ],
    "path-parts.sh": [
        {
            "args": [
                "/var/log/app.log",
                "notes.txt",
                "dir/sub/",
                "archive.tar.gz",
                "/",
                "README",
                ".bashrc",
            ]
        },
    ],
    "name-defaults.sh": [
        {"args": []},
        {"args": ["My App", "1.2.3-beta", "beta"]},
        {"args": ["Café Tools", "2.10.0"]},
        {"args": ["x", "", ""]},
    ],
    "branch-slugs.sh": [
        {"stdin": "feature/login_form\nfix/bug-12\n\nmain\nrelease/v1.2/hotfix_3\n"},
        {"stdin": ""},
    ],
    "retry-loop.sh": [
        {"files": {"o": "fail\nfail\nok\n"}, "args": ["o"]},
        {"files": {"o": "fail\nfail\nok\n"}, "args": ["o", "2"]},
        {"files": {"o": "fail\n"}, "args": ["o", "4"]},
        {"files": {"o": "ok\n"}, "args": ["o"]},
    ],
    "grade-scores.sh": [
        {"stdin": "ann 95\nbob 49\ncy 50\ndee 90\neve 08\n"},
        {"stdin": ""},
        {"stdin": "solo 10\n"},
    ],
    "disk-check.sh": [
        {"stdin": "/ 45%\n/var 85%\n/home 91%\n"},
        {"stdin": "/ 45%\n/var 85%\n/home 91%\n", "args": ["40", "95"]},
        {"stdin": "/ 10%\n"},
        {"stdin": "/a 81%\n/b 82%\n"},
    ],
    "deploy-url.sh": [
        {"args": [name]}
        for name in ("dev", "staging", "prod", "production", "Prod", "")
    ],
    "usage-text.sh": [{"args": []}, {"args": ["-h"]}],
    "rotate-spool.sh": [
        {
            "files": {"spool/a.msg": "1", "spool/b c.msg": "2", "spool/keep.txt": "k"},
            "args": ["spool"],
        },
        {
            "files": {"spool/archive/old.msg": "0", "spool/n.msg": "n"},
            "args": ["spool"],
        },
        {"files": {"spool/keep.txt": "k"}, "args": ["spool"]},
        {"args": ["nope"]},
    ],
    "make-skeleton.sh": [
        {},
        {"files": {"tests/case03/input.txt": "keep\n", "src/": ""}},
    ],
    "install-config.sh": [
        {
            "files": {"m.conf": "# managed\nk=v\n", "etc/app.conf": "old\n"},
            "args": ["m.conf", "etc"],
        },
        {"files": {"m.conf": "# managed\n", "etc/": ""}, "args": ["m.conf", "etc"]},
        {"files": {"u.conf": "k=v\n", "etc/": ""}, "args": ["u.conf", "etc"]},
        {"files": {"m.conf": "# managed\n"}, "args": ["m.conf", "nodir"]},
        {"files": {"etc/": ""}, "args": ["absent.conf", "etc"]},
    ],
    "active-users.sh": [
        {"files": {"r.csv": REPORT}, "args": ["r.csv"]},
        {"files": {"h.csv": "name,email,status\n"}, "args": ["h.csv"]},
        {
            "files": {"z.csv": "name,email,status\nbob,bob@x.io,disabled\n"},
            "args": ["z.csv"],
        },
        {"args": ["missing.csv"]},
    ],
    "count-ext.sh": [
        {
            "files": {
                "a.txt": "",
                "b.txt": "",
                "src/main.c": "",
                "src/util.h": "",
                "Makefile": "",
                "docs/x.tar.gz": "",
            }
        },
        {},
    ],
}


def tree(root: pathlib.Path) -> dict[str, str]:
    """Map each path under root to `dir` or the sha256 of its bytes."""
    found: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        key = path.relative_to(root).as_posix()
        found[key] = (
            "dir" if path.is_dir() else hashlib.sha256(path.read_bytes()).hexdigest()
        )
    return found


def execute(
    script: pathlib.Path, run: dict[str, object], base: pathlib.Path
) -> dict[str, object]:
    """Run one script on one recorded run from a clean tree at base."""
    shutil.rmtree(base, ignore_errors=True)
    work, home, bin_dir = base / "work", base / "home", base / "bin"
    for directory in (work, home, bin_dir):
        directory.mkdir(parents=True)
    target = bin_dir / script.name
    shutil.copyfile(script, target)
    for name, text in dict(run.get("files", {})).items():
        path = work / name
        if name.endswith("/"):
            path.mkdir(parents=True, exist_ok=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(text))
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "LC_ALL": "C.UTF-8",
        "LANG": "C.UTF-8",
    }
    args = [str(arg) for arg in list(run.get("args", []))]
    try:
        done = subprocess.run(
            ["bash", str(target), *args],
            check=False,
            cwd=work,
            env=env,
            input=str(run.get("stdin", "")).encode(),
            capture_output=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    return {
        "status": done.returncode,
        "stdout": done.stdout.decode(errors="replace"),
        "tree": tree(work),
    }


def first_difference(want: dict[str, object], got: dict[str, object]) -> str:
    for field in ("status", "stdout", "tree"):
        if want.get(field) != got.get(field):
            return f"{field}: original {json.dumps(want.get(field))[:300]} candidate {json.dumps(got.get(field))[:300]}"
    return ""


def main() -> None:
    failed: list[str] = []
    fixtures = sorted(pathlib.Path("evals/files").glob("*.sh"))
    if not fixtures:
        failed.append("no-fixture")
    for original in fixtures:
        name = original.name
        candidate = pathlib.Path("output") / name
        runs = RUNS.get(name)
        if runs is None:
            failed.append(f"{name}:unknown-fixture")
            continue
        if not candidate.is_file():
            failed.append(f"{name}:missing-output")
            print(f"{name}: output/{name} is missing", file=sys.stderr)
            continue
        syntax = subprocess.run(
            ["bash", "-n", str(candidate)],
            check=False,
            capture_output=True,
            timeout=TIMEOUT,
        )
        if syntax.returncode != 0:
            failed.append(f"{name}:syntax")
            print(
                f"{name}: bash -n fails: {syntax.stderr.decode(errors='replace')[:300]}",
                file=sys.stderr,
            )
            continue
        base = pathlib.Path(tempfile.mkdtemp(prefix="bash-shortening-gate-"))
        try:
            for index, run in enumerate(runs, 1):
                want = execute(original, run, base)
                got = execute(candidate, run, base)
                difference = first_difference(want, got)
                if difference:
                    failed.append(f"{name}:run-{index}")
                    shown = {key: run[key] for key in ("args", "stdin") if key in run}
                    print(
                        f"{name} run {index} {json.dumps(shown)}: {difference}",
                        file=sys.stderr,
                    )
        finally:
            shutil.rmtree(base, ignore_errors=True)
    print(json.dumps({"score": 0 if failed else 1, "failed": failed}))


main()
