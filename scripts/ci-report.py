#!/usr/bin/env python3
"""ci-report.py - the end-of-run report of the faseela workflows.

Two sub-commands, both print GitHub-flavoured markdown on stdout (the
workflows append it to $GITHUB_STEP_SUMMARY and keep it as an artifact):

  excerpt LOG [--title T]     why a build log failed: the stage that died, the
                              error lines just before it and the last log lines.
                              Meant for a job's "if: always()" step; prints a
                              one-line "no failure" note when the log is clean.

  report [options]            the run as a whole: verdict, jobs with duration,
                              failed steps, artifacts, facts (recipes commit,
                              seed, ...) and the excerpts the jobs left behind.
                              Reads the run through `gh api` (needs GH_TOKEN and
                              `actions: read`), or from files for the tests:
                              --jobs-json F  --artifacts-json F  --run-json F

Standard library only.
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys

ICON = {
    "success": "✅", "failure": "❌", "cancelled": "🚫", "skipped": "⏭️",
    "timed_out": "⏱️", "in_progress": "⏳", "queued": "⏳", "neutral": "➖",
    None: "⏳",
}
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
STAMP = re.compile(r"^\ufeff?\d{4}-\d\d-\d\dT[\d:.]+Z ")
# Real failures only: case-sensitive markers, no "warning", no "-Werror".
ERRLINE = re.compile(
    r"(?:^|[\s:\]])(?:ERROR|FATAL|FAILED|SELF-HOST FAILED)\b"
    r"|\berror:|\bfatal error:|\bfatal:|\bundefined reference\b|\bmake(?:\[\d+\])?: \*\*\*"
    r"|\bpanicked at\b|\bTraceback \(most recent call last\)"
)
NOISE = re.compile(r"warning|lint: checked|-Werror|Wno-error|checking |^##\[(?:group|endgroup)\]", re.I)
FAILED_DURING = re.compile(r"FAILED during '([^']+)'")


def clean(line):
    return STAMP.sub("", ANSI.sub("", line.rstrip("\n")))


# --------------------------------------------------------------------- excerpt
def excerpt(path, title, tail_lines=30, max_errors=25, window=400):
    last = collections.deque(maxlen=window)
    stage = None
    try:
        with open(path, errors="replace") as fh:
            for raw in fh:
                line = clean(raw)
                last.append(line)
                m = FAILED_DURING.search(line)
                if m:
                    stage = m.group(1)
    except OSError as e:
        return f"### ⚠️ {title}: no log to read ({e.strerror or e})\n"

    errors = [l for l in last if ERRLINE.search(l) and not NOISE.search(l)]
    if stage is None and not errors:
        return f"### ✅ {title}: no failure found in the log\n"

    head = f"### ❌ {title}: failed" + (f" during `{stage}`" if stage else "")
    out = [head, ""]
    if errors:
        seen, uniq = set(), []
        for l in errors:
            if l not in seen:
                seen.add(l)
                uniq.append(l)
        out += ["Errors reported just before the end of the log:", "", "```"]
        out += [l[:300] for l in uniq[-max_errors:]]
        out += ["```", ""]
    tail = [l[:300] for l in list(last)[-tail_lines:]]
    out += [f"<details><summary>Last {len(tail)} log lines</summary>", "", "```"]
    out += tail
    out += ["```", "", "</details>", ""]
    return "\n".join(out)


# ---------------------------------------------------------------------- report
def parse_time(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def human_duration(seconds):
    if seconds is None:
        return "–"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def human_size(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def gh_api(path):
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh api {path}: {r.stderr.strip() or r.returncode}")
    return json.loads(r.stdout)


def load(path_or_none, api_path):
    if path_or_none:
        with open(path_or_none) as fh:
            return json.load(fh)
    return gh_api(api_path)


def verdict_of(needs, jobs):
    """success | failure | cancelled, from the `needs` results when given."""
    if needs:
        results = [v.get("result") for v in needs.values()]
    else:
        results = [j.get("conclusion") for j in jobs]
    if any(r in ("failure", "timed_out") for r in results):
        return "failure"
    if any(r == "cancelled" for r in results):
        return "cancelled"
    return "success"


def report(args):
    env = os.environ
    repo = env.get("GITHUB_REPOSITORY", "")
    run_id = args.run_id or env.get("GITHUB_RUN_ID", "")
    server = env.get("GITHUB_SERVER_URL", "https://github.com")
    run_url = f"{server}/{repo}/actions/runs/{run_id}" if repo and run_id else ""

    base = f"repos/{repo}/actions/runs/{run_id}"
    problems = []
    try:
        jobs = load(args.jobs_json, f"{base}/jobs?per_page=100").get("jobs", [])
    except (RuntimeError, OSError, ValueError) as e:
        jobs, problems = [], problems + [f"jobs: {e}"]
    try:
        arts = load(args.artifacts_json, f"{base}/artifacts?per_page=100").get("artifacts", [])
    except (RuntimeError, OSError, ValueError) as e:
        arts, problems = [], problems + [f"artifacts: {e}"]
    try:
        run = load(args.run_json, base)
    except (RuntimeError, OSError, ValueError) as e:
        run, problems = {}, problems + [f"run: {e}"]

    needs = None
    if args.needs_json:
        with open(args.needs_json) as fh:
            needs = json.load(fh)

    jobs = [j for j in jobs if j.get("name") != args.exclude]
    verdict = verdict_of(needs, jobs)
    title = {"success": "Build succeeded", "failure": "Build failed",
             "cancelled": "Run cancelled"}[verdict]

    started = parse_time(run.get("run_started_at"))
    now = dt.datetime.now(dt.timezone.utc)
    total = (now - started).total_seconds() if started else None

    out = [f"# {ICON[verdict]} {env.get('GITHUB_WORKFLOW', 'Run')}: {title}", ""]
    meta = [
        ("Trigger", env.get("GITHUB_EVENT_NAME", "")),
        ("Ref", env.get("GITHUB_REF_NAME", "")),
        ("Commit", env.get("GITHUB_SHA", "")[:10]),
        ("Actor", env.get("GITHUB_ACTOR", "")),
        ("Total time", human_duration(total) if total is not None else ""),
    ] + [tuple(f.split("=", 1)) for f in args.fact if "=" in f]
    meta = [(k, v) for k, v in meta if v]
    if meta:
        out += ["| | |", "|---|---|"] + [f"| **{k}** | {v} |" for k, v in meta] + [""]
    if run_url:
        out += [f"[Open the run]({run_url})", ""]

    # ----- jobs
    out += ["## Jobs", "", "| | job | result | time |", "|---|---|---|---|"]
    failed_jobs = []
    for j in sorted(jobs, key=lambda j: (j.get("started_at") or "9", j.get("name", ""))):
        concl = j.get("conclusion") or j.get("status")
        t0, t1 = parse_time(j.get("started_at")), parse_time(j.get("completed_at"))
        dur = (t1 - t0).total_seconds() if t0 and t1 else None
        name = j.get("name", "?")
        link = f"[{name}]({j['html_url']})" if j.get("html_url") else name
        out.append(f"| {ICON.get(concl, '❔')} | {link} | {concl} | {human_duration(dur)} |")
        if concl in ("failure", "timed_out"):
            failed_jobs.append(j)
    if not jobs:
        out.append("| ❔ | _no job data_ | | |")
    out.append("")

    # ----- failed steps
    if failed_jobs:
        out += ["## Where it failed", ""]
        for j in failed_jobs:
            bad = [s for s in j.get("steps", []) if s.get("conclusion") in ("failure", "timed_out")]
            for s in bad or [{"name": "(job-level failure)", "number": 1}]:
                url = f"{j.get('html_url', '')}#step:{s.get('number', 1)}:1"
                out.append(f"- **{j.get('name')}** → step *{s.get('name')}* ([log]({url}))")
        out.append("")

    # ----- excerpts left by the jobs (report-*/ *.md)
    files = sorted(glob.glob(os.path.join(args.extra, "**", "*.md"), recursive=True)) if args.extra else []
    shown = []
    for f in files:
        with open(f, errors="replace") as fh:
            body = fh.read().strip()
        # only a run that did not succeed has anything worth repeating
        if body and verdict != "success":
            shown.append(body)
    if shown:
        out += ["## Failure details", ""] + ["\n\n".join(shown), ""]

    # ----- artifacts
    live = [a for a in arts if not a.get("expired")]
    if live:
        out += ["## Artifacts", "", "| artifact | size |", "|---|---|"]
        for a in sorted(live, key=lambda a: a["name"]):
            out.append(f"| `{a['name']}` | {human_size(a.get('size_in_bytes', 0))} |")
        out.append("")
    elif verdict == "success":
        out += ["## Artifacts", "", "_none were uploaded_", ""]

    if problems:
        out += ["> ⚠️ the report is incomplete: " + "; ".join(problems), ""]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("excerpt")
    e.add_argument("log")
    e.add_argument("--title", default="Build")
    r = sub.add_parser("report")
    r.add_argument("--run-id")
    r.add_argument("--needs-json", help="toJSON(needs) of the workflow, for the verdict")
    r.add_argument("--extra", help="directory with excerpt *.md files from the jobs")
    r.add_argument("--exclude", default="run report", help="job name to leave out (this one)")
    r.add_argument("--fact", action="append", default=[], metavar="KEY=VALUE")
    r.add_argument("--jobs-json")
    r.add_argument("--artifacts-json")
    r.add_argument("--run-json")
    args = ap.parse_args()
    if args.cmd == "excerpt":
        sys.stdout.write(excerpt(args.log, args.title))
    else:
        sys.stdout.write(report(args) + "\n")


if __name__ == "__main__":
    main()
