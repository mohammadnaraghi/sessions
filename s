#!/usr/bin/env python3
"""sessions (command: s) - Claude Code and Codex session picker.

Lists your recent Claude Code and Codex CLI sessions across every project
folder, and across other machines over ssh, shows what each one was about, and
resumes the one you pick: it cd's into the session's directory and runs
`claude --resume <id>` or `codex resume <id>`, over ssh when the session lives
elsewhere. Any session can also be continued in the other tool. It also shows
which sessions are running right now and what they are doing, and which ones
set up cron jobs.

Usage
  s                      interactive picker (last 14 days, >= 10 min of work;
                         shorter ones for a day after you last used them)
  s 3                    resume the 3rd session in that list, in its own tool
  s 3 --codex            continue it in Codex instead (--claude: in Claude Code).
                         Claude -> Codex imports the full conversation as a Codex
                         thread; Codex -> Claude hands Claude its transcript. If
                         the conversation has a session in that tool already, it
                         resumes that one and tells it what the rest of the
                         conversation did since it last saw it (in any session).
                         A conversation continued that way stays one row (⇄);
                         its number opens wherever you worked on it last.
  s <session id>         open exactly that session, even inside such a chain
  s tiktok               filter by text; resumes directly on a single match
                         ("running", "cron", "claude" and "codex" filter by
                         status or tool, @studio by host)
  s search WORDS         every prompt you ever wrote, in every session on every
                         machine, however old: the conversations with a prompt
                         that has all the words, newest match first, to pick from
  s show 3 | show <id>   details: work per day, prompts, live status, cron jobs
  s transcript 3 | <id>  a session as a document: where it ended, the files it
                         changed, problems it hit, the latest part of the
                         conversation (--all: all of it; --grep WORDS: only the
                         parts about them; --since 2d). Any machine, either tool.
  s handoff [DIR]        a handoff for a new session about everything done in a
                         repository: its state (branches, uncommitted work, PRs),
                         every conversation about it (goal, where it ended, files,
                         problems), the latest one in detail, Claude's memories,
                         and how to read any detail (-d 90 by default).
                         --claude / --codex start that new session with it.
  s cost                 what your sessions would cost at API list prices (not a
                         subscription): bar charts per day, week and month,
                         Claude Code vs Codex, by model, and the top sessions
                         (last 30 days; -d 90 for longer, -a for every session,
                         --top N). Subagents count toward their session.
  s live                 running sessions: what they are doing and how far along
  s jobs                 every in-session cron job and its status
  s path 3               print the session's directory  ->  cd "$(s path 3)"
  s -p                   print the list and exit (all rows when piped)
  s update               replace this script (and ai-bridge beside it) with the
                         latest release

Other machines (over ssh, key auth)
  s hosts                        list configured hosts and check them
  s hosts add studio user@host   add a host (label, then ssh destination)
  s hosts setup studio           copy sessions (and ai-bridge) to that host so it
                                 can answer
  s hosts rm studio              remove a host
  Sessions from every host then appear in the list with a host column.
  Resuming one starts claude there inside a tmux session (when tmux is
  installed there), so closing your laptop only detaches it and picking
  it again attaches. A session already running inside tmux is attached
  to, never duplicated. --tmux does the same for local sessions;
  --no-tmux runs plainly over ssh -t.

Memories and configs between machines
  s sync studio                  two-way sync of Claude's memory folders and
                                 your configs (settings.json, CLAUDE.md,
                                 keybindings, commands, agents, hooks, skills,
                                 MCP servers; Codex's AGENTS.md, hooks, rules
                                 and your settings in its config.toml and
                                 profiles). Newest copy wins per file;
                                 settings and memory indexes are merged;
                                 a file deleted on one side since the last
                                 sync is deleted on the other. Shows the plan
                                 and asks before changing anything; replaced
                                 files are kept under ~/.claude/backups.
  s migrate to studio            copy everything here onto a new machine
  s migrate from studio          the other way round (no deletions either way)
  --memory | --configs           only one of the two groups
  --prefer local|remote          who wins conflicts (default: newest)
  -n                             dry run      -y   apply without asking

Options
  -d, --days N           look back N days (default 14; 30 for s cost)
  -m, --min N            minimum active minutes to be listed (default 10); a
                         shorter session is listed for a day after its last turn
  -a, --all              list every session touched in the window
  --sort recent|active   order by last activity (default) or by work time
  --local                this machine only, skip configured hosts
  --host LABEL=DEST      query this host too (or only, with --local)
  --tmux | --no-tmux     run local sessions inside tmux too | never use tmux
  --claude | --codex     continue the chosen session in that tool
  --no-codex             leave Codex sessions out (they are listed when
                         ~/.codex has any)
  --json                 machine-readable output
  -n, --dry-run          print the resume command instead of running it
  --rescan               rebuild the cache from scratch
  --no-fzf               use the built-in picker even if fzf is installed
  -v, --version          print the version
  -- ARGS                pass ARGS to claude or codex, e.g.  s 2 -- --model opus
  SESSIONS_CODEX_ARGS    extra arguments for every codex it starts, e.g.
                         export SESSIONS_CODEX_ARGS="-p astra"

Companion: ai-bridge (same repo) shares memory and MCP servers between Claude
Code and Codex; see `ai-bridge --help`.

Other machines answer within about a second; one that is slower is shown as of
its last answer and refreshed in the background for next time.

Markers   ● session is running (green = busy, yellow = idle)
          ↻ session set up cron jobs (green = a job is still live)

Inside the picker:  3 = resume #3   c 3 / x 3 = continue #3 in Claude / Codex
                    s 3 = details   /text = filter   ?text = search every prompt
                    n / p = next / previous page (n past the last page and
                    o reach further back: 30 days, 90, a year, everything)
                    q = quit
                    With fzf: alt-c / alt-x continue, alt-o reaches further back.
"""
import argparse
import glob
import json
import math
import os
import re
import select as selectlib
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone, time as dtime
from urllib.parse import quote

VERSION = "0.16.0"
UPDATE_URL = "https://raw.githubusercontent.com/mohammadnaraghi/sessions/main/s"


def env(name):
    return os.environ.get("SESSIONS_" + name)


CLAUDE_DIR = env("CLAUDE_DIR") or os.path.expanduser("~/.claude")  # override for tests
PROJECTS = os.path.join(CLAUDE_DIR, "projects")
CONFIG_DIR = env("CONFIG_DIR") or os.path.expanduser("~/.config/sessions")
CACHE_DIR = env("CACHE_DIR") or os.path.expanduser("~/.cache/sessions")
CACHE = os.path.join(CACHE_DIR, "cache.json")
CACHE_VERSION = 8
HOSTS_FILE = os.path.join(CONFIG_DIR, "hosts")
HOME = env("HOME") or os.path.expanduser("~")  # override for tests
HOME_RE = re.compile(r"^/(?:Users|home)/[^/]+")
GAP = 30 * 60  # silence longer than this is not counted as work
CRON_LIFETIME = timedelta(days=7)  # recurring in-session jobs auto-expire after this
CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
CODEX_CACHE = os.path.join(CACHE_DIR, "codex.json")
CODEX_CACHE_VERSION = 8
HANDOFF_DIR = os.path.join(CACHE_DIR, "handoffs")  # transcripts handed from one tool to the other
HANDOFF_MAX = 80_000  # characters of a session's conversation in a handoff (about 20k tokens)
# Codex models read about 272k tokens. A Claude conversation bigger than this is not imported
# whole (Codex could not even compact it); Codex gets Claude's summary plus the recent part.
IMPORT_MAX_TOKENS = 150_000
REMOTE_WAIT = 1.2  # seconds to wait for other machines before showing their last answer
# Reuse one ssh connection per host for a few minutes, so repeated runs skip the handshake.
CONTROL_OPTS = (["-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/s-%C", "-o", "ControlPersist=10m"]
                if os.path.isdir(os.path.expanduser("~/.ssh")) else [])
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", *CONTROL_OPTS]
# Non-interactive ssh shells have a bare PATH; find s where the installer puts it.
REMOTE_S = "sh -c 'PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; exec s \"$@\"' s"
SKIP_PREFIX = (
    "<task-notification>", "<system-reminder>", "[Request interrupted",
    "<artifact-content", "<local-command", "<command-name>", "<command-message>",
    "<command-args>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "Caveat:",
    "This session is being continued", "<ide_opened_file>", "<ide_selection>",
)
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
# How one tool's session points at the other's: a Codex transcript handed to Claude (by s or by
# ai-bridge), or a command that reads the other tool's session ("continue where Codex left off").
HANDOFF_RE = re.compile(r"handoffs/(?:\d{8}-\d{4}-)?(" + UUID + r")\.md")
# (ai-bridge's reader run as the command, the way its hooks tell an agent to: not a command that
# merely mentions it, nor one that runs a copy of it some other way)
READS_CODEX_RE = re.compile(r"(?:^|&&|;|\|)\s*['\"]?[^\s'\";&|]*ai-bridge['\"]?\s+codex-transcript\s+(" + UUID + ")")
READS_CLAUDE_RE = re.compile(r"(?:^|&&|;|\|)\s*['\"]?[^\s'\";&|]*ai-bridge['\"]?\s+claude-transcript\s+(" + UUID + ")")
PASTE_RE = re.compile(r"</?pasted_content[^>]*>")
REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
WS_RE = re.compile(r"\s+")

TTY = sys.stdout.isatty()
HOSTS = {}


def c(code, s):
    return f"\033[{code}m{s}\033[0m" if TTY else s


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


# ----------------------------------------------------------------- parsing

def clean_part(txt):
    txt = REMINDER_RE.sub(" ", PASTE_RE.sub(" ", txt)).strip()
    if not txt or txt.startswith(SKIP_PREFIX):
        return None
    return WS_RE.sub(" ", txt)


def prompt_text(content):
    """Return the human-written text of a user message, or None."""
    if isinstance(content, str):
        parts = [content]
    elif isinstance(content, list):
        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in content):
            return None
        parts = [x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text"]
    else:
        return None
    parts = [p for p in (clean_part(p) for p in parts) if p]
    return " ".join(parts) if parts else None


def tool_summary(name, inp):
    if name == "Bash":
        s = inp.get("description") or inp.get("command") or ""
    elif name in ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit"):
        s = inp.get("file_path") or ""
    elif name in ("Agent", "Task"):
        s = inp.get("description") or ""
    elif name in ("Grep", "Glob"):
        s = inp.get("pattern") or ""
    elif name == "Skill":
        s = inp.get("skill") or ""
    elif name in ("WebFetch", "WebSearch"):
        s = inp.get("url") or inp.get("query") or ""
    else:
        s = json.dumps(inp)
    return WS_RE.sub(" ", str(s))[:160]


def job_stub(jid):
    return dict(id=jid, cron=None, recurring=True, prompt="", created=None, human="",
                deleted=None, fires=[], error=None)


def new_state():
    return dict(offset=0, first=None, last=None, active=0.0, days={}, user=0,
                assistant=0, tools=0, cwd=None, branch=None, model=None,
                ai_title=None, custom_title=None, first_prompts=[], last_prompts=[],
                last_prompt_ts=None, last_said=None, open_tools={}, ctx_tokens=0,
                todo=None, jobs={}, pending_cron={}, links=[], usage={}, usage_recent={})


# ----------------------------------------------------------------- cost

# API list prices in $ per million tokens: input, output, short cache write (Anthropic 5 min,
# OpenAI 30 min), long cache write (1 h / 12 h), cache read. From
# platform.claude.com/docs/en/about-claude/pricing and developers.openai.com/api/docs/pricing.
# This is what the tokens would cost on the pay-as-you-go API; subscriptions bill differently.
PRICES_AS_OF = "2026-10-22"
_OPUS_45 = (5, 25, 6.25, 10, 0.50)
_OPUS_41 = (15, 75, 18.75, 30, 1.50)
_SONNET_45 = (3, 15, 3.75, 6, 0.30)
_FABLE_51 = (10, 50, 12.50, 20, 0.25)
_FABLE_5 = (10, 50, 12.50, 20, 1.00)
PRICES = {
    "claude-fable-5-1": _FABLE_51, "claude-mythos-5-1": _FABLE_51,
    "claude-fable-5": _FABLE_5, "claude-mythos-5": _FABLE_5,
    "claude-opus-5-5": (4, 20, 5, 8, 0.20),
    "claude-opus-5": _OPUS_45, "claude-opus-4-8": _OPUS_45, "claude-opus-4-7": _OPUS_45,
    "claude-opus-4-6": _OPUS_45, "claude-opus-4-5": _OPUS_45,
    "claude-opus-4-1": _OPUS_41, "claude-opus-4": _OPUS_41,
    "claude-sonnet-5-5": (2, 10, 2.50, 4, 0.10), "claude-sonnet-5": (2, 10, 2.50, 4, 0.20),
    "claude-sonnet-4-6": _SONNET_45, "claude-sonnet-4-5": _SONNET_45, "claude-sonnet-4": _SONNET_45,
    "claude-haiku-5-5": (0.10, 0.50, 0.125, 0.20, 0.01), "claude-haiku-4-5": (1, 5, 1.25, 2, 0.10),
    "claude-3-5-haiku": (0.80, 4, 1, 1.60, 0.08),
    "gpt-6-astra": (10, 50, 12.50, 25, 1.00), "gpt-6.1-sol": (2, 10, 2.50, 5, 0.10),
    "gpt-6-sol": (2, 10, 2.50, 5, 0.20), "gpt-6-luna": (0.10, 0.50, 0.125, 0.25, 0.01),
    "gpt-5.6-sol": (4, 20, 5, 10, 0.40), "gpt-5.6-terra": (2, 12, 2.50, 5, 0.20),
    "gpt-5.6-luna": (0.20, 1.20, 0.25, 0.50, 0.02), "gpt-5.5": (5, 30, 5, 5, 0.50),
    "gpt-5.4": (2.50, 15, 2.50, 2.50, 0.25), "gpt-5.4-mini": (0.75, 4.50, 0.75, 0.75, 0.075),
    "gpt-5.4-nano": (0.20, 1.25, 0.20, 0.20, 0.02), "gpt-5.3-codex": (1.75, 14, 1.75, 1.75, 0.175),
}
# a request whose prompt is over the threshold pays these rates for all of it
LONG_PROMPT = {"claude-haiku-5-5": 100_000, "gpt": 272_000}
LONG_PRICES = {
    "claude-haiku-5-5": (0.50, 2.50, 0.625, 1, 0.05),
    "gpt-6-astra": (20, 75, 25, 50, 2.00), "gpt-6.1-sol": (4, 15, 5, 10, 0.20),
    "gpt-6-sol": (4, 15, 5, 10, 0.40), "gpt-6-luna": (0.20, 0.75, 0.25, 0.50, 0.02),
    "gpt-5.6-sol": (8, 30, 10, 20, 0.80), "gpt-5.6-terra": (4, 18, 5, 10, 0.40),
    "gpt-5.6-luna": (0.40, 1.80, 0.50, 1, 0.04), "gpt-5.5": (10, 45, 10, 10, 1.00),
    "gpt-5.4": (5, 22.50, 5, 5, 0.50),
}
FAST_PRICES = {"claude-opus-5-5": (8, 40, 10, 16, 0.40), "claude-opus-5": (10, 50, 12.50, 20, 1.00),
               "claude-opus-4-8": (10, 50, 12.50, 20, 1.00)}
UNPRICED = {"codex-auto-review": "Codex's approval reviewer"}  # models with no API list price
US_ONLY = 1.1  # inference_geo "us" on Claude 4.6 and later
WEB_SEARCH = 0.01  # $ per Claude web search
NO_US_PREMIUM = ("claude-opus-4-5", "claude-opus-4-1", "claude-opus-4", "claude-sonnet-4-5",
                 "claude-sonnet-4", "claude-haiku-4-5", "claude-3-5-haiku")


def base_model(model):
    return re.sub(r"-\d{8}$", "", model or "")  # claude-haiku-4-5-20251001 -> claude-haiku-4-5


def long_threshold(model):
    return LONG_PROMPT.get(model) or (LONG_PROMPT["gpt"] if model.startswith("gpt") else None)


def price_of(key):
    """$ per million tokens for a usage key 'model|flag|flag', or None when the model is unknown."""
    model, *flags = key.split("|")
    if "fast" in flags:
        p = FAST_PRICES.get(model)
    elif "long" in flags:
        p = LONG_PRICES.get(model) or PRICES.get(model)
    else:
        p = PRICES.get(model)
    if p and "us" in flags and model not in NO_US_PREMIUM:
        p = tuple(x * US_ONLY for x in p)
    return p


def cost_of(key, vec):
    """vec = [input, output, short cache write, long cache write, cache read, web searches]."""
    p = price_of(key)
    if p is None:
        return None
    return sum(v * x for v, x in zip(vec[:5], p)) / 1e6 + vec[5] * WEB_SEARCH


def add_usage(usage, day, key, vec, sign=1):
    cur = usage.setdefault(day, {}).setdefault(key, [0] * 6)
    for i, v in enumerate(vec):
        cur[i] += sign * v


def merge_usage(*usages):
    out = {}
    for usage in usages:
        for day, keys in (usage or {}).items():
            for key, vec in keys.items():
                add_usage(out, day, key, vec)
    return out


def note_claude_usage(st, o, ts):
    """Count one Claude response's tokens. Claude Code writes a response once per content block,
    each line carrying its usage, so a repeat replaces the earlier count instead of adding to it."""
    msg = o.get("message") or {}
    u, model = msg.get("usage"), base_model(msg.get("model"))
    if not u or not model or model.startswith("<"):
        return
    write = u.get("cache_creation_input_tokens") or 0
    ttl = u.get("cache_creation") or {}
    long_write = ttl.get("ephemeral_1h_input_tokens") or 0
    vec = [u.get("input_tokens") or 0, u.get("output_tokens") or 0, max(0, write - long_write), long_write,
           u.get("cache_read_input_tokens") or 0, (u.get("server_tool_use") or {}).get("web_search_requests") or 0]
    flags = [model]
    limit = long_threshold(model)
    if limit and vec[0] + write + vec[4] > limit:
        flags.append("long")
    if u.get("speed") == "fast":
        flags.append("fast")
    if u.get("inference_geo") == "us":
        flags.append("us")
    key, day = "|".join(flags), ts.astimezone().strftime("%Y-%m-%d")
    mid = (msg.get("id") or "") + (o.get("requestId") or "")
    recent = st.setdefault("usage_recent", {})
    if mid and mid in recent:
        add_usage(st["usage"], *recent[mid], sign=-1)
    add_usage(st["usage"], day, key, vec)
    if mid:
        recent[mid] = [day, key, vec]
        while len(recent) > 12:
            del recent[next(iter(recent))]


def first_session_id(path):
    """The session an older top-level agent-*.jsonl transcript belongs to."""
    try:
        with open(path, errors="ignore") as f:
            for _, line in zip(range(20), f):
                try:
                    sid = json.loads(line).get("sessionId")
                except ValueError:
                    continue
                if sid:
                    return sid
    except OSError:
        pass
    return None


def parse_usage(path, st):
    """Only the token usage of a subagent's transcript, read from where the last read stopped."""
    with open(path, "rb") as f:
        f.seek(st["offset"])
        data = f.read()
    end = data.rfind(b"\n")
    if end < 0:
        return st
    st["offset"] += end + 1
    for line in data[: end + 1].split(b"\n"):
        if b'"usage"' not in line or b'"assistant"' not in line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        ts = parse_ts(o.get("timestamp"))
        if o.get("type") == "assistant" and ts:
            note_claude_usage(st, o, ts)
    return st


def usage_cost(usage, days=None):
    """-> (total $, {key: $}, {key: tokens} for models without a known price)."""
    total, by_key, unknown = 0.0, {}, {}
    for day, keys in (usage or {}).items():
        if days is not None and day not in days:
            continue
        for key, vec in keys.items():
            c = cost_of(key, vec)
            if c is None:
                unknown[key.split("|")[0]] = unknown.get(key.split("|")[0], 0) + sum(vec[:5])
                continue
            total += c
            by_key[key.split("|")[0]] = by_key.get(key.split("|")[0], 0) + c
    return total, by_key, unknown


def add_links(st, pattern, text):
    for other in pattern.findall(text or ""):
        if other not in st["links"] and len(st["links"]) < 20:
            st["links"].append(other)


def parse(path, st):
    """Consume any bytes appended to a transcript since st['offset']."""
    with open(path, "rb") as f:
        f.seek(st["offset"])
        data = f.read()
    end = data.rfind(b"\n")
    if end < 0:
        return st
    chunk = data[: end + 1]
    st["offset"] += len(chunk)
    prev = parse_ts(st["last"])
    first = parse_ts(st["first"])
    for line in chunk.split(b"\n"):
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        t = o.get("type")
        if t == "ai-title":
            st["ai_title"] = o.get("aiTitle") or st["ai_title"]
            continue
        if t == "custom-title":
            st["custom_title"] = o.get("customTitle") or st["custom_title"]
            continue
        if t not in ("user", "assistant"):
            continue
        ts = parse_ts(o.get("timestamp"))
        if ts is None:
            continue
        if first is None or ts < first:
            first = ts
        if prev is not None:
            gap = (ts - prev).total_seconds()
            if 0 < gap <= GAP:
                st["active"] += gap
                day = ts.astimezone().strftime("%Y-%m-%d")
                st["days"][day] = st["days"].get(day, 0) + gap
        if prev is None or ts > prev:
            prev = ts
        if st["cwd"] is None and o.get("cwd"):
            st["cwd"] = o["cwd"]
        if o.get("gitBranch"):
            st["branch"] = o["gitBranch"]
        msg = o.get("message") or {}
        content = msg.get("content")
        if t == "user":
            if o.get("turnOrigin") == "scheduled" and o.get("scheduledTaskId"):
                j = st["jobs"].setdefault(o["scheduledTaskId"], job_stub(o["scheduledTaskId"]))
                j["fires"].append(ts.isoformat())
                if not j["prompt"] and isinstance(content, str):
                    j["prompt"] = WS_RE.sub(" ", content)[:200]
                continue
            if isinstance(content, list):
                for x in content:
                    if not (isinstance(x, dict) and x.get("type") == "tool_result"):
                        continue
                    tid = x.get("tool_use_id")
                    st["open_tools"].pop(tid, None)
                    if tid in st["pending_cron"]:
                        inp = st["pending_cron"].pop(tid)
                        body = x.get("content")
                        s = body if isinstance(body, str) else json.dumps(body)
                        m = re.search(r"(?:job|task) ([0-9a-f]{6,})", s)
                        jid = m.group(1) if m else "?" + tid[-6:]
                        j = st["jobs"].setdefault(jid, job_stub(jid))
                        j.update(cron=inp["cron"], recurring=inp["recurring"], prompt=inp["prompt"],
                                 created=inp["ts"])
                        human = re.search(r"\((.*?)\)", s)
                        j["human"] = human.group(1) if human else ""
                        if not m:
                            j["error"] = WS_RE.sub(" ", s)[:160]
            if o.get("isMeta"):
                continue
            txt = prompt_text(content)
            if not txt:
                continue
            add_links(st, HANDOFF_RE, txt)
            st["user"] += 1
            st["last_prompt_ts"] = ts.isoformat()
            item = [ts.isoformat(), txt[:400]]
            recent = (st["last_prompts"] or st["first_prompts"])
            if recent and recent[-1][1] == txt[:400]:
                continue
            if len(st["first_prompts"]) < 5:
                st["first_prompts"].append(item)
            else:
                st["last_prompts"] = (st["last_prompts"] + [item])[-4:]
        else:
            st["assistant"] += 1
            note_claude_usage(st, o, ts)
            if not st["model"] and msg.get("model"):
                st["model"] = msg["model"]
            usage = msg.get("usage") or {}
            ctx = ((usage.get("input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0)
                   + (usage.get("cache_creation_input_tokens") or 0))
            if ctx:
                st["ctx_tokens"] = ctx
            if not isinstance(content, list):
                continue
            for x in content:
                if not isinstance(x, dict):
                    continue
                if x.get("type") == "text" and x.get("text", "").strip():
                    st["last_said"] = [ts.isoformat(), WS_RE.sub(" ", x["text"]).strip()[:300]]
                elif x.get("type") == "tool_use":
                    st["tools"] += 1
                    nm, inp = x.get("name"), x.get("input") or {}
                    st["open_tools"][x["id"]] = [ts.isoformat(), nm, tool_summary(nm, inp)]
                    while len(st["open_tools"]) > 8:
                        del st["open_tools"][next(iter(st["open_tools"]))]
                    if nm == "Bash":
                        add_links(st, READS_CODEX_RE, inp.get("command"))
                    if nm == "CronCreate":
                        st["pending_cron"][x["id"]] = {
                            "cron": inp.get("cron"), "recurring": inp.get("recurring", True),
                            "prompt": WS_RE.sub(" ", inp.get("prompt") or "")[:200], "ts": ts.isoformat()}
                    elif nm == "CronDelete":
                        jid = inp.get("id") or inp.get("jobId")
                        if jid:
                            st["jobs"].setdefault(jid, job_stub(jid))["deleted"] = ts.isoformat()
                    elif nm == "TodoWrite":
                        todos = inp.get("todos") or []
                        if todos:
                            done = sum(1 for td in todos if td.get("status") == "completed")
                            cur = next((td.get("activeForm") or td.get("content")
                                        for td in todos if td.get("status") == "in_progress"), None)
                            st["todo"] = {"done": done, "total": len(todos), "current": cur}
    st["first"] = first.isoformat() if first else None
    st["last"] = prev.isoformat() if prev else None
    return st


def load_sessions(days, rescan=False, include=()):
    """This machine's Claude sessions active in the window (or parsed before), and those in
    `include` (transcript paths) however old."""
    cache = {}
    if not rescan and os.path.exists(CACHE):
        try:
            with open(CACHE) as f:
                cache = json.load(f)
        except ValueError:
            cache = {}
        if cache.get("__version__") != CACHE_VERSION:
            cache = {}
    cache["__version__"] = CACHE_VERSION
    horizon = (datetime.now() - timedelta(days=days)).timestamp()
    out, dirty, sub_usage = [], False, {}
    include_ids = {os.path.basename(p)[:-6] for p in include}
    if not os.path.isdir(PROJECTS):
        return out

    def read_subagent(path, parent):
        """A subagent's or workflow agent's transcript: its tokens count toward the session that ran it."""
        nonlocal dirty
        entry = cache.get(path)
        try:  # a running session may remove a subagent's file while s looks
            s = os.stat(path)
            if entry and entry["mtime"] == s.st_mtime and entry["size"] == s.st_size:
                st = entry["st"]
            elif s.st_mtime < horizon and not entry and parent not in include_ids:
                return
            else:
                st = (entry["st"] if entry and entry["size"] <= s.st_size
                      else {"offset": 0, "usage": {}, "usage_recent": {}, "parent": parent or first_session_id(path)})
                st = parse_usage(path, st)
                cache[path] = {"mtime": s.st_mtime, "size": s.st_size, "st": st}
                dirty = True
        except OSError:
            if not entry:
                return
            st = entry["st"]
        if st.get("parent") and st["usage"]:
            sub_usage[st["parent"]] = merge_usage(sub_usage.get(st["parent"]), st["usage"])

    for proj in os.scandir(PROJECTS):
        if not proj.is_dir():
            continue
        for ent in os.scandir(proj.path):
            if ent.is_dir() and re.fullmatch(UUID, ent.name):  # <session id>/subagents/...
                for root, _, files in os.walk(ent.path):  # (os.walk skips folders that vanish)
                    for fn in files:
                        if fn.endswith(".jsonl"):
                            read_subagent(os.path.join(root, fn), ent.name)
                continue
            if ent.name.startswith("agent-") and ent.name.endswith(".jsonl"):  # older layout
                read_subagent(ent.path, None)
                continue
            if not ent.name.endswith(".jsonl"):
                continue
            entry = cache.get(ent.path)
            try:
                s = ent.stat()
                if entry and entry["mtime"] == s.st_mtime and entry["size"] == s.st_size:
                    st = entry["st"]
                elif s.st_mtime < horizon and not entry and ent.path not in include:
                    continue  # too old to matter and never parsed
                else:
                    st = entry["st"] if entry and entry["size"] <= s.st_size else new_state()
                    st = parse(ent.path, st)
                    cache[ent.path] = {"mtime": s.st_mtime, "size": s.st_size, "st": st}
                    dirty = True
            except OSError:  # removed while s looked
                continue
            if not st["first"]:
                continue
            out.append(dict(id=ent.name[:-6], path=ent.path, project_dir=proj.name, host=None, app="claude", **st))
    for s in out:
        if s["id"] in sub_usage:
            s["usage"] = merge_usage(s.get("usage"), sub_usage[s["id"]])
    if dirty:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, CACHE)
    return out


# ----------------------------------------------------------------- Codex sessions

class CodexError(Exception):
    pass


class CodexServer:
    """Minimal JSON-RPC client for `codex app-server`, Codex's own API to its sessions. Only
    importing a Claude conversation needs it; listing and reading go to Codex's files."""

    def __init__(self, cwd, timeout=8):
        try:
            self.proc = subprocess.Popen(["codex", "app-server"], cwd=cwd, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as e:
            raise CodexError(f"cannot start codex: {e}")
        self.fd, self.buf, self.next_id, self.notes = self.proc.stdout.fileno(), b"", 0, []
        try:
            self.request("initialize", {"clientInfo": {"name": "sessions", "title": "sessions", "version": VERSION},
                                        "capabilities": {"experimentalApi": False}}, timeout)
            self.send({"method": "initialized", "params": {}})
        except CodexError:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        try:  # end of input lets it finish what it is writing (such as a refreshed login) and exit
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
            return
        except (OSError, subprocess.TimeoutExpired):
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def send(self, msg):
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def read(self, deadline):
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0:
                raise CodexError("codex did not answer in time")
            if not selectlib.select([self.fd], [], [], left)[0]:
                continue
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise CodexError("codex app-server exited")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line) if line.strip() else self.read(deadline)

    def handle(self, msg):
        if "id" in msg and "method" in msg:  # a request from the server; s answers none
            self.send({"id": msg["id"], "error": {"code": -32601, "message": "unsupported"}})
        elif "method" in msg:
            self.notes.append(msg)

    def request(self, method, params, timeout=30):
        self.next_id += 1
        rid = self.next_id
        self.send({"id": rid, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            msg = self.read(deadline)
            if msg.get("id") == rid and "method" not in msg:
                if "error" in msg:
                    raise CodexError(f"{method}: {msg['error'].get('message', msg['error'])}")
                return msg.get("result") or {}
            self.handle(msg)

    def wait_for(self, method, timeout):
        deadline = time.monotonic() + timeout
        while True:
            for note in self.notes:
                if note.get("method") == method:
                    self.notes.remove(note)
                    return note.get("params") or {}
            self.handle(self.read(deadline))


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def codex_db():
    """Codex's own index of its threads, opened read-only, or None. s reads Codex's files and
    never starts Codex just to look: every `codex` process shares the ChatGPT login and may
    refresh it, and two refreshing at once can sign all of them out."""
    found = []
    for p in glob.glob(os.path.join(CODEX_HOME, "state_*.sqlite")):
        m = re.search(r"state_(\d+)\.sqlite$", p)
        if m:
            found.append((int(m.group(1)), p))
    if not found:
        return None
    db = sqlite3.connect(f"file:{quote(max(found)[1])}?mode=ro", uri=True, timeout=3)
    db.row_factory = sqlite3.Row
    return db


def rollout_file(path):
    """Where a Codex session file is now; Codex compresses older ones with zstd."""
    for p in (path, path + ".zst") if path else ():
        if os.path.isfile(p):
            return p
    return None


def read_rollout(path):
    """A Codex session file's text."""
    p = rollout_file(path)
    if not p:
        return None
    with open(p, "rb") as f:
        data = f.read()
    if p.endswith(".zst"):
        try:
            from compression import zstd  # Python 3.14+
            data = zstd.decompress(data)
        except ImportError:
            if not shutil.which("zstd"):
                return None
            data = subprocess.run(["zstd", "-dcq"], input=data, capture_output=True).stdout
    return data.decode("utf-8", "ignore")


CODEX_NOT_TOOLS = ("UserMessage", "AgentMessage", "Reasoning", "ContextCompaction", "SubAgentActivity",
                   "Plan", "TodoList")
CODEX_CALLS = ("function_call", "custom_tool_call", "local_shell_call", "web_search_call")


def codex_text(content):
    if isinstance(content, str):
        return content
    return "\n".join(x.get("text") or "" for x in content or [] if isinstance(x, dict) and "text" in x)


EXEC_CMD_RE = re.compile(r'exec_command\(\s*\{\s*"?cmd"?\s*:\s*"((?:[^"\\]|\\.)*)"')
PATCH_FILE_RE = re.compile(r"\*\*\* (?:Add|Update|Delete) File: ([^\n\\\"]+)")


def call_commands(item):
    """The shell commands inside a raw Codex tool call: in code mode Codex runs them from a script
    (tools.exec_command({cmd: "..."})), else they are the call's own arguments."""
    body, cmds = item.get("command") or "", []
    for m in EXEC_CMD_RE.finditer(body):
        try:
            cmds.append(json.loads('"' + m.group(1) + '"'))
        except ValueError:
            cmds.append(m.group(1))
    if not cmds and body.lstrip().startswith("{"):
        try:
            args = json.loads(body)
        except ValueError:
            args = {}
        cmd = args.get("cmd") or args.get("command") if isinstance(args, dict) else None
        if isinstance(cmd, list):
            cmd = cmd[-1] if len(cmd) == 3 and cmd[1] in ("-c", "-lc") else shlex.join(map(str, cmd))
        if isinstance(cmd, str):
            cmds.append(cmd)
    return cmds


def codex_command(item):
    if item.get("type") == "Call":
        return " ; ".join(call_commands(item))
    cmd = item.get("command")
    if isinstance(cmd, list):  # ["/bin/zsh", "-lc", "the command"]
        cmd = cmd[-1] if len(cmd) == 3 and cmd[1] in ("-c", "-lc") else shlex.join(map(str, cmd))
    return str(cmd or "")


def codex_events(text, items=None):
    """A Codex session file as (kind, unix time, value), alike for its older and newer formats:
    start (a turn begins), end (value: start, end, error), model, tokens (token_count info),
    user / agent (message text), tool (the item), call (a raw tool call, for its text). Turns
    Codex imported from a Claude transcript are left out: they are that Claude session's."""
    if items is None:  # newer files log every item; older ones only messages
        items = '"item_completed"' in text
    imported = False
    for line in text.splitlines():
        try:
            o = json.loads(line)
        except ValueError:
            continue
        kind, p = o.get("type"), o.get("payload")
        if not isinstance(p, dict):
            continue
        ts = parse_ts(o.get("timestamp"))
        t, sub = ts.timestamp() if ts else None, p.get("type")
        if kind == "turn_context":
            yield "model", t, p.get("model")
        elif kind == "event_msg" and sub == "task_started":
            imported = str(p.get("turn_id") or "").startswith("external-import")
            if not imported:
                yield "start", p.get("started_at") or t, None
        elif imported:
            continue
        elif kind == "event_msg" and sub in ("task_complete", "turn_aborted"):
            err = p.get("error")
            err = (err.get("message") if isinstance(err, dict) else err) or ""
            end = p.get("completed_at") or t
            yield "end", end, (p.get("started_at"), end, str(err))
        elif kind == "event_msg" and sub == "token_count":
            yield "tokens", t, p.get("info") or {}
        elif kind == "event_msg" and sub == "item_completed":
            item = p.get("item") or {}
            if item.get("type") == "UserMessage":
                yield "user", t, codex_text(item.get("content"))
            elif item.get("type") == "AgentMessage":
                yield "agent", t, codex_text(item.get("content"))
            elif item.get("type") not in CODEX_NOT_TOOLS:
                yield "tool", t, item
        elif kind == "event_msg" and sub in ("user_message", "agent_message") and not items:
            yield sub.split("_")[0], t, p.get("message") or ""
        elif kind == "response_item" and sub in CODEX_CALLS:
            body = p.get("arguments") or p.get("input") or p.get("action") or ""
            yield ("call" if items else "tool"), t, {"type": "Call", "name": p.get("name") or sub,
                                                     "command": body if isinstance(body, str) else json.dumps(body)}


def codex_state(row, text):
    """A Codex thread (its index row and session file) summarised into the same fields a Claude
    transcript gets."""
    st = new_state()
    st.update(cwd=row.get("cwd"), ai_title=row.get("name") or None, branch=row.get("git_branch"))
    model, usage, prev = row.get("model"), {}, None
    span = {"first": None, "last": None, "prev_end": None}
    start, err, seen = None, "", None

    def turn(a, b):
        b = max(a, b or a)
        work = b - a
        if span["prev_end"] is not None and 0 < a - span["prev_end"] <= GAP:
            work += a - span["prev_end"]
        st["active"] += work
        day = datetime.fromtimestamp(a).strftime("%Y-%m-%d")
        st["days"][day] = st["days"].get(day, 0) + work
        span["prev_end"] = b
        span["first"] = a if span["first"] is None else min(span["first"], a)
        span["last"] = b if span["last"] is None else max(span["last"], b)

    for kind, t, v in codex_events(text or ""):
        seen = max(seen or 0, t or 0) or seen
        if kind == "start":
            start = t
        elif kind == "end":
            a = v[0] or start or v[1]
            if a:
                turn(a, v[1])
                # the last finished turn: Codex runs a resumed thread's start hook as the next one begins
                st["last_done"] = iso(max(a, v[1] or a))
            start, err = None, v[2]
        elif kind == "model":
            model = v or model
        elif kind == "tokens":
            total, last = v.get("total_token_usage"), v.get("last_token_usage") or {}
            if not total or not t or not model:
                continue
            cur = [total.get(k) or 0 for k in ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                                               "output_tokens")]
            delta = [c - p for c, p in zip(cur, prev)] if prev and all(c >= p for c, p in zip(cur, prev)) else cur
            prev = cur
            if not any(delta):
                continue
            inp, cached, write, out = delta
            key = model + ("|long" if (last.get("input_tokens") or 0) > (long_threshold(model) or 1e18) else "")
            add_usage(usage, datetime.fromtimestamp(t).strftime("%Y-%m-%d"), key,
                      [max(0, inp - cached - write), out, write, 0, cached, 0])
        elif kind == "user":
            add_links(st, HANDOFF_RE, v)
            txt = clean_part(v or "")
            if not txt:
                continue
            st["user"] += 1
            st["last_prompt_ts"] = iso(t or start or 0)
            entry = [st["last_prompt_ts"], txt[:400]]
            if len(st["first_prompts"]) < 5:
                st["first_prompts"].append(entry)
            else:
                st["last_prompts"] = (st["last_prompts"] + [entry])[-4:]
        elif kind == "agent" and (v or "").strip():
            st["assistant"] += 1
            st["last_said"] = [iso(t or 0), WS_RE.sub(" ", v).strip()[:300]]
        elif kind in ("tool", "call"):
            st["tools"] += kind == "tool"
            add_links(st, READS_CLAUDE_RE, codex_command(v))
    if start is not None:  # a turn still running
        turn(start, seen)
    st["model"], st["usage"] = model, usage
    # where you last worked: the last turn, not the index's updated time, which other things touch
    st["first"] = iso(span["first"] or row.get("created_at") or 0)
    st["last"] = iso(span["last"] or row.get("updated_at") or row.get("created_at") or 0)
    if "context_length_exceeded" in err or "context window" in err:
        st["broken"] = "too big for Codex's context window"  # every new turn fails the same way
    return st


def codex_parent(row, text):
    """The thread a Codex subagent or reviewer thread worked for."""
    try:
        spawn = (json.loads(row.get("source") or "{}").get("subagent") or {}).get("thread_spawn") or {}
    except (ValueError, AttributeError):
        spawn = {}
    if spawn.get("parent_thread_id"):
        return spawn["parent_thread_id"]
    first = (text or "").split("\n", 1)[0]
    try:
        meta = json.loads(first).get("payload") or {}
    except ValueError:
        return None
    parent = meta.get("parent_thread_id") or meta.get("session_id")
    return parent if parent and parent != row.get("id") else None


def load_codex(days, rescan=False, include=()):
    """-> (Codex sessions touched in the window, note), from Codex's thread index and session
    files. A thread is read again only when its file changed. Work Codex's subagents and
    reviewers did counts toward the thread they worked for."""
    if not os.path.isdir(CODEX_HOME):
        return [], None
    try:
        with open(CODEX_CACHE) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    if cache.get("__version__") != CODEX_CACHE_VERSION:
        cache = {}
    old, note = cache.get("threads") or {}, None
    horizon = time.time() - days * 86400
    threads, dirty = {}, False
    try:
        db = codex_db()
        if db is None:
            return [], None
        try:
            wanted = sorted(include)
            rows = [dict(r) for r in db.execute(
                "select * from threads where updated_at >= ?" + " or id = ?" * len(wanted), [int(horizon), *wanted])]
            try:
                edges = dict(db.execute("select child_thread_id, parent_thread_id from thread_spawn_edges"))
            except sqlite3.Error:
                edges = {}
        finally:
            db.close()
        for r in rows:
            source = r.get("source") or ""
            child = source.startswith("{")  # {"subagent": ...}
            if (not child and (source == "exec" or r.get("archived"))) or not r.get("id"):
                continue  # `codex exec` runs and archived threads are not sessions to show
            path = rollout_file(r.get("rollout_path"))
            try:
                fs = os.stat(path) if path else None
            except OSError:
                fs = None
            sig = [path, fs.st_mtime if fs else None, fs.st_size if fs else None,
                   r.get("updated_at"), r.get("name"), r.get("git_branch")]
            prev = old.get(r["id"])
            if prev and prev.get("sig") == sig and not rescan:
                threads[r["id"]] = prev
                continue
            text = read_rollout(path) if path else None
            threads[r["id"]] = {"sig": sig, "rollout": path, "child": child, "st": codex_state(r, text),
                                "parent": (edges.get(r["id"]) or codex_parent(r, text)) if child else None}
            dirty = True
        listed = {r.get("id") for r in rows}
        for tid, e in old.items():  # read before for a longer window or a search: still good
            if tid not in listed and tid not in threads:
                threads[tid] = e
        if dirty or set(threads) != set(old):
            os.makedirs(CACHE_DIR, exist_ok=True)
            tmp = CODEX_CACHE + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"__version__": CODEX_CACHE_VERSION, "threads": threads}, f)
            os.replace(tmp, CODEX_CACHE)
    except (sqlite3.Error, OSError, ValueError) as e:
        note = f"codex: cannot read its sessions ({e}); showing them as of the last run"
        threads = old
    work_for = {}
    for tid, e in threads.items():
        if not e.get("child"):
            continue
        boss, hops = e.get("parent"), 0
        while boss in threads and threads[boss].get("child") and hops < 10:
            boss, hops = threads[boss].get("parent"), hops + 1
        work_for.setdefault(boss, []).append(e["st"].get("usage"))
    out = []
    for tid, e in threads.items():
        if e.get("child"):
            continue
        st = dict(e["st"])
        if tid in work_for:
            st["usage"] = merge_usage(st.get("usage"), *work_for[tid])
        out.append(dict(id=tid, path=None, rollout=e.get("rollout"), project_dir="", host=None,
                        app="codex", **st))
    return out, note


def claude_to_codex(s):
    """Import a Claude transcript as a Codex thread (Codex's own importer). -> thread id."""
    source = os.path.realpath(s["path"])
    cwd = s.get("cwd") or HOME
    with CodexServer(cwd, timeout=20) as srv:
        srv.request("externalAgentConfig/import", {"migrationItems": [{
            "itemType": "SESSIONS", "description": f"Transfer Claude session {os.path.basename(source)}",
            "cwd": None,
            "details": {"plugins": [], "sessions": [{"path": source, "cwd": cwd, "title": None}],
                        "mcpServers": [], "hooks": [], "subagents": [], "commands": []}}]})
        done = srv.wait_for("externalAgentConfig/import/completed", 180)
    for result in done.get("itemTypeResults") or []:
        for failure in result.get("failures") or []:
            raise CodexError(f"import failed: {failure.get('message')}")
    try:
        with open(os.path.join(CODEX_HOME, "external_agent_session_imports.json")) as f:
            records = json.load(f).get("records") or []
    except (OSError, ValueError):
        records = []
    ids = [r["imported_thread_id"] for r in records
           if r.get("source_path") == source and r.get("imported_thread_id")]
    if not ids:
        raise CodexError("Codex found nothing to import in that session")
    return ids[-1]


def codex_lines(kind, v):
    """A Codex event as transcript lines for Claude to read."""
    if kind in ("user", "agent"):
        txt = (v or "").strip()
        return [("**You:** " if kind == "user" else "**Codex:** ") + txt] if txt else []
    if kind != "tool":
        return []
    t = v.get("type")
    if t == "CommandExecution":
        code = v.get("exit_code")
        return [f"- ran `{WS_RE.sub(' ', codex_command(v))[:300]}`" + (f" (exit {code})" if code not in (0, None) else "")]
    if t == "FileChange":
        ch = v.get("changes") or {}
        paths = list(ch) if isinstance(ch, dict) else [x.get("path") for x in ch if isinstance(x, dict) and x.get("path")]
        return ["- changed " + ", ".join(paths)] if paths else []
    if t == "McpToolCall":
        return [f"- used {v.get('server')}.{v.get('tool')}"]
    if t in ("WebSearch", "Extension") and v.get("query"):
        return ["- searched the web: " + v["query"]]
    if t == "Call":
        cmds = call_commands(v)
        if cmds:
            return [f"- ran `{WS_RE.sub(' ', cmd)[:300]}`" for cmd in cmds[:5]]
        files = PATCH_FILE_RE.findall(v.get("command") or "")
        return ["- changed " + ", ".join(dict.fromkeys(files))] if files else [f"- used {v.get('name')}"]
    return []


# ----------------------------------------------------------------- sessions as documents
#
# Every handoff, catch-up and `s transcript` is built from one reading of a session as items,
# (unix time, kind, markdown), alike for both tools. Kinds: user, agent (a reply, or a subagent's
# report), tool (one line per call), error (a failed call with what it said), files (a path it
# changed), summary (Claude's own summary of the earlier part, written when it compacted).

EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
SUBAGENT_TOOLS = ("Agent", "Task")
REPORT_MAX = 1500  # a subagent's report or a failure is kept to this many characters


def body_text(body):
    if isinstance(body, str):
        return body
    return "\n".join(x.get("text", "") for x in body or [] if isinstance(x, dict) and x.get("type") == "text")


def claude_items(path, since=None):
    """A Claude transcript as items, only those after `since` (unix time) if given."""
    items, calls = [], {}
    try:
        f = open(path, errors="ignore")
    except OSError:
        return items
    with f:
        for line in f:
            if '"user"' not in line and '"assistant"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            kind = o.get("type")
            if kind not in ("user", "assistant") or o.get("isSidechain"):
                continue
            ts = parse_ts(o.get("timestamp"))
            t = ts.timestamp() if ts else 0
            content = (o.get("message") or {}).get("content")
            blocks = content if isinstance(content, list) else []
            keep = since is None or t > since
            if kind == "assistant":
                for b in blocks:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        nm, inp = b.get("name"), b.get("input") or {}
                        calls[b.get("id")] = (nm, inp)
                        if keep:
                            items.append((t, "tool", f"- {nm}: {tool_summary(nm, inp)}"))
                            if nm in EDIT_TOOLS and (inp.get("file_path") or inp.get("notebook_path")):
                                items.append((t, "files", inp.get("file_path") or inp.get("notebook_path")))
                    elif b.get("type") == "text" and (b.get("text") or "").strip() and keep:
                        items.append((t, "agent", "**Claude:** " + b["text"].strip()))
                continue
            if not keep:
                continue
            if o.get("isCompactSummary"):
                items.append((t, "summary", claude_text_of(content).strip()))
                continue
            for b in blocks:
                if not (isinstance(b, dict) and b.get("type") == "tool_result"):
                    continue
                nm, inp = calls.get(b.get("tool_use_id"), ("tool", {}))
                text = WS_RE.sub(" ", body_text(b.get("content"))).strip()
                if b.get("is_error"):
                    items.append((t, "error", f"- {nm} ({tool_summary(nm, inp)[:120]}) failed: {text[:600]}"))
                elif nm in SUBAGENT_TOOLS and text:
                    items.append((t, "agent", f"**Subagent ({inp.get('description') or nm}):** {text[:REPORT_MAX]}"))
            if o.get("isMeta"):
                continue
            txt = prompt_text(content)
            if txt:
                items.append((t, "user", "**You:** " + txt))
    return items


def codex_items(rollout, since=None):
    """A Codex session file as items, only those after `since` (unix time) if given."""
    items = []
    for kind, t, v in codex_events(read_rollout(rollout) or ""):
        if since is not None and (t or 0) <= since:
            continue
        if kind in ("user", "agent") and (v or "").strip():
            items.append((t or 0, kind, ("**You:** " if kind == "user" else "**Codex:** ") + v.strip()))
        elif kind == "tool":
            items += [(t or 0, "tool", ln) for ln in codex_lines(kind, v)]
            if v.get("type") == "FileChange":
                ch = v.get("changes") or {}
                paths = list(ch) if isinstance(ch, dict) else [x.get("path") for x in ch if isinstance(x, dict)]
                items += [(t or 0, "files", p) for p in paths if p]
            elif v.get("type") == "Call":
                items += [(t or 0, "files", p.strip()) for p in dict.fromkeys(PATCH_FILE_RE.findall(v.get("command") or ""))]
            code = v.get("exit_code")
            if v.get("type") == "CommandExecution" and code not in (0, None):
                out = WS_RE.sub(" ", v.get("aggregated_output") or "").strip()[-600:]  # the error is at the end
                items.append((t or 0, "error", f"- `{WS_RE.sub(' ', codex_command(v))[:200]}` failed (exit {code}): {out}"))
    return items


def session_items(s, since=None):
    if is_remote(s):
        return []
    if app_of(s) == "codex":
        return codex_items(s.get("rollout"), since)
    return claude_items(s["path"], since) if s.get("path") else []


def render_items(items, budget=None):
    """The conversation part of items as markdown, the newest that fit in `budget` characters.
    -> (text, how many items were left out)"""
    talk = [(t, k, x) for t, k, x in items if k in ("user", "agent", "tool", "error")]
    kept, size = [], 0
    for item in reversed(talk):
        if budget is not None and kept and size + len(item[2]) > budget:
            break
        kept.append(item)
        size += len(item[2]) + 2
    kept.reverse()
    out = []
    for _, kind, text in kept:
        if out and kind in ("tool", "error") and out[-1][0] in ("tool", "error"):
            out[-1] = (kind, out[-1][1] + "\n" + text)  # calls in a row stay one block
        else:
            out.append((kind, text))
    return "\n\n".join(text for _, text in out), len(talk) - len(kept)


def session_doc(s, items, budget=None, heading=None, since=None):
    """One session as a document: who and where, where it ended, the files it changed, the
    problems it hit, Claude's summary of whatever is left out, and the conversation itself."""
    tool = APP_LABEL[app_of(s)]
    where = f"`{s['id']}`, {tool}" + (f", on {s['host']}" if is_remote(s) else "")
    head = [f"## {heading or name(s)}", f"- Session: {where}",
            f"- Folder: {s.get('cwd') or '?'}" + (f" (branch {s['branch']})" if s.get("branch") else ""),
            f"- Active: {when(s['first'])} to {when(s['last'])}, {hm((s.get('active') or 0) / 60)} of work"
            + (f", model {s['model']}" if s.get("model") else "")]
    parts = ["\n".join(head)]
    ends = [x for x in items if x[1] == "agent" and not x[2].startswith("**Subagent")]
    asks = [x for x in items if x[1] == "user"]
    if ends:
        last = ends[-1][2]
        if len(last) > 6000:
            last = last[:6000] + " …"
        parts.append("### Where it ended\n\n" + (asks[-1][2] + "\n\n" if asks else "") + last)
    files = list(dict.fromkeys(reversed([x[2] for x in items if x[1] == "files"])))
    if files:  # its own folder's first, as paths relative to it
        home = (s.get("cwd") or "").rstrip("/") + "/"
        files = ([p[len(home):] for p in files if p.startswith(home)] + [p for p in files if not p.startswith(home)])
        parts.append("### Files it changed (latest first)\n\n" + "\n".join(f"- {p}" for p in files[:40])
                     + (f"\n- … and {len(files) - 40} more" if len(files) > 40 else ""))
    times = [x[0] for x in items if x[0]]
    commits, changed = repo_changes(s.get("cwd"), min(times), max(times)) if times and not is_remote(s) else ([], [])
    if commits or changed:
        parts.append("### The repository while it worked\n\n(its shell commands included; so is anything else that "
                     "ran at the same time)\n\n"
                     + ("Commits:\n" + "\n".join(f"- {x}" for x in commits[:15]) + "\n\n" if commits else "")
                     + ("Files:\n" + "\n".join(f"- {x}" for x in changed[:40])
                        + (f"\n- … and {len(changed) - 40} more" if len(changed) > 40 else "") if changed else ""))
    errors = [x[2] for x in items if x[1] == "error"]
    if errors:
        parts.append("### Problems it hit (the latest)\n\n" + "\n".join(errors[-5:]))
    text, left_out = render_items(items, budget)
    summaries = [x for x in items if x[1] == "summary"]
    if left_out and summaries:
        parts.append("### Earlier, in Claude's own summary\n\n" + fit_block(summaries[-1][2], 20000))
    more = (f"s transcript {s['id']}" + (f" --since '{iso(since)}'" if since else "")
            + (f" (on {s['host']})" if is_remote(s) else ""))
    parts.append("### The conversation" + (f" (the latest part; {left_out} earlier entries: `{more} --all`)"
                                           if left_out else "") + "\n\n" + (text or "(nothing said)"))
    return "\n\n".join(parts)


def fit_block(text, n):
    return text if len(text) <= n else text[:n] + "\n\n…(cut)"


def git_out(cwd, *args, timeout=5):
    try:
        p = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout.rstrip() if p.returncode == 0 else None


def git_state(cwd, since=None):
    """The repository a session worked in, as it is now: branch, what is not committed, and the
    commits (since `since`, else the latest). None outside a git repository."""
    if not cwd or not os.path.isdir(cwd):
        return None
    root = git_out(cwd, "rev-parse", "--show-toplevel")
    if not root:
        return None
    branch = git_out(cwd, "rev-parse", "--abbrev-ref", "HEAD") or "?"
    lines = [f"- Repository {root}, branch {branch}"]
    counts = git_out(cwd, "rev-list", "--left-right", "--count", "@{upstream}...HEAD")
    if counts and len(counts.split()) == 2:
        behind, ahead = counts.split()
        if behind != "0" or ahead != "0":
            lines[0] += f" ({ahead} commits ahead of its upstream, {behind} behind)"
    status = (git_out(cwd, "status", "--short") or "").splitlines()
    if status:
        stat = git_out(cwd, "diff", "--shortstat", "HEAD") or ""
        lines.append(f"- Not committed: {len(status)} files" + (f" ({stat.strip()})" if stat else "") + "\n"
                     + "\n".join("    " + x for x in status[:30]) + ("\n    …" if len(status) > 30 else ""))
    else:
        lines.append("- Everything is committed")
    args = ["log", "--format=%h %ad %s", "--date=format:%b %d %H:%M", "-n", "20"]
    if since:
        args.append("--since=" + datetime.fromtimestamp(since).isoformat())
    log = git_out(cwd, *args)
    if log:
        lines.append(("- Commits since then:\n" if since else "- Latest commits:\n")
                     + "\n".join("    " + x for x in log.splitlines()))
    elif since:
        lines.append("- No commits since then")
    stashes = git_out(cwd, "stash", "list")
    if stashes:
        lines.append(f"- {len(stashes.splitlines())} stashed change sets (git stash list)")
    return "\n".join(lines)


def repo_changes(cwd, start, end):
    """What changed in cwd's repository while a session worked (start to end, unix times): the
    commits made then, on any branch, and the uncommitted files last written then. Its own shell
    commands show up here; so does anything else that ran at the same time. -> (commits, files),
    files relative to the repository, or ([], []) outside one."""
    root = git_out(cwd, "rev-parse", "--show-toplevel") if cwd and os.path.isdir(cwd) else None
    if not root or not start:
        return [], []
    end = (end or start) + 300
    log = git_out(root, "log", "--all", "--name-only", "--format=@@%h %ad %s", "--date=format:%b %d %H:%M",
                  "--since=" + datetime.fromtimestamp(start - 60).isoformat(),
                  "--until=" + datetime.fromtimestamp(end).isoformat()) or ""
    commits, files = [], []
    for line in log.splitlines():
        if line.startswith("@@"):
            commits.append(line[2:])
        elif line.strip():
            files.append(line.strip())
    for line in (git_out(root, "status", "--porcelain") or "").splitlines():
        path = line[3:].split(" -> ")[-1].strip('"')
        try:
            if start - 60 <= os.path.getmtime(os.path.join(root, path)) <= end:
                files.append(path)
        except OSError:
            pass
    return list(dict.fromkeys(commits)), list(dict.fromkeys(files))


def handoff_file(stem):
    os.makedirs(HANDOFF_DIR, exist_ok=True)
    return os.path.join(HANDOFF_DIR, stem + ".md")


def codex_handoff(s):
    """Write a Codex thread for Claude to read. -> path"""
    doc = ["# Handoff from Codex", session_doc(s, codex_items(s.get("rollout")), HANDOFF_MAX)]
    state = git_state(s.get("cwd"))
    if state:
        doc.append("## The working tree now\n\n" + state)
    path = handoff_file(s["id"])
    with open(path, "w") as f:
        f.write("\n\n".join(doc) + "\n")
    return path


def claude_handoff(s):
    """Write a Claude conversation too long to import for Codex to read: where it ended, what it
    changed, Claude's own summary of the earlier work and as much of the latest part as fits. -> path"""
    doc = ["# Handoff from Claude Code", session_doc(s, claude_items(s["path"]), HANDOFF_MAX)]
    state = git_state(s.get("cwd"))
    if state:
        doc.append("## The working tree now\n\n" + state)
    path = handoff_file(s["id"])
    with open(path, "w") as f:
        f.write("\n\n".join(doc) + "\n")
    return path


def handoff_prompt(path, source="codex", title=None):
    lead = f"Continuing \"{title}\". " if title else ""
    if source == "claude":
        return (f"{lead}I'm switching to you from a Claude Code session in this folder. It is too long to "
                f"import whole, so here is Claude's summary of the earlier work plus the most recent "
                f"part: {path}. Read it, then tell me in a few lines where that session left off and "
                f"what is still open. Don't start new work until I say so.")
    return (f"{lead}I'm switching to you from a Codex (GPT) session in this folder. Its transcript is at "
            f"{path}. Read it, then tell me in a few lines where that session left off and what is "
            f"still open. Don't start new work until I say so.")


CATCHUP_INLINE = 8000  # a catch-up this short goes straight into the prompt; a longer one is a file
CAUGHT_UP = os.path.join(CACHE_DIR, "caught-up.json")  # session id -> when it was last told the rest
# of its conversation (s writes it when it passes a catch-up on, ai-bridge when its start hook does)


def caught_up(sid):
    try:
        with open(CAUGHT_UP) as f:
            mark = json.load(f).get(sid)
    except (OSError, ValueError, AttributeError):
        return None
    return mark.get("through") if isinstance(mark, dict) else mark


def chain_watch(target):
    """The files of the other sessions of target's conversation on this machine: ai-bridge's
    per-message hook only asks again when one of them changed."""
    out = []
    for ref in target.get("chain") or []:
        m = SESSION_INDEX.get((target.get("host"), ref["id"]))
        if m and m["id"] != target["id"] and not is_remote(m):
            path = m.get("rollout") if app_of(m) == "codex" else m.get("path")
            if path:
                out.append(path)
    return out


def mark_caught_up(sid, through, watch=None):
    try:
        with open(CAUGHT_UP) as f:
            marks = json.load(f)
    except (OSError, ValueError):
        marks = {}
    old = marks.get(sid) if isinstance(marks.get(sid), dict) else {}
    marks[sid] = {"through": through, "watch": watch if watch is not None else old.get("watch", []),
                  "checked": time.time()}
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(CAUGHT_UP + ".tmp", "w") as f:
        json.dump(marks, f)
    os.replace(CAUGHT_UP + ".tmp", CAUGHT_UP)


def last_turn(s, live=False):
    """Unix time of a session's last real turn (a resume writes lines of its own first; `live`: its
    last reply, as the message being sent may be written already)."""
    if app_of(s) == "claude" and live and s.get("last_said"):
        return parse_ts(s["last_said"][0]).timestamp()
    if app_of(s) == "claude":
        times = [t for t in (s.get("last_prompt_ts"), (s.get("last_said") or [None])[0]) if t]
        if times:
            return max(parse_ts(t).timestamp() for t in times)
    return parse_ts(s.get("last_done") or s["last"]).timestamp()


def catchup(target, write=True, live=False):
    """What the rest of target's conversation did that target has not seen: every other session
    of it in either tool, each as a document (where it ended, what it changed, what went wrong,
    the conversation), oldest first, then the working tree now with the commits since.
    -> {"text", "path", "tools", "inline", "through"} or None. Not seen: since target was last
    caught up, else since its own last turn."""
    through = time.time()
    since = caught_up(target["id"]) or last_turn(target, live)
    sources = []
    for ref in target.get("chain") or []:
        m = SESSION_INDEX.get((target.get("host"), ref["id"]))
        if not m or m["id"] == target["id"] or parse_ts(m["last"]).timestamp() <= since + 1:
            continue
        items = session_items(m, since)
        if any(k in ("user", "agent") for _, k, _ in items):
            sources.append((min(t for t, _, _ in items), m, items))
    if not sources:
        return None
    sources.sort(key=lambda x: x[0])
    budget = max(15000, HANDOFF_MAX // len(sources))
    out = [f"# This conversation since {when(iso(since))}"]
    for _, m, items in sources:
        out.append(session_doc(m, items, budget, f"In {APP_LABEL[app_of(m)]}: {name(m)}", since))
    state = git_state(target.get("cwd"), since)
    if state:
        out.append("## The working tree now\n\n" + state)
    text = "\n\n".join(out) + "\n"
    latest = max((m for _, m, _ in sources), key=lambda m: m["last"])
    path = handoff_file(f"{datetime.now():%Y%m%d-%H%M}-{latest['id']}")  # named after a session it came from
    if write:
        with open(path, "w") as f:
            f.write(text)
    tools = []
    for _, m, _ in sources:
        label = (f"another {APP_LABEL[app_of(m)]} session" if app_of(m) == app_of(target)
                 else "Codex (GPT)" if app_of(m) == "codex" else "Claude Code")
        if label not in tools:
            tools.append(label)
    return {"text": text, "path": path, "tools": " and ".join(tools), "inline": len(text) <= CATCHUP_INLINE,
            "through": through}


def catchup_prompt(cu):
    """The first message of a resumed session that the rest of its conversation moved past."""
    if cu["inline"]:
        return (f"Since your last turn here, this conversation continued in {cu['tools']}. This is what "
                f"happened there:\n\n{cu['text']}\nTell me in a few lines where things stand now and what is "
                f"still open. Don't start new work until I say so.")
    return (f"Since your last turn here, this conversation continued in {cu['tools']}; what happened there "
            f"is in {cu['path']}. Read it, then tell me in a few lines where things stand now and what is "
            f"still open. Don't start new work until I say so.")


def catchup_context(cu, live=False):
    """The same for a session resumed some other way, as context ai-bridge's hooks add: as it
    starts, or (`live`) with the message the user is sending."""
    head = (f"Since your last reply in this session, the user continued this conversation in {cu['tools']}. "
            f"Take it into account: the message they are sending may build on it." if live else
            f"Since this session's last turn, the user continued this conversation in {cu['tools']}. "
            f"Take it into account: their next message may build on it.")
    if cu["inline"]:
        return head + "\n\n" + cu["text"]
    return head + f" What happened there is in {cu['path']}; read it before you answer their next message."


def read_claude(path):
    """One pass over a Claude transcript -> (estimated tokens of the conversation, Claude's latest
    compaction summary, the conversation as (unix time, short markdown) entries)."""
    chars, summary, entries = 0, None, []
    with open(path, errors="ignore") as f:
        for line in f:
            if '"type":"user"' not in line and '"type":"assistant"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") not in ("user", "assistant") or o.get("isSidechain"):
                continue
            ts = parse_ts(o.get("timestamp"))
            t = ts.timestamp() if ts else None
            content = (o.get("message") or {}).get("content")
            blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content or []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                kind = b.get("type")
                if kind == "text":
                    chars += len(b.get("text") or "")
                    if o.get("type") == "assistant" and (b.get("text") or "").strip():
                        entries.append((t, "**Claude:** " + b["text"].strip()))
                elif kind == "tool_use":
                    chars += len(json.dumps(b.get("input")))
                    entries.append((t, "- used " + f"{b.get('name')}: {tool_summary(b.get('name'), b.get('input') or {})}"))
                elif kind == "tool_result":
                    body = b.get("content")
                    chars += len(body if isinstance(body, str) else json.dumps(body))
            if o.get("type") == "user":
                if o.get("isCompactSummary"):
                    summary = claude_text_of(content)
                    continue
                if o.get("isMeta"):
                    continue
                txt = prompt_text(content)
                if txt:
                    entries.append((t, "**You:** " + txt))
    return chars // 4, summary, entries


def claude_text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


def codex_args():
    return shlex.split(env("CODEX_ARGS") or "")


# ----------------------------------------------------------------- conversations across tools

def link_sessions(sessions):
    """Mark this machine's sessions that continue one another across Claude Code and Codex:
    each gets `group` (shared key) and `chain` (all of them, oldest first)."""
    by_id = {s["id"]: s for s in sessions}
    parent = {}

    def root(x):
        while parent.get(x, x) != x:
            x = parent[x]
        return x

    def join(a, b):
        if a in by_id and b in by_id and root(a) != root(b):
            parent[root(a)] = root(b)

    try:  # Codex's own record of the Claude transcripts it imported (s --codex, /codex:transfer)
        with open(os.path.join(CODEX_HOME, "external_agent_session_imports.json")) as f:
            records = json.load(f).get("records") or []
    except (OSError, ValueError):
        records = []
    for r in records:
        src = os.path.basename(r.get("source_path") or "")
        if src.endswith(".jsonl"):
            join(src[:-6], r.get("imported_thread_id"))
    for s in sessions:
        for other in s.get("links") or []:
            join(s["id"], other)
    groups = {}
    for s in sessions:
        groups.setdefault(root(s["id"]), []).append(s)
    for members in groups.values():
        if len(members) < 2:
            continue
        members.sort(key=lambda m: m["last"])
        chain = [{"id": m["id"], "app": app_of(m), "last": m["last"], "name": name(m),
                  "broken": m.get("broken")} for m in members]
        for m in members:
            m["group"], m["chain"] = members[0]["id"], chain


def merge_rows(sessions):
    """One row per conversation: sessions continued across tools become one row that carries
    the latest session (so resuming it picks up where you worked last) and their combined work."""
    rows, groups = [], {}
    for s in sessions:
        if s.get("group"):
            groups.setdefault((s.get("host"), s["group"]), []).append(s)
        else:
            rows.append(s)
    for members in groups.values():
        usable = [m for m in members if not m.get("broken")] or members  # skip a thread Codex can't run
        latest = max(usable, key=lambda m: m["last"])
        first = min(members, key=lambda m: m.get("first") or m["last"])
        days = {}
        for m in members:
            for d, v in (m.get("days") or {}).items():
                days[d] = days.get(d, 0) + v
        row = dict(latest)
        row.update(usage=merge_usage(*(m.get("usage") for m in members)))
        row.update(days=days, active=sum(m.get("active") or 0 for m in members),
                   user=sum(m.get("user") or 0 for m in members), first=first.get("first"),
                   first_prompts=first.get("first_prompts") or [],
                   last_prompts=((latest.get("first_prompts") or []) + (latest.get("last_prompts") or []))[-4:],
                   ai_title=first.get("ai_title"),
                   custom_title=next((m["custom_title"] for m in sorted(members, key=lambda m: m["last"],
                                                                         reverse=True)
                                      if m.get("custom_title")), None))
        rows.append(row)
    return rows


# ----------------------------------------------------------------- deep search

PROMPT_INDEX = os.path.join(CACHE_DIR, "prompts.json")
PROMPT_INDEX_VERSION = 2
PROMPT_KEEP = 4000  # characters kept of each prompt
CODEX_PROMPT_LINES = (b'"UserMessage"', b'"user_message"', b'"task_started"', b'"item_completed"')


def index_claude(path, e):
    """Add the prompts you wrote into a Claude transcript since e's offset."""
    with open(path, "rb") as f:
        f.seek(e["offset"])
        data = f.read()
    end = data.rfind(b"\n")
    if end < 0:
        return
    e["offset"] += end + 1
    for line in data[:end].split(b"\n"):
        if b'"user"' not in line:  # cheap test before parsing; the type is checked below
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("type") != "user" or o.get("isMeta") or o.get("isCompactSummary") or o.get("isSidechain"):
            continue
        txt, ts = prompt_text((o.get("message") or {}).get("content")), parse_ts(o.get("timestamp"))
        if txt and ts:
            e["prompts"].append([ts.timestamp(), txt[:PROMPT_KEEP]])


def index_codex(path, e):
    """Add the prompts you wrote into a Codex session file since e's offset (a compressed file
    is read whole)."""
    if path.endswith(".zst"):
        data, e["offset"], e["prompts"] = (read_rollout(path[:-4]) or "").encode(), 0, []
    else:
        with open(path, "rb") as f:
            f.seek(e["offset"])
            data = f.read()
    end = data.rfind(b"\n")
    if end < 0:
        return
    if not path.endswith(".zst"):
        e["offset"] += end + 1
    lines = [ln for ln in data[:end + 1].split(b"\n") if any(k in ln for k in CODEX_PROMPT_LINES)]
    text = b"\n".join(lines).decode("utf-8", "ignore")
    e["items"] = e.get("items") or '"item_completed"' in text
    for kind, t, v in codex_events(text, e["items"]):
        txt = clean_part(v or "") if kind == "user" else None
        if txt and t:
            e["prompts"].append([t, txt[:PROMPT_KEEP]])


def prompt_index():
    """{"files": {path: {app, id, size, mtime, offset, prompts: [[unix time, text]]}}}: every prompt
    you wrote in every Claude Code and Codex session on this machine, however old. Kept in
    ~/.cache/sessions/prompts.json and brought up to date from where each file was last read."""
    try:
        with open(PROMPT_INDEX) as f:
            index = json.load(f)
    except (OSError, ValueError):
        index = {}
    if index.get("__version__") != PROMPT_INDEX_VERSION:
        index = {"__version__": PROMPT_INDEX_VERSION, "files": {}}
    files, seen, dirty = index["files"], set(), False
    todo = []
    if os.path.isdir(PROJECTS):
        for proj in os.scandir(PROJECTS):
            if proj.is_dir():
                for ent in os.scandir(proj.path):
                    if ent.name.endswith(".jsonl") and not ent.name.startswith("agent-"):
                        todo.append((ent.path, "claude", ent.name[:-6]))
    try:
        db = codex_db()
    except sqlite3.Error:
        db = None
    if db is not None:
        try:
            for r in db.execute("select id, rollout_path, source from threads"):
                src = r["source"] or ""
                path = rollout_file(r["rollout_path"])
                if path and not src.startswith("{") and src != "exec":
                    todo.append((path, "codex", r["id"]))
        except sqlite3.Error:
            pass
        finally:
            db.close()
    for path, app, sid in todo:
        seen.add(path)
        try:
            st = os.stat(path)
            e = files.get(path)
            if e and e["size"] == st.st_size and e["mtime"] == st.st_mtime:
                continue
            if not e or st.st_size < e["size"]:
                e = files[path] = {"app": app, "id": sid, "offset": 0, "prompts": []}
            (index_claude if app == "claude" else index_codex)(path, e)
            e["size"], e["mtime"] = st.st_size, st.st_mtime
            dirty = True
        except OSError:  # gone while being read
            continue
    for path in [p for p in files if p not in seen]:
        del files[path]
        dirty = True
    if dirty:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = PROMPT_INDEX + ".tmp"
        with open(tmp, "w") as f:
            json.dump(index, f)
        os.replace(tmp, PROMPT_INDEX)
    return index


def deep_search(words):
    """-> ({session id: [(unix time, prompt)]}, Claude transcript paths, Codex thread ids) for every
    prompt here that has all of `words` (any case)."""
    hits, paths, threads = {}, set(), set()
    for path, e in prompt_index()["files"].items():
        for t, txt in e["prompts"]:
            low = txt.lower()
            if all(w in low for w in words):
                hits.setdefault(e["id"], []).append((t, txt))
                (paths if e["app"] == "claude" else threads).add(path if e["app"] == "claude" else e["id"])
    return hits, paths, threads


def match_snippet(text, words):
    low = text.lower()
    at = min([i for i in (low.find(w) for w in words) if i >= 0] or [0])
    start = max(0, at - 12)
    return ("…" if start else "") + text[start:]


def matched_rows(sessions, hits, words):
    """The conversations (one row each, as in the list) that have a prompt matching, each with the
    most recent matching prompt as `match`."""
    out = []
    for r in merge_rows(sessions):
        ids = [m["id"] for m in r.get("chain") or []] or [r["id"]]
        found = sorted(h for i in ids for h in hits.get(i, []))
        if found:
            t, text = found[-1]
            out.append(dict(r, match=match_snippet(text, words), match_ts=iso(t), matches=len(found),
                            active_win=(r.get("active") or 0) / 60))
    return out


def remote_search(hosts, query, timeout=180):
    """[(label, rows, note)]: every host searches its own sessions."""
    procs = {}
    for label, dest in hosts.items():
        argv = ["ssh", *SSH_OPTS, dest, f"{REMOTE_S} search --json --local -- {shlex.quote(query)}"]
        try:
            procs[label] = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, text=True)
        except OSError:
            procs[label] = None
    out = []
    for label, p in procs.items():
        if p is None:
            out.append((label, [], "ssh failed"))
            continue
        try:
            stdout, stderr = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            out.append((label, [], "took too long to search"))
            continue
        try:
            answer = json.loads(stdout)
            if any(o.get("match") is None for o in answer):  # an older s there lists instead of searching
                out.append((label, [], f"its s cannot search yet (run: s hosts setup {label})"))
            else:
                out.append((label, [from_json(o, label) for o in answer], None))
        except ValueError:
            err = (stderr.strip().splitlines() or ["no answer"])[-1]
            out.append((label, [], f"could not search there ({err}; run: s hosts setup {label})"))
    return out


def highlight(text, words):
    if not TTY or not words:
        return text
    return re.sub("|".join(re.escape(w) for w in sorted(words, key=len, reverse=True)),
                  lambda m: c("1;33", m.group(0)), text, flags=re.I)


# ----------------------------------------------------------------- details on demand, repo handoffs

def parse_when(text):
    """'2026-10-27 14:30', an ISO time, or how long ago ('3h', '2d') -> unix time."""
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([mhd])", text.strip())
    if m:
        return time.time() - float(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)]
    ts = parse_ts(text.strip().replace(" ", "T"))
    if ts is None:
        sys.exit(f"cannot read the time '{text}' (try 2026-10-27 14:30, or 3h / 2d ago)")
    if ts.tzinfo is None:
        ts = ts.astimezone()
    return ts.timestamp()


def grep_items(items, words):
    """The entries that have every word, each with the entry before and after it."""
    talk = [x for x in items if x[1] in ("user", "agent", "tool", "error")]
    hit = {i for i, x in enumerate(talk) if all(w in x[2].lower() for w in words)}
    keep = {j for i in hit for j in (i - 1, i, i + 1) if 0 <= j < len(talk)}
    return [x for i, x in enumerate(talk) if i in keep]


def transcript_cmd(s, a, words):
    """`s transcript`: one session as a document, to read any part of it on demand."""
    if is_remote(s):
        args = ["transcript", s["id"], "--local"] + (["--all"] if a.all else [])
        args += (["--grep", a.grep] if a.grep else []) + (["--since", a.since] if a.since else [])
        dest = HOSTS.get(s["host"], s["host"])
        sys.exit(subprocess.run(["ssh", *SSH_OPTS, dest, f"{REMOTE_S} {shlex.join(args)}"]).returncode)
    since = parse_when(a.since) if a.since else None
    items = session_items(s, since)
    if words:
        items = grep_items(items, words)
    print(session_doc(s, items, None if a.all or words else HANDOFF_MAX, since=since))
    state = git_state(s.get("cwd"))
    if state and not words:
        print("\n## The working tree now\n\n" + state)


def repo_root(path):
    path = os.path.realpath(os.path.expanduser(path))
    return git_out(path, "rev-parse", "--show-toplevel") or path


def worktrees(root):
    out = git_out(root, "worktree", "list", "--porcelain") or ""
    return [ln[9:] for ln in out.splitlines() if ln.startswith("worktree ") and ln[9:] != root]


def under(path, roots):
    """Is path one of roots or inside one (as written, or with symlinks resolved, /tmp being /private/tmp)?"""
    if not path:
        return False
    paths = {path, os.path.realpath(path)}
    return any(p == r or p.startswith(r.rstrip("/") + "/") for p in paths for r in roots)


def repo_handoff(root, sessions, detailed=10):
    """A handoff for a new session about everything done in a repository: the state it is in,
    every conversation about it in either tool on every machine (what it set out to do, where
    it ended, what it changed, what went wrong), the latest one in detail, what Claude remembers
    about the project, and the commands that pull any detail on demand. -> (path, rows)"""
    roots = list(dict.fromkeys([root, os.path.realpath(root)] + worktrees(root)))
    mine = [s for s in sessions if under(s.get("cwd"), roots)]
    rows = sorted(merge_rows(mine), key=lambda r: r["last"], reverse=True)
    by_key = {(s.get("host"), s["id"]): s for s in mine}
    hours = sum(r.get("active") or 0 for r in rows) / 3600
    tools = sorted({app_of(m) for m in mine})
    doc = [f"# Handoff: {os.path.basename(root)}",
           f"Everything done in {root} so far: {len(rows)} conversations, {hours:.0f} hours of work, in "
           + " and ".join(APP_LABEL[t] for t in tools) + (", on " + ", ".join(sorted({r['host'] for r in rows
                                                                                         if r.get('host')}))
                                                             + " and this machine" if any(r.get("host") for r in rows)
                                                             else "")
           + f". Written {datetime.now():%Y-%m-%d %H:%M}. This is the overview: the end of this file says "
             "how to read any session in full."]
    state = git_state(root)
    if state:
        branches = git_out(root, "for-each-ref", "--sort=-committerdate", "--count=8",
                           "--format=    %(refname:short)  %(committerdate:relative)  %(subject)", "refs/heads")
        trees = worktrees(root)
        prs = None
        if shutil.which("gh") and "github.com" in (git_out(root, "remote", "get-url", "origin") or ""):
            try:
                p = subprocess.run(["gh", "pr", "list", "--state", "open", "--limit", "10", "--json",
                                    "number,title,headRefName"], cwd=root, capture_output=True, text=True, timeout=10)
                prs = json.loads(p.stdout) if p.returncode == 0 else None
            except (OSError, ValueError, subprocess.TimeoutExpired):
                prs = None
        doc.append("## The repository now\n\n" + state
                   + (f"\n- Branches, latest first:\n{branches}" if branches else "")
                   + (f"\n- Other worktrees: {', '.join(trees)}" if trees else "")
                   + ("\n- Open pull requests:\n" + "\n".join(f"    #{p['number']} {p['title']} ({p['headRefName']})"
                                                             for p in prs) if prs else ""))
    mem = os.path.join(PROJECTS, encode_path(root), "memory", "MEMORY.md")
    if os.path.isfile(mem):
        with open(mem, errors="ignore") as f:
            index = "".join(f.readlines()[:200]).strip()
        if index:
            doc.append(f"## What Claude remembers about this project\n\nThe index of {os.path.dirname(mem)}/ "
                       f"(read a file there for the whole memory):\n\n{index}")
    over = ["## The conversations, latest first"]
    for n, r in enumerate(rows, 1):
        members = [by_key.get((r.get("host"), c["id"])) or r for c in (r.get("chain") or [{"id": r["id"]}])]
        items = []
        if n <= detailed:
            for m in members:
                items += session_items(m)
        apps = " → ".join(dict.fromkeys(APP_LABEL[app_of(m)] for m in members))
        lines = [f"### {n}. {name(r)}",
                 f"- {when(r['first'])} to {when(r['last'])}, {hm((r.get('active') or 0) / 60)} of work, "
                 f"{r.get('user') or 0} prompts, in {apps}" + (f", on {r['host']}" if r.get("host") else ""),
                 "- Sessions: " + ", ".join(f"`{m['id']}` ({APP_LABEL[app_of(m)]})" for m in members)]
        if r.get("first_prompts"):
            lines.append("- Set out to: " + fit(r["first_prompts"][0][1], 400))
        if last_prompt(r) and r.get("user", 0) > 1:
            lines.append("- Last asked: " + fit(last_prompt(r), 300))
        ends = [x[2] for x in items if x[1] == "agent" and not x[2].startswith("**Subagent")]
        if ends:
            lines.append("- Ended with: " + fit(WS_RE.sub(" ", ends[-1].split(":** ", 1)[-1]), 1200))
        elif r.get("last_said"):
            lines.append("- Ended with: " + r["last_said"][1])
        files = list(dict.fromkeys(reversed([x[2] for x in items if x[1] == "files"])))
        times = [x[0] for x in items if x[0]]
        if times:  # what its shell commands changed shows up in the repository
            files += [os.path.join(root, p) for p in repo_changes(root, min(times), max(times))[1]]
            files = list(dict.fromkeys(files))
        inside = list(dict.fromkeys(os.path.relpath(p, t) for p in files for t in roots if under(p, [t])))[:200]
        if inside:
            outside = len(files) - len(inside)
            lines.append("- Changed: " + ", ".join(inside[:12]) + (f" and {len(inside) - 12} more" if len(inside) > 12 else "")
                         + (f" (and {outside} files outside the repository)" if outside > 0 else ""))
        errors = [x[2] for x in items if x[1] == "error"]
        if errors:
            lines.append("- Last problem: " + fit(errors[-1].lstrip("- "), 300))
        if r.get("todo") and r["todo"].get("done", 0) < r["todo"].get("total", 0):
            td = r["todo"]
            lines.append(f"- Checklist: {td['done']} of {td['total']} done" + (f", on: {td['current']}" if td.get("current") else ""))
        if r.get("broken"):
            lines.append(f"- Note: its Codex thread is {r['broken']}")
        over.append("\n".join(lines))
    doc.append("\n\n".join(over))
    if rows:
        latest = rows[0]
        if is_remote(latest):
            dest = HOSTS.get(latest["host"], latest["host"])
            p = subprocess.run(["ssh", *SSH_OPTS, dest, f"{REMOTE_S} transcript {latest['id']} --local"],
                               capture_output=True, text=True, timeout=120)
            detail = p.stdout.strip() if p.returncode == 0 else None
        else:
            detail = session_doc(latest, session_items(latest), 40000)
        if detail:
            doc.append("# The latest conversation in detail\n\n" + detail.replace("\n## ", "\n### ", 1))
    doc.append("## Details on demand\n\n"
               "Read any of these when a detail matters, instead of guessing:\n\n"
               "- `s transcript <session id>`: a session as a document (where it ended, files it changed, "
               "problems, the latest part of the conversation); add `--all` for all of it, `--grep WORDS` "
               "for just the parts about something, `--since 2d` for the recent part. Works for sessions "
               "on the other machine too.\n"
               "- `s search WORDS`: every prompt about something, in every session.\n"
               "- `git log -p -- PATH`, `git show COMMIT`, `git diff`: what actually changed.")
    path = handoff_file(f"repo-{re.sub(r'[^A-Za-z0-9_.-]', '_', os.path.basename(root))}-{datetime.now():%Y%m%d-%H%M}")
    with open(path, "w") as f:
        f.write("\n\n".join(doc) + "\n")
    return path, rows


def repo_prompt(path, rows):
    hours = sum(r.get("active") or 0 for r in rows) / 3600
    return (f"Here is a handoff of the work on this repository so far ({len(rows)} conversation"
            f"{'' if len(rows) == 1 else 's'} in Claude Code and Codex, {hours:.1f} hours of work): {path}. Read it. It is an overview, with the latest "
            f"conversation in more detail, and its last section has the commands that pull any part of any "
            f"session when you need a detail. Then tell me in a few lines what this repository is, what was "
            f"being worked on, where it stands now, and what looks unfinished or fragile. Don't start new "
            f"work until I say so.")


# ----------------------------------------------------------------- live state

_RUNNING = None


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def tmux_panes():
    """pane shell pid -> tmux target, so a session inside tmux can be attached to."""
    if not shutil.which("tmux"):
        return {}
    try:
        out = subprocess.run(["tmux", "list-panes", "-a", "-F",
                              "#{pane_pid}\t#{session_name}:#{window_index}.#{pane_index}"],
                             capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    panes = {}
    for line in out.splitlines():
        pid, _, target = line.partition("\t")
        if pid.isdigit():
            panes[int(pid)] = target
    return panes


def parent_pid(pid):
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=3).stdout.strip()
        return int(out) if out else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def tmux_target(pid, panes):
    """The tmux window a process lives in, found by walking up its parents."""
    for _ in range(25):
        if not pid or pid <= 1:
            return None
        if pid in panes:
            return panes[pid]
        pid = parent_pid(pid)
    return None


def running():
    """sessionId -> info for Claude Code processes that are alive on this machine right now."""
    global _RUNNING
    if _RUNNING is not None:
        return _RUNNING
    out = {}
    for f in glob.glob(os.path.join(CLAUDE_DIR, "sessions", "*.json")):
        try:
            with open(f) as fh:
                o = json.load(fh)
        except (ValueError, OSError):
            continue
        if o.get("sessionId") and pid_alive(o.get("pid")):
            out[o["sessionId"]] = {"status": o.get("status") or "?", "name": o.get("name"),
                                   "updated": o.get("updatedAt"), "pid": o.get("pid"), "backend": "cli"}
    roster = os.path.join(CLAUDE_DIR, "daemon", "roster.json")
    if os.path.exists(roster):
        try:
            with open(roster) as fh:
                workers = (json.load(fh).get("workers") or {}).values()
        except (ValueError, OSError):
            workers = []
        for w in workers:
            sid = w.get("sessionId")
            if sid and sid not in out and pid_alive(w.get("pid")):
                out[sid] = {"status": "?", "name": None, "updated": None, "pid": w.get("pid"), "backend": "daemon"}
    panes = tmux_panes() if out else {}
    for info in out.values():
        info["tmux"] = tmux_target(info["pid"], panes) if panes else None
    _RUNNING = out
    return out


def daemon_state(sid):
    """State written by daemon-managed sessions (Remote Control, background workers)."""
    p = os.path.join(CLAUDE_DIR, "jobs", sid[:8], "state.json")
    if not os.path.exists(p):
        return None
    try:
        with open(p) as fh:
            o = json.load(fh)
    except (ValueError, OSError):
        return None
    return o if o.get("sessionId", sid) == sid else None


def is_remote(s):
    return bool(s.get("host"))


def running_of(s):
    return s.get("_running") if is_remote(s) else running().get(s["id"])


def daemon_of(s):
    return s.get("_daemon") if is_remote(s) else daemon_state(s["id"])


def doing(s):
    """The tool call still waiting for a result, if any."""
    if is_remote(s):
        return s.get("_doing")
    if not s.get("open_tools"):
        return None
    ts, nm, summary = list(s["open_tools"].values())[-1]
    return f"{nm}: {summary}" if summary else nm


# ----------------------------------------------------------------- cron jobs

def cron_field(spec, lo, hi):
    vals = set()
    for part in spec.split(","):
        step = 1
        if "/" in part:
            part, step = part.split("/", 1)
            step = int(step)
        if part == "*":
            rng = range(lo, hi + 1)
        elif "-" in part:
            a, b = part.split("-", 1)
            rng = range(int(a), int(b) + 1)
        else:
            v = int(part)
            rng = range(v, hi + 1) if step > 1 else range(v, v + 1)
        vals.update(range(rng.start, rng.stop, step))
    return vals


def cron_fires(expr, start, end):
    """How many times a 5-field cron matches in (start, end]; None if unparsable."""
    try:
        m, h, dom, mon, dow = expr.split()
        mins, hours = cron_field(m, 0, 59), cron_field(h, 0, 23)
        doms, mons = cron_field(dom, 1, 31), cron_field(mon, 1, 12)
        dows = {x % 7 for x in cron_field(dow, 0, 7)}
    except (ValueError, AttributeError):
        return None
    n, day = 0, start.date()
    while day <= end.date():
        dmatch, wmatch = day.day in doms, (day.weekday() + 1) % 7 in dows
        if dom != "*" and dow != "*":
            ok = dmatch or wmatch
        else:
            ok = (dmatch if dom != "*" else True) and (wmatch if dow != "*" else True)
        if ok and day.month in mons:
            for hh in hours:
                for mm in mins:
                    t = datetime.combine(day, dtime(hh, mm), tzinfo=start.tzinfo)
                    if start < t <= end:
                        n += 1
        day += timedelta(days=1)
    return n


def job_status(j, alive, session_last):
    """-> (status, fires_text, expiry). Status: live, waiting, done, dead, expired, cancelled."""
    now = datetime.now().astimezone()
    fires = len(j["fires"])
    if not j.get("created"):  # fired here, but created in a transcript we have not seen
        return ("fired" if fires else "?"), (str(fires) if fires else ""), None
    if j.get("error"):
        return "failed", "", None
    created = parse_ts(j["created"]).astimezone()
    if not j.get("recurring", True):
        if j.get("deleted"):
            return "cancelled", "", None
        if fires:
            return "done", "", None
        return ("waiting" if alive else "dead"), "", None
    expiry = created + CRON_LIFETIME
    total = cron_fires(j["cron"], created, expiry) if j.get("cron") else None
    text = f"{fires}/{total} ({100 * fires // total}%)" if total else str(fires)
    if j.get("deleted"):
        status = "cancelled"
    elif alive and now < expiry:
        status = "live"
    elif not alive and (session_last is None or session_last < expiry):
        status = "dead"
    else:
        status = "expired"
    return status, text, expiry


STATUS_COLOR = {"live": "32", "waiting": "33", "done": "", "fired": "", "dead": "2", "expired": "2",
                "cancelled": "2", "failed": "31", "?": "2"}

_JOB_INDEX = None
_ALL_SESSIONS = []
SESSION_INDEX = {}  # (host, id) -> session, every machine's
SEARCH_WORDS = []  # what `s search` / `?text` looked for, to highlight


def job_index():
    """Local jobs merged across sessions by id: a continued session splits one job over transcripts."""
    global _JOB_INDEX
    if _JOB_INDEX is not None:
        return _JOB_INDEX
    idx = {}
    for s in _ALL_SESSIONS:
        for jid, j in s["jobs"].items():
            m = idx.setdefault(jid, dict(job_stub(jid), sessions=[]))
            m["sessions"].append(s)
            for k in ("cron", "prompt", "created", "human", "deleted", "error"):
                if j.get(k) and not m.get(k):
                    m[k] = j[k]
            if j.get("created"):
                m["recurring"] = j.get("recurring", True)
            m["fires"] = sorted(set(m["fires"]) | set(j["fires"]))
    _JOB_INDEX = idx
    return idx


def job_home(m):
    """The session a merged job belongs to now: the most recently active one that saw it."""
    return max(m["sessions"], key=lambda s: s["last"])


def merged_status(m):
    home = job_home(m)
    last = parse_ts(home["last"])
    return job_status(m, home["id"] in running(), last.astimezone() if last else None)


def session_jobs(s):
    """[(job, status, fires_text, expiry)] for a session's jobs, newest first."""
    if is_remote(s):
        return s["_jobs"]
    out = []
    for jid in s["jobs"]:
        m = job_index().get(jid)
        if m is None:
            m = dict(s["jobs"][jid], sessions=[s])
        status, text, expiry = merged_status(m)
        out.append((m, status, text, expiry))
    out.sort(key=lambda r: r[0].get("created") or (r[0]["fires"][0] if r[0]["fires"] else ""), reverse=True)
    return out


def once_text(j):
    """A one-shot's cron 'M H D Mo *' rendered as a date."""
    m = re.fullmatch(r"(\d+) (\d+) (\d+) (\d+) \*", (j.get("cron") or "").strip())
    if m:
        mi, hh, dd, mo = map(int, m.groups())
        year = parse_ts(j["created"]).astimezone().year if j.get("created") else datetime.now().year
        try:
            return datetime(year, mo, dd, hh, mi).strftime("%b %d %H:%M")
        except ValueError:
            pass
    return j.get("human") or j.get("cron") or "?"


def job_line(j, status, text, expiry):
    sched = j.get("human") or j.get("cron") or "?"
    if not j.get("created"):
        parts = ["? schedule unknown"]
    elif j.get("recurring", True):
        parts = ["↻ " + sched]
    else:
        parts = ["◦ once " + once_text(j)]
    if j.get("recurring", True) and text:
        parts.append("fires " + text)
    if j["fires"]:
        parts.append("last " + when(j["fires"][-1]))
    parts.append(c("1;" + STATUS_COLOR[status] if STATUS_COLOR[status] else "1", status))
    if status == "live" and expiry:
        parts.append("expires " + when(expiry.isoformat()))
    if status == "dead":
        parts.append("session closed")
    if j.get("error"):
        parts.append(c("33", "create failed"))
    return " · ".join(parts)


# ----------------------------------------------------------------- remote hosts

def load_hosts(extra=None):
    """label -> ssh destination, from ~/.config/s/hosts plus any --host values."""
    hosts = {}
    if os.path.exists(HOSTS_FILE):
        with open(HOSTS_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                hosts[parts[0]] = parts[1] if len(parts) > 1 else parts[0]
    for h in extra or []:
        label, _, dest = h.partition("=")
        hosts[label] = dest or label
    return hosts


def save_hosts(hosts):
    os.makedirs(os.path.dirname(HOSTS_FILE), exist_ok=True)
    with open(HOSTS_FILE, "w") as f:
        f.write("# label  ssh-destination   (s lists and resumes sessions on these hosts over ssh)\n")
        for label, dest in hosts.items():
            f.write(f"{label} {dest}\n")


def ssh(dest, command, timeout=40, tty=False):
    cmd = ["ssh", *([] if tty else SSH_OPTS), *(["-t"] if tty else []), dest, command]
    return subprocess.run(cmd, capture_output=not tty, text=True, timeout=timeout)


def from_json(o, host):
    """A session dict built from another machine's `s --json` output."""
    s = dict(o)
    s["host"] = host
    for k, v in (("project_dir", ""), ("open_tools", {}), ("todo", None), ("last_said", None),
                 ("ctx_tokens", 0), ("last_prompt_ts", None), ("branch", None), ("model", None),
                 ("app", "claude"), ("group", None), ("chain", None), ("broken", None),
                 ("usage", None)):
        s.setdefault(k, v)
    s["_running"] = o.get("running")
    s["_daemon"] = o.get("daemon")
    s["_doing"] = o.get("doing")
    jobs = o.get("jobs") or []
    s["_jobs"] = [(j, j.get("status", "?"), j.get("fires_text", ""),
                   parse_ts(j["expires"]) if j.get("expires") else None) for j in jobs]
    s["jobs"] = {j["id"]: j for j in jobs}
    return s


def remote_base(label, days):
    return os.path.join(CACHE_DIR, "remote", re.sub(r"[^A-Za-z0-9_.-]", "_", label) + f"-d{int(days)}")


def start_remote(hosts, days):
    """Ask every host for its sessions in the background. Each answer lands in the cache as a
    whole file, even if this run has moved on, so a slow host is current again next time."""
    os.makedirs(os.path.join(CACHE_DIR, "remote"), exist_ok=True)
    script = 'ssh "$@" > "$0.tmp" 2> "$0.err" && mv "$0.tmp" "$0.json"'
    procs = {}
    for label, dest in hosts.items():
        base = remote_base(label, days)
        argv = ["sh", "-c", script, base, *SSH_OPTS, dest, f"{REMOTE_S} --json --local -a -d {int(days)}"]
        try:
            procs[label] = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            procs[label] = None
    return {"procs": procs, "days": days, "started": time.monotonic()}


def cached_remote(hosts, days):
    """Every host's last answer, without asking again."""
    out = []
    for label in hosts:
        try:
            with open(remote_base(label, days) + ".json") as f:
                out += [from_json(o, label) for o in json.load(f)]
        except (OSError, ValueError):
            pass
    return out


def finish_remote(pending, wait=REMOTE_WAIT):
    """[(label, sessions, note)]: fresh answers from hosts that replied within `wait` seconds,
    the last answer from the others."""
    deadline = pending["started"] + wait
    for p in pending["procs"].values():
        if p is not None:
            try:
                p.wait(timeout=max(0.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
    out = []
    for label, p in pending["procs"].items():
        base = remote_base(label, pending["days"])
        code = p.poll() if p is not None else 255
        note = None
        if code not in (0, None):
            try:
                with open(base + ".err") as f:
                    err = (f.read().strip().splitlines() or ["ssh failed"])[-1]
            except OSError:
                err = "ssh failed"
            note = f"sessions is not installed there, run: s hosts setup {label}" if "not found" in err else err
        sessions, asof = [], None
        try:
            with open(base + ".json") as f:
                sessions = [from_json(o, label) for o in json.load(f)]
            asof = rel(iso(os.path.getmtime(base + ".json")))
        except (OSError, ValueError):
            if code == 0:
                note = f"unexpected output, run: s hosts setup {label}"
        stale = code != 0 and sessions
        if code is None:
            note = (f"slow to answer, showing its sessions as of {asof}" if stale
                    else "slow to answer, skipped this time (refreshing in the background)")
        elif note and stale:
            note += f"; showing its sessions as of {asof}"
        out.append((label, sessions, note))
    return out


def host_check(dest):
    try:
        p = ssh(dest, f"{REMOTE_S} --version 2>/dev/null || echo 'sessions missing'; "
                      "if command -v tmux >/dev/null 2>&1 || [ -x /opt/homebrew/bin/tmux ]; "
                      "then echo tmux; else echo 'no tmux'; fi", timeout=15)
    except (subprocess.TimeoutExpired, OSError) as e:
        return False, f"unreachable ({e.__class__.__name__})"
    if p.returncode != 0:
        return False, "unreachable: " + (p.stderr.strip().splitlines() or ["ssh failed"])[-1]
    return True, " · ".join(p.stdout.split())


def hosts_setup(label, dest):
    """Copy this script to the host so it can answer `s --json` and resume sessions."""
    me = os.path.realpath(__file__)
    bridge = os.path.join(os.path.dirname(me), "ai-bridge")
    has_bridge = os.path.exists(bridge)
    print(f"copying sessions {VERSION}{' and ai-bridge' if has_bridge else ''} to {label} ({dest}) ...")
    try:
        ssh(dest, "mkdir -p ~/.local/bin", timeout=20)
        subprocess.run(["scp", "-q", *SSH_OPTS, me, f"{dest}:.local/bin/s"], check=True, timeout=60)
        if has_bridge:
            subprocess.run(["scp", "-q", *SSH_OPTS, bridge, f"{dest}:.local/bin/ai-bridge"], check=True, timeout=60)
            # refresh its hooks there when the bridge is already set up; never set it up unasked
            p = ssh(dest, 'chmod +x ~/.local/bin/ai-bridge; export PATH="$HOME/.local/bin:/opt/homebrew/bin:'
                          '/usr/local/bin:$PATH"; if grep -q ai-bridge ~/.codex/hooks.json 2>/dev/null; then '
                          'ai-bridge setup >/dev/null && echo "ai-bridge: $(ai-bridge --version), setup refreshed"; '
                          'else echo "ai-bridge: copied; run ai-bridge setup there to share memory with Codex"; fi',
                    timeout=60)
            print((p.stdout or "") + (p.stderr or ""), end="")
            p = ssh(dest, f"{REMOTE_S} _plugins", timeout=600)  # plugins the synced settings turn on
            try:
                for plugin, outcome in json.loads(p.stdout or "[]"):
                    print(f"plugin {plugin}: {outcome}")
            except ValueError:
                pass
            # MCP servers that sign in there (each machine keeps its own sign-ins)
            p = ssh(dest, 'export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; '
                          'grep -q ai-bridge ~/.codex/hooks.json 2>/dev/null && ai-bridge mcp-login --check', timeout=240)
            if p.returncode == 1 and p.stdout.strip():
                print("\n".join("mcp: " + ln for ln in p.stdout.strip().splitlines() if not ln.startswith("Checking"))
                      + f"\n     to sign in there: ssh -t {dest} .local/bin/ai-bridge mcp-login")
        p = ssh(dest, "chmod +x ~/.local/bin/s && ~/.local/bin/s --version && "
                      "(nohup ~/.local/bin/s --local -a -p >/dev/null 2>&1 &) && "  # the first long read, now
                      "(command -v python3 >/dev/null 2>&1 || echo 'warning: python3 missing there') && "
                      "if command -v tmux >/dev/null 2>&1 || [ -x /opt/homebrew/bin/tmux ]; "
                      "then echo 'tmux: installed'; "
                      "else echo 'tmux: not installed there (brew install tmux); sessions in tmux can be attached to'; fi",
                timeout=20)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
        sys.exit(f"setup failed: {e}")
    print((p.stdout or "") + (p.stderr or ""), end="")
    if p.returncode != 0:
        sys.exit("setup failed")
    print(f"done. `s` now includes {label}; `s live` shows what runs there.")


def hosts_cmd(args, hosts):
    if not args:
        if not hosts:
            print("no hosts configured. add one with:  s hosts add studio user@hostname")
            return
        width = max(len(k) for k in hosts)
        for label, dest in hosts.items():
            ok, msg = host_check(dest)
            print(f"{c('32', '●') if ok else c('31', '●')} {c('1', label.ljust(width))}  {dest}  {c('2', msg)}")
        return
    sub = args[0]
    if sub == "add" and len(args) in (2, 3):
        label, dest = args[1], args[-1]
        hosts[label] = dest
        save_hosts(hosts)
        print(f"added {label} -> {dest}\nnext: s hosts setup {label}   (copies sessions there)")
    elif sub in ("rm", "remove") and len(args) == 2 and args[1] in hosts:
        del hosts[args[1]]
        save_hosts(hosts)
        print(f"removed {args[1]}")
    elif sub == "setup" and len(args) == 2 and args[1] in hosts:
        hosts_setup(args[1], hosts[args[1]])
    else:
        sys.exit("usage: s hosts | s hosts add LABEL user@host | s hosts setup LABEL | s hosts rm LABEL")


# ----------------------------------------------------------------- sync (memories + configs)

SYNC_STATE_DIR = os.path.join(CONFIG_DIR, "sync")
BACKUP_ROOT = os.path.join(CLAUDE_DIR, "backups")
CONFIG_FILES = ("settings.json", "CLAUDE.md", "keybindings.json")
CONFIG_DIRS = ("commands", "agents", "hooks", "skills")
SYNC_SKIP_DIRS = ("skills/synced",)  # managed by your claude.ai account, not by you
SYNC_MAX_FILE = 2_000_000
MCP_FILE = "mcp-servers.json"  # the mcpServers section of ~/.claude.json, as its own file
JUNK_PROJECTS = ("-private-tmp", "-tmp", "-var-folders", "-private-var")


def encode_path(p):
    """How Claude Code names a project folder under ~/.claude/projects."""
    return re.sub(r"[^A-Za-z0-9]", "-", p)


def logical_project(dirname, home):
    """projects/<dirname> -> 'HOME-rest' so the same project matches on a machine with another home."""
    enc = encode_path(home)
    if dirname == enc:
        return "HOME"
    if dirname.startswith(enc + "-"):
        return "HOME" + dirname[len(enc):]
    if dirname == "-" or dirname.startswith(JUNK_PROJECTS):
        return None
    return dirname


def physical_project(logical, home):
    enc = encode_path(home)
    if logical == "HOME":
        return enc
    if logical.startswith("HOME-"):
        return enc + logical[4:]
    return logical


def physical_path(logical):
    if logical.startswith("codex/"):
        return os.path.join(CODEX_HOME, logical[len("codex/"):])
    if logical.startswith("memory/"):
        _, proj, rest = logical.split("/", 2)
        return os.path.join(PROJECTS, physical_project(proj, HOME), "memory", rest)
    return os.path.join(CLAUDE_DIR, logical)


def pretty_logical(logical):
    if logical == CODEX_FILE:
        return "codex: settings in config.toml and profiles (trusted folders, hook approvals, model, ...)"
    return logical.replace("memory/HOME", "memory/~", 1)


def sync_paths(items):
    """logical path -> absolute path for everything on this machine that takes part in a sync."""
    out = {}
    if "configs" in items:
        for f in CONFIG_FILES:
            p = os.path.join(CLAUDE_DIR, f)
            if os.path.isfile(p):
                out[f] = p
        for d in CONFIG_DIRS:
            for root, dirs, files in os.walk(os.path.join(CLAUDE_DIR, d)):
                rel = os.path.relpath(root, CLAUDE_DIR)
                if (any(rel == s or rel.startswith(s + "/") for s in SYNC_SKIP_DIRS)
                        or any(part.startswith(".") for part in rel.split("/"))):  # e.g. skills/.trash
                    dirs[:] = []
                    continue
                for fn in files:
                    p = os.path.join(root, fn)
                    if not fn.startswith(".") and os.path.getsize(p) <= SYNC_MAX_FILE:
                        out[os.path.join(rel, fn)] = p
        for f in CODEX_FILES:  # Codex: instructions, hooks and command rules, as whole files
            p = os.path.join(CODEX_HOME, f)
            if os.path.isfile(p):
                out["codex/" + f] = p
        for d in CODEX_DIRS:
            for root, _, files in os.walk(os.path.join(CODEX_HOME, d)):
                for fn in files:
                    p = os.path.join(root, fn)
                    if not fn.startswith(".") and ".bak" not in fn and os.path.getsize(p) <= SYNC_MAX_FILE:
                        out["codex/" + os.path.relpath(p, CODEX_HOME)] = p
    if "memory" in items and os.path.isdir(PROJECTS):
        for ent in os.scandir(PROJECTS):
            mem = os.path.join(ent.path, "memory")
            if not ent.is_dir() or not os.path.isdir(mem):
                continue
            lp = logical_project(ent.name, HOME)
            if lp is None:
                continue
            for root, _, files in os.walk(mem):
                for fn in files:
                    p = os.path.join(root, fn)
                    if not fn.startswith(".") and os.path.getsize(p) <= SYNC_MAX_FILE:
                        out["memory/" + lp + "/" + os.path.relpath(p, mem)] = p
    return out


def claude_json_path():
    return env("CLAUDE_JSON") or os.path.expanduser("~/.claude.json")


def mcp_bytes():
    """The MCP server definitions as a stable JSON document, or None if there is no ~/.claude.json."""
    try:
        with open(claude_json_path()) as f:
            servers = json.load(f).get("mcpServers") or {}
    except (OSError, ValueError):
        return None
    return (json.dumps(servers, indent=1, sort_keys=True) + "\n").encode()


# Codex's settings live in TOML files that also hold what only one machine should have (the
# ChatGPT app's window preferences and plugin cache paths, ai-bridge's copy of the MCP servers),
# so a sync takes only the portable parts, setting by setting, as the exact lines Codex wrote:
# top-level settings, trusted folders, hook approvals and a few preference tables. Text, not a
# TOML library: a Mac's own python3 (3.9) has none.
CODEX_FILE = "codex-settings.json"  # the portable parts of ~/.codex/config.toml and *.config.toml
CODEX_FILES = ("AGENTS.md", "hooks.json")
CODEX_DIRS = ("rules",)
CODEX_TABLES = re.compile(r"(projects\.|hooks\.state|tui$|tui\.|sandbox_workspace_write$|permissions\.)")
TOML_HEADER = re.compile(r"\[([^\[\]]+)\]\s*(?:#.*)?$")
TOML_KEY = re.compile(r'([A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*")\s*=')


def toml_depth(line):
    """How many brackets/braces a line leaves open, ignoring those inside strings and comments."""
    depth, quote, i = 0, None, 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\" and quote == '"':
                i += 1
            elif ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#":
            break
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        i += 1
    return depth


def toml_sections(text):
    """[[header or None, [(key or None, raw text)]]]: the part before the first table, then each
    table; a setting's raw text includes the lines its value continues on."""
    out, open_key, depth = [[None, []]], None, 0
    for line in text.splitlines(keepends=True):
        if open_key is not None:
            out[-1][1][-1] = (open_key, out[-1][1][-1][1] + line)
            depth += toml_depth(line)
            if depth <= 0:
                open_key = None
            continue
        m = TOML_HEADER.match(line.rstrip("\n")) if line.startswith("[") and not line.startswith("[[") else None
        if m:
            out.append([m.group(1).strip(), []])
            continue
        k = TOML_KEY.match(line)
        if k:
            out[-1][1].append((k.group(1), line))
            depth = toml_depth(line[k.end():])
            if depth > 0:
                open_key = k.group(1)
        else:
            out[-1][1].append((None, line))
    return out


def codex_portable_of(text):
    """{"top": {key: raw}, "tables": {header: {key: raw}}}: what a sync carries of one TOML file."""
    top, tables = {}, {}
    for header, entries in toml_sections(text):
        if header is not None and not CODEX_TABLES.match(header):
            continue
        keys = {k: raw if raw.endswith("\n") else raw + "\n" for k, raw in entries if k}
        if header is None:
            top = keys
        else:
            tables.setdefault(header, {}).update(keys)
    return {"top": top, "tables": tables}


def codex_toml_files():
    out = {}
    for p in [os.path.join(CODEX_HOME, "config.toml")] + sorted(glob.glob(os.path.join(CODEX_HOME, "*.config.toml"))):
        if os.path.isfile(p):
            out[os.path.basename(p)] = p
    return out


def codex_settings_bytes():
    files = codex_toml_files()
    if not files:
        return None, 0
    data = {}
    for name_, p in files.items():
        with open(p, errors="replace") as f:
            data[name_] = codex_portable_of(f.read())
    return (json.dumps(data, indent=1, sort_keys=True) + "\n").encode(), max(os.path.getmtime(p) for p in files.values())


def codex_apply_portable(text, want):
    """text with the portable settings in `want` put in: a changed setting replaced where it is,
    a new one added to its table (or a new table at the end). Nothing is removed."""
    sections = toml_sections(text)

    def put(section, key, raw):
        entries = section[1]
        for i, (k, old) in enumerate(entries):
            if k == key:
                entries[i] = (k, raw)
                return
        last = max([i for i, (k, _) in enumerate(entries) if k] or [-1])
        entries.insert(last + 1, (key, raw))

    for key, raw in want.get("top", {}).items():
        put(sections[0], key, raw)
    for header, keys in want.get("tables", {}).items():
        section = next((s for s in sections if s[0] == header), None)
        if section is None:
            section = [header, [], True]
            sections.append(section)
        for key, raw in keys.items():
            put(section, key, raw)
    out = []
    for header, entries, *new in sections:
        if new and out and out[-1].strip():  # a table this file did not have: after a blank line
            out.append("\n")
        if header is not None:
            out.append(f"[{header}]\n")
        out.extend(raw if raw.endswith("\n") else raw + "\n" for _, raw in entries)
    return "".join(out)


def codex_write_settings(data, keep):
    """Apply a merged codex-settings.json here. -> names of the files changed."""
    changed = []
    for fname, want in sorted(data.items()):
        if "/" in fname or not (fname == "config.toml" or fname.endswith(".config.toml")):
            continue
        p = os.path.join(CODEX_HOME, fname)
        try:
            with open(p, errors="replace") as f:
                text = f.read()
        except OSError:
            text = ""
        new = codex_apply_portable(text, want)
        if new == text:
            continue
        try:  # where Python can read TOML, refuse to write a file Codex couldn't
            import tomllib
            tomllib.loads(new)
        except ImportError:
            pass
        except ValueError as e:
            print(c("33", f"skipped ~/.codex/{fname}: the merged file would not parse ({e})"), file=sys.stderr)
            continue
        keep(p, "codex/" + fname)
        os.makedirs(CODEX_HOME, exist_ok=True)
        tmp = p + ".s-tmp"
        with open(tmp, "w") as f:
            f.write(new)
        if os.path.exists(p):
            shutil.copymode(p, tmp)
        else:
            os.chmod(tmp, 0o600)
        os.replace(tmp, p)
        changed.append(fname)
    return changed


def sha(data):
    import hashlib
    return hashlib.sha256(data).hexdigest()


def local_snapshot(items):
    """{logical: {"hash", "mtime", "data"}} for this machine."""
    snap = {}
    for logical, p in sync_paths(items).items():
        with open(p, "rb") as f:
            data = f.read()
        snap[logical] = {"hash": sha(data), "mtime": os.path.getmtime(p), "data": data}
    if "configs" in items:
        data = mcp_bytes()
        if data is not None:
            snap[MCP_FILE] = {"hash": sha(data), "mtime": os.path.getmtime(claude_json_path()), "data": data}
        data, mtime = codex_settings_bytes()
        if data is not None:
            snap[CODEX_FILE] = {"hash": sha(data), "mtime": mtime, "data": data}
    return snap


def pack(files, extra=None):
    """tar.gz bytes: files/<logical> for each entry (with its mtime) plus optional small JSON members."""
    import io
    import tarfile
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, data in (extra or {}).items():
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mtime = int(datetime.now().timestamp())
            tar.addfile(ti, io.BytesIO(data))
        for logical, entry in files.items():
            ti = tarfile.TarInfo("files/" + logical)
            ti.size = len(entry["data"])
            ti.mtime = int(entry.get("mtime") or datetime.now().timestamp())
            tar.addfile(ti, io.BytesIO(entry["data"]))
    return buf.getvalue()


def unpack(data):
    """-> (extra members as {name: bytes}, files as {logical: {"hash", "mtime", "data"}})."""
    import io
    import tarfile
    extra, files = {}, {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for m in tar.getmembers():
            if not m.isfile():
                continue
            body = tar.extractfile(m).read()
            if m.name.startswith("files/"):
                files[m.name[6:]] = {"hash": sha(body), "mtime": float(m.mtime), "data": body}
            else:
                extra[m.name] = body
    return extra, files


def missing_plugins():
    """Plugins settings.json turns on that Claude Code has not installed on this machine (a sync
    carries the setting, not the plugin)."""
    try:
        with open(os.path.join(CLAUDE_DIR, "settings.json")) as f:
            enabled = [k for k, v in (json.load(f).get("enabledPlugins") or {}).items() if v]
    except (OSError, ValueError, AttributeError):
        return []
    try:
        with open(os.path.join(CLAUDE_DIR, "plugins", "installed_plugins.json")) as f:
            installed = set(json.load(f).get("plugins") or {})
    except (OSError, ValueError, AttributeError):
        installed = set()
    return [p for p in enabled if p not in installed]


def install_plugins():
    """Install the plugins settings.json turns on but this machine lacks. -> [[plugin, outcome]]"""
    claude = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
    out = []
    for plugin in missing_plugins():
        try:
            p = subprocess.run([claude, "plugin", "install", plugin], capture_output=True, text=True,
                               timeout=300, cwd=HOME)
            ok = p.returncode == 0
            out.append([plugin, "installed" if ok else ((p.stderr or p.stdout).strip().splitlines() or ["failed"])[-1][:160]])
        except (OSError, subprocess.TimeoutExpired) as e:
            out.append([plugin, f"failed: {e}"])
    return out


def apply_changes(writes, deletes):
    """Write and delete on this machine, keeping a copy of anything replaced under ~/.claude/backups."""
    stamp = datetime.now().strftime("sessions-sync-%Y%m%d-%H%M%S")
    backup = os.path.join(BACKUP_ROOT, stamp)
    result = {"written": [], "deleted": [], "backup": None}

    def keep(path, logical):
        if os.path.exists(path):
            dst = os.path.join(backup, logical)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(path, dst)
            result["backup"] = backup

    def put(path, data, mtime):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".s-tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
        if mtime:
            os.utime(path, (mtime, mtime))

    for logical, entry in writes.items():
        if logical == MCP_FILE:
            p = claude_json_path()
            keep(p, "claude.json")
            try:
                with open(p) as f:
                    o = json.load(f)
            except (OSError, ValueError):
                o = {}
            o["mcpServers"] = json.loads(entry["data"])
            put(p, (json.dumps(o, indent=2) + "\n").encode(), None)
            if shutil.which("ai-bridge"):  # Codex's copy of the MCP servers follows Claude's
                subprocess.run(["ai-bridge", "sync", "--quiet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif logical == CODEX_FILE:
            codex_write_settings(json.loads(entry["data"]), keep)
        else:
            p = physical_path(logical)
            keep(p, logical)
            put(p, entry["data"], entry.get("mtime"))
        result["written"].append(logical)
    for logical in deletes:
        p = physical_path(logical)
        if os.path.exists(p):
            keep(p, logical)
            os.remove(p)
            result["deleted"].append(logical)
    if "settings.json" in result["written"]:
        result["plugins"] = install_plugins()
    return result


def merge_json(a, b, prefer_a):
    """Deep merge: dict keys unioned, lists unioned in order, scalar conflicts go to the winner."""
    if isinstance(a, dict) and isinstance(b, dict):
        first, second = (a, b) if prefer_a else (b, a)
        out = {}
        for k in list(first) + [k for k in second if k not in first]:
            out[k] = merge_json(a[k], b[k], prefer_a) if k in a and k in b else (a.get(k) if k in a else b[k])
        return out
    if isinstance(a, list) and isinstance(b, list):
        first, second = (a, b) if prefer_a else (b, a)
        return list(first) + [x for x in second if x not in first]
    return a if prefer_a else b


def merge_index(a, b, prefer_a):
    """MEMORY.md indexes: keep every bullet, deduped by the file it links to, winner's order first."""
    first, second = (a, b) if prefer_a else (b, a)
    lines, seen = [], set()
    for text in (first, second):
        for line in text.decode(errors="replace").splitlines():
            key = re.search(r"\]\(([^)]+)\)", line)
            key = key.group(1) if key else (line.strip() if line.strip() else None)
            if key is not None and key in seen:
                continue
            if text is second and not line.startswith("-"):
                continue  # headers and prose come from the winner only
            if key is not None:
                seen.add(key)
            lines.append(line)
    return ("\n".join(lines).rstrip("\n") + "\n").encode()


def merge_entry(logical, le, re_, prefer_local):
    """Merged bytes for the few files that should be combined instead of overwritten, else None."""
    if logical in ("settings.json", MCP_FILE, CODEX_FILE):
        try:
            merged = merge_json(json.loads(le["data"]), json.loads(re_["data"]), prefer_local)
        except ValueError:
            return None
        return (json.dumps(merged, indent=2 if logical == "settings.json" else 1,
                           sort_keys=logical != "settings.json") + "\n").encode()
    if logical.startswith("memory/") and logical.endswith("/MEMORY.md"):
        return merge_index(le["data"], re_["data"], prefer_local)
    return None


def state_path(label):
    return os.path.join(SYNC_STATE_DIR, re.sub(r"[^A-Za-z0-9_.-]", "_", label) + ".json")


def plan_sync(local, remote, state, prefer, allow_delete, label):
    """Decide per file. -> (local_writes, local_deletes, remote_writes, remote_deletes, lines, same)."""
    lw, ld, rw, rd, lines, same = {}, [], {}, [], [], 0
    for logical in sorted(set(local) | set(remote)):
        le, re_ = local.get(logical), remote.get(logical)
        shown = pretty_logical(logical)
        if le and re_:
            if le["hash"] == re_["hash"]:
                same += 1
                continue
            local_wins = prefer == "local" or (prefer == "newest" and le["mtime"] >= re_["mtime"])
            merged = merge_entry(logical, le, re_, local_wins)
            if merged is not None:
                entry = {"data": merged, "mtime": max(le["mtime"], re_["mtime"]), "hash": sha(merged)}
                if entry["hash"] != le["hash"]:
                    lw[logical] = entry
                if entry["hash"] != re_["hash"]:
                    rw[logical] = entry
                lines.append(("merge", shown, "both sides differ, combined" +
                              ("" if prefer == "newest" else f", {prefer} wins conflicts")))
            elif local_wins:
                rw[logical] = le
                why = "local wins" if prefer == "local" else f"newer here ({when_ts(le['mtime'])} vs {when_ts(re_['mtime'])})"
                lines.append(("push", shown, why))
            else:
                lw[logical] = re_
                why = f"{label} wins" if prefer == "remote" else f"newer there ({when_ts(re_['mtime'])} vs {when_ts(le['mtime'])})"
                lines.append(("pull", shown, why))
        elif le:
            if allow_delete and state.get(logical) == le["hash"] and prefer != "local":
                ld.append(logical)
                lines.append(("delete here", shown, f"removed on {label} since the last sync"))
            else:
                rw[logical] = le
                lines.append(("push", shown, "only here"))
        else:
            if allow_delete and state.get(logical) == re_["hash"] and prefer != "remote":
                rd.append(logical)
                lines.append((f"delete on {label}", shown, "removed here since the last sync"))
            else:
                lw[logical] = re_
                lines.append(("pull", shown, f"only on {label}"))
    return lw, ld, rw, rd, lines, same


def when_ts(t):
    return datetime.fromtimestamp(t).strftime("%b %d %H:%M")


ACTION_STYLE = {"push": ("→", "32"), "pull": ("←", "36"), "merge": ("⇄", "33")}


def sync_cmd(label, dest, items, prefer, dry, yes, allow_delete, title):
    try:
        p = subprocess.run(["ssh", *SSH_OPTS, dest, f"{REMOTE_S} _export --items {','.join(items)}"],
                           capture_output=True, timeout=120)
    except (subprocess.TimeoutExpired, OSError) as e:
        sys.exit(f"{label}: {e}")
    if p.returncode != 0:
        err = p.stderr.decode(errors="replace").strip().splitlines() or ["ssh failed"]
        sys.exit(f"{label}: {err[-1]}\n(an older version there? run: s hosts setup {label})")
    try:
        extra, remote = unpack(p.stdout)
        manifest = json.loads(extra["manifest.json"])
    except (KeyError, ValueError, OSError):
        sys.exit(f"{label}: unexpected reply, run: s hosts setup {label}")
    local = local_snapshot(items)
    try:
        with open(state_path(label)) as f:
            state = json.load(f).get("files", {})
    except (OSError, ValueError):
        state = {}
    lw, ld, rw, rd, lines, same = plan_sync(local, remote, state, prefer, allow_delete, label)
    what = " + ".join(items)
    print(c("1", f"{title} {label}") + c("2", f"  ({what}; their home {manifest.get('home')}; "
                                               f"{len(local)} files here, {len(remote)} there)"))
    cols, _ = term()
    width = min(max([20] + [len(s) for _, s, _ in lines]), max(30, cols - 60))
    for action, shown, why in lines:
        sym, col = ACTION_STYLE.get(action.split()[0], ("✕", "31"))
        print(f"  {c(col, sym + ' ' + action.ljust(16))} {fit(shown, width).ljust(width)}  {c('2', why)}")
    print(c("2", f"  = {same} files identical"))
    if not lines:
        print("nothing to do")
        return
    if dry:
        print(c("2", "dry run, nothing changed"))
        return
    if not yes:
        if not sys.stdin.isatty():
            sys.exit("not applying without -y (no terminal to confirm)")
        try:
            ans = input(c("1", f"apply {len(lines)} changes? [y/N] ")).strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if ans not in ("y", "yes"):
            print("cancelled")
            return
    if rw or rd:
        payload = pack(rw, {"plan.json": json.dumps({"deletes": rd}).encode()})
        try:
            q = subprocess.run(["ssh", *SSH_OPTS, dest, f"{REMOTE_S} _import"], input=payload,
                               capture_output=True, timeout=600)  # (it may install plugins there)
        except (subprocess.TimeoutExpired, OSError) as e:
            sys.exit(f"{label}: {e}")
        if q.returncode != 0:
            sys.exit(f"{label}: import failed: {q.stderr.decode(errors='replace').strip()[-300:]}")
        try:
            rres = json.loads(q.stdout.decode())
        except ValueError:
            sys.exit(f"{label}: import gave no result")
        print(f"{label}: wrote {len(rres['written'])}, removed {len(rres['deleted'])}"
              + (f", backups in {rres['backup']}" if rres.get("backup") else ""))
        for plugin, outcome in rres.get("plugins") or []:
            print(f"{label}: plugin {plugin}: {outcome}")
    lres = apply_changes(lw, ld) if lw or ld else {"plugins": install_plugins() if "configs" in items else []}
    if lw or ld:
        print(f"here: wrote {len(lres['written'])}, removed {len(lres['deleted'])}"
              + (f", backups in {lres['backup']}" if lres.get("backup") else ""))
    for plugin, outcome in lres.get("plugins") or []:
        print(f"here: plugin {plugin}: {outcome}")
    final = {}
    for logical, e in local.items():
        if logical not in ld:
            final[logical] = e["hash"]
    for logical, e in remote.items():
        if logical not in rd and logical not in final:
            final[logical] = e["hash"]
    for logical, e in list(lw.items()) + list(rw.items()):
        final[logical] = e["hash"]
    os.makedirs(SYNC_STATE_DIR, exist_ok=True)
    with open(state_path(label), "w") as f:
        json.dump({"at": datetime.now().isoformat(), "items": items, "files": final}, f, indent=1)
    print(c("32", "done"))


def export_cmd(items):
    """`s _export`: this machine's sync files as a tar.gz on stdout (run over ssh by the other side)."""
    snap = local_snapshot(items)
    manifest = {"home": HOME, "version": VERSION,
                "files": {k: {"hash": v["hash"], "mtime": v["mtime"]} for k, v in snap.items()}}
    sys.stdout.buffer.write(pack(snap, {"manifest.json": json.dumps(manifest).encode()}))


def import_cmd():
    """`s _import`: apply a plan tar.gz from stdin, report as JSON (run over ssh by the other side)."""
    extra, files = unpack(sys.stdin.buffer.read())
    plan = json.loads(extra.get("plan.json", b"{}"))
    print(json.dumps(apply_changes(files, plan.get("deletes", []))))


# ----------------------------------------------------------------- selection

SHORT_GRACE = timedelta(days=1)  # a session under the minimum work still shows this long after its last turn


def select(sessions, days, min_active, sort):
    now = datetime.now(timezone.utc)
    cutoff_day = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
    view = []
    for s in sessions:
        last = parse_ts(s["last"])
        if last is None or last < now - timedelta(days=days) or s["user"] == 0:
            continue
        s["active_win"] = sum(v for d, v in s["days"].items() if d >= cutoff_day) / 60
        s["days_win"] = sorted(d for d, v in s["days"].items() if d >= cutoff_day and v >= 60)
        if s["active_win"] < min_active and last < now - SHORT_GRACE:
            continue  # short, and not touched for a day
        view.append(s)
    if sort == "active":
        view.sort(key=lambda s: -s["active_win"])
    else:
        view.sort(key=lambda s: s["last"], reverse=True)
    return view


def matches(s, query):
    words = query.lower().split()
    hay = None
    for w in words:
        if w.startswith("@"):  # @studio = sessions on that host, @local = this machine
            here = s.get("host") or "local"
            if here != w[1:]:
                return False
            continue
        if w == "running":
            if not running_of(s):
                return False
            continue
        if w == "cron":
            if not s["jobs"]:
                return False
            continue
        if w in ("claude", "codex"):
            if s.get("app", "claude") != w:
                return False
            continue
        if hay is None:
            hay = " ".join([s["id"], project(s), name(s), s.get("ai_title") or "", last_prompt(s),
                            s.get("host") or ""]
                           + [p[1] for p in s["first_prompts"] + s["last_prompts"]]
                           + [m["id"] + " " + m["name"] for m in s.get("chain") or []]).lower()
        if w not in hay:
            return False
    return True


# ----------------------------------------------------------------- display

def project(s):
    p = s.get("cwd") or s.get("project_dir") or "?"
    return HOME_RE.sub("~", p, count=1)


def short_project(s):
    p = project(s)
    return p if p == "~" else (os.path.basename(p.rstrip("/")) or p)


def name(s):
    """Session name: your /rename title, else Claude's auto title, else first prompt."""
    if s.get("custom_title"):
        return s["custom_title"]
    if s.get("ai_title"):
        return s["ai_title"]
    return fit(s["first_prompts"][0][1], 60) if s["first_prompts"] else "(untitled)"


def subtitle(s):
    """Auto title, shown next to a custom name when both exist and differ."""
    if s.get("custom_title") and s.get("ai_title") and s["ai_title"] != s["custom_title"]:
        return s["ai_title"]
    return ""


def last_prompt(s):
    """The last thing you asked, skipping one-word replies like 'yes' or 'resume'."""
    ps = s["first_prompts"] + s["last_prompts"]
    for _, p in reversed(ps):
        if len(p.split()) >= 3:
            return p
    return ps[-1][1] if ps else ""


def rel(ts_iso):
    ts = parse_ts(ts_iso)
    sec = (datetime.now(timezone.utc) - ts).total_seconds()
    if sec < 3600:
        return f"{int(sec // 60)}m ago"
    if sec < 86400:
        return f"{int(sec // 3600)}h ago"
    if sec < 14 * 86400:
        return f"{int(sec // 86400)}d ago"
    return ts.astimezone().strftime("%b %d")


def when(ts_iso):
    return parse_ts(ts_iso).astimezone().strftime("%b %d %H:%M")


def hm(minutes):
    return f"{minutes / 60:.1f}h" if minutes >= 60 else f"{int(minutes)}m"


def ktok(n):
    return f"{n / 1000:.0f}k" if n >= 1000 else str(n)


def fit(s, n):
    return s if len(s) <= n else s[: n - 1] + "…"


def term():
    size = shutil.get_terminal_size((120, 40))
    return size.columns, size.lines


def flags(s):
    """Two marker cells: running, and cron jobs."""
    r = running_of(s)
    a = (c("32", "●") if r.get("status") == "busy" else c("33", "●")) if r else " "
    if s["jobs"]:
        statuses = {st for _, st, _, _ in session_jobs(s)}
        b = c("32", "↻") if statuses & {"live", "waiting"} else c("2", "↻")
    else:
        b = " "
    return a + b


def where(s):
    """'@host' suffix for remote sessions."""
    return c("35", "@" + s["host"]) if is_remote(s) else ""


def app_of(s):
    return s.get("app") or "claude"


def app_cell(s):
    """'claude' / 'codex', with ⇄ when the conversation moved between the two."""
    return ("⇄" if s.get("chain") else " ") + app_of(s)


APP_LABEL = {"claude": "Claude Code", "codex": "Codex"}
APP_COLOR = {"claude": "33", "codex": "34"}


def print_list(view, start=0, count=None):
    """One row per session, columns sized to the terminal width."""
    cols, _ = term()
    rows = view[start:] if count is None else view[start:start + count]
    if not rows:
        return
    gutter = "   "
    show_proj = cols >= 100
    show_work = cols >= 80
    show_app = any(app_of(s) != "claude" or s.get("chain") for s in view)
    hw = max([4] + [len(h) for h in HOSTS]) if HOSTS else 0
    nw = min(38, max(len(name(s)) for s in rows))
    pw = min(18, max(len(short_project(s)) for s in rows)) if show_proj else 0
    fixed = 3 + len(gutter) + 2 + len(gutter) + 7 + len(gutter) + nw + len(gutter)
    if hw:
        fixed += hw + len(gutter)
    if show_app:
        fixed += 7 + len(gutter)
    if show_work:
        fixed += 5 + len(gutter)
    if show_proj:
        fixed += pw + len(gutter)
    for floor in (26, 20):  # narrow terminal: shorter names first, then no folder, then shorter still
        shrink = min(nw - floor, 24 - (cols - fixed - 1))
        if shrink > 0:
            nw, fixed = nw - shrink, fixed - shrink
        if cols - fixed - 1 < 24 and show_proj and floor == 26:  # the prompt matters more than the folder
            show_proj, fixed = False, fixed - pw - len(gutter)
    lw = max(16, cols - fixed - 1)

    def row(idx, flag, nm, proj, app, host, last, prompt, work, header=False):
        cells = [(f"{idx:>3}", "1;36"), (f"{nm:<{nw}}", "1"), (flag, None)]
        if show_proj:
            cells.append((f"{proj:<{pw}}", "2"))
        if show_app:
            cells.append((f"{app:<7}", APP_COLOR.get(app.strip(" ⇄"), "")))
        if hw:
            cells.append((f"{host:<{hw}}", "35"))
        cells.append((f"{last:<7}", "32" if ("m ago" in last or "h ago" in last) else ""))
        if isinstance(prompt, tuple):  # a search hit: the matching prompt, its words highlighted
            plain = prompt[0]
            cells.append((highlight(plain, SEARCH_WORDS) + (" " * (lw - len(plain)) if show_work else ""), None))
        else:
            cells.append((f"{prompt:<{lw}}" if show_work else prompt, ""))
        if show_work:
            cells.append((f"{work:>5}", ""))
        if header:
            return c("2", gutter.join(t for t, _ in cells).rstrip())
        return gutter.join(t if code is None else (c(code, t) if code else t) for t, code in cells).rstrip()

    found = any(s.get("match") is not None for s in rows)
    print(row("#", "  ", "name", "project", " app", "host", "last", "matching prompt" if found else "last prompt",
              " work", header=True))
    for i, s in enumerate(rows, start + 1):
        prompt = (fit(s["match"], lw),) if s.get("match") is not None else fit(last_prompt(s), lw)
        print(row(i, flags(s), fit(name(s), nw), fit(short_project(s), pw), app_cell(s), s.get("host") or "",
                  rel(s["last"]), prompt, hm(s["active_win"])))


def live_block(s, indent="   "):
    """Lines describing what a running session is doing right now."""
    r = running_of(s)
    lines = []
    if r:
        status = r.get("status") or "?"
        ref = s.get("last_prompt_ts") if status == "busy" else s["last"]
        since = rel(ref or s["last"]).replace(" ago", "")
        if status == "busy":
            head = c("32", "busy") + f" for {since}"
        elif status == "idle":
            head = c("33", "idle") + f" since {since}"
        else:
            head = c("33", status) + f" · last activity {since} ago"
        if s.get("ctx_tokens"):
            head += f" · context {ktok(s['ctx_tokens'])} tokens"
        if r.get("tmux"):
            head += f" · tmux {r['tmux']}"
        if r.get("backend") == "daemon":
            head += " · daemon"
        lines.append(head)
    ds = daemon_of(s)
    if ds and (r or ds.get("state") in ("working", "blocked")):
        lines.append(c("2", "state  ") + f"{ds.get('state')} · {fit(ds.get('detail') or '', 150)}")
        prs = [ch for ch in ds.get("children") or [] if ch.get("kind") == "pr"]
        if prs:
            by_repo = {}
            for ch in prs:
                repo = ch.get("href", "").rstrip("/").split("/")[-3] if "/pull/" in ch.get("href", "") else "pr"
                by_repo.setdefault(repo, []).append("#" + str(ch.get("id")))
            lines.append(c("2", "prs    ") + " · ".join(f"{k} {', '.join(v)}" for k, v in by_repo.items()))
    if r:
        ps = s["first_prompts"] + s["last_prompts"]
        if ps:
            lines.append(c("2", "asked  ") + fit(ps[-1][1], 150))
        d = doing(s)
        if d:
            lines.append(c("2", "doing  ") + fit(d, 150))
        if s.get("last_said"):
            lines.append(c("2", "said   ") + fit(s["last_said"][1], 150))
    if s.get("todo"):
        td = s["todo"]
        pct = 100 * td["done"] // td["total"] if td["total"] else 0
        lines.append(c("2", "todo   ") + f"{td['done']}/{td['total']} done ({pct}%)"
                     + (f" · now: {fit(td['current'], 100)}" if td.get("current") else ""))
    return [indent + ln for ln in lines]


TMUX_MODE = "auto"  # auto: remote sessions run inside tmux when it exists; always: local ones too; never
DAYS = 14
DAYS_STEPS = (14, 30, 90, 365, 36500)  # how far back `o` in the picker reaches, step by step


def window_label(days):
    return "all time" if days >= 36500 else "last year" if days == 365 else f"last {days} days"



def local_argv(s, target, extra, prepared=None):
    """argv that continues s in `target` here. prepared, when switching tools: ("thread", id) for a
    Claude conversation imported into Codex, ("transcript", path) for one handed over as text, or
    ("catchup", path) for what the other tool did since s, its own session there, last ran."""
    kind, value = prepared or ("transcript", "<transcript>")
    if target == "claude":
        claude = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
        # --add-dir=DIR, not --add-dir DIR: it takes any number of folders and would take the prompt too
        if app_of(s) == "claude" and kind == "catchup":
            return [claude, "--resume", s["id"], "--add-dir=" + HANDOFF_DIR, *extra, catchup_prompt(value)]
        if app_of(s) == "claude":
            return [claude, "--resume", s["id"], *extra]
        return [claude, "--add-dir=" + HANDOFF_DIR, *extra, handoff_prompt(value, "codex", s.get("custom_title") or s.get("ai_title"))]
    codex = shutil.which("codex") or "codex"
    if app_of(s) == "codex" and kind == "catchup":
        return [codex, *codex_args(), "resume", s["id"], *extra, catchup_prompt(value)]
    if app_of(s) == "codex":
        return [codex, *codex_args(), "resume", s["id"], *extra]
    if kind == "thread":
        return [codex, *codex_args(), "resume", value, *extra]
    return [codex, *codex_args(), *extra, handoff_prompt(value, "claude", s.get("custom_title") or s.get("ai_title"))]


def resume_command(s, extra, target=None, prepared=None):
    """(argv, description) that resumes or attaches to the session, locally or over ssh."""
    target = target or app_of(s)
    native = target == app_of(s)
    r = running_of(s) if native else None
    cwd = s.get("cwd") or "~"
    extra_q = " ".join(shlex.quote(e) for e in extra)
    if is_remote(s) and not (native and target == "claude"):
        # the other machine's s does the work there (importing, writing the transcript)
        claude_cmd = (f"s {s['id']} --{target} --local --no-tmux -a -d {int(DAYS)}"
                      + (f" -- {extra_q}" if extra else ""))
    elif is_remote(s):
        claude_cmd = f"cd {shlex.quote(cwd)} && claude --resume {s['id']} {extra_q}".rstrip()
    else:
        argv = local_argv(s, target, extra, prepared)
        claude_cmd = f"cd {shlex.quote(cwd)} && {shlex.join(argv)}"
    tname = "s-" + s["id"][:8] + ("" if native else "-" + target)
    if is_remote(s):
        dest = HOSTS.get(s["host"], s["host"])
        # the usual homes of claude and tmux, in case the remote shell's own PATH lacks them
        path = 'export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; '
        if r and r.get("tmux"):
            inner, desc = path + f"exec tmux attach -t {shlex.quote(r['tmux'])}", f"tmux attach -t {r['tmux']}"
        elif TMUX_MODE != "never":
            # start claude inside a tmux session there: closing the laptop only detaches,
            # and the next `s` pick attaches to the same window
            in_shell = f'"$SHELL" -lic {shlex.quote(path + claude_cmd)}'
            inner = (path + f"if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s {tname} "
                     f"{shlex.quote(in_shell)}; else echo 'tmux is not installed there, so this session "
                     f"ends if the connection drops'; {claude_cmd}; fi")
            desc = f"tmux new-session -A -s {tname} '{claude_cmd}'"
        else:
            inner, desc = path + claude_cmd, claude_cmd
        # an interactive login shell on the other side, so the user's own PATH applies too
        return (["ssh", "-t", *CONTROL_OPTS, dest, f'"$SHELL" -lic {shlex.quote(inner)}'],
                f"ssh -t {dest} '{desc}'")
    if r and r.get("tmux"):
        verb = "switch-client" if os.environ.get("TMUX") else "attach"
        return ["tmux", verb, "-t", r["tmux"]], f"tmux {verb} -t {r['tmux']}"
    if TMUX_MODE == "always" and shutil.which("tmux"):
        if os.environ.get("TMUX"):  # already inside tmux: open the session beside this one
            argv = ["sh", "-c", f"tmux new-session -d -s {tname} {shlex.quote(claude_cmd)} 2>/dev/null; "
                                f"exec tmux switch-client -t {tname}"]
        else:
            argv = ["tmux", "new-session", "-A", "-s", tname, claude_cmd]
        return argv, f"tmux new-session -A -s {tname} '{claude_cmd}'"
    argv = local_argv(s, target, extra, prepared)
    return argv, f"cd {project(s)} && {shlex.join([target, *argv[1:]])}"


def show(s):
    first = parse_ts(s["first"]).astimezone()
    last = parse_ts(s["last"]).astimezone()
    days = " · ".join(f"{d[5:]} {hm(v / 60)}" for d, v in sorted(s["days"].items()) if v >= 60)
    print(c("1", f"Name     {name(s)}") + (c("2", f"   (auto title: {subtitle(s)})") if subtitle(s) else ""))
    print(f"Session  {s['id']}  " + c(APP_COLOR[app_of(s)], f"({APP_LABEL[app_of(s)]})"))
    if is_remote(s):
        print(f"Host     {s['host']}  ({HOSTS.get(s['host'], s['host'])})")
    print(f"Project  {project(s)}" + (f"  (branch {s['branch']})" if s.get("branch") else ""))
    print(f"Started  {first:%a %b %d %H:%M}    Last active  {last:%a %b %d %H:%M}  ({rel(s['last'])})")
    print(f"Work     {hm(s['active'] / 60)} total · {days}")
    print(f"Volume   {s['user']} prompts · {s['assistant']} replies"
          + (f" · {s['tools']} tool calls" if s.get("tools") is not None else "")
          + (f" · {s['model']}" if s.get("model") else ""))
    if s.get("usage"):
        total, by_model, unknown = usage_cost(s["usage"])
        parts = " · ".join(f"{m} {money(v)}" for m, v in sorted(by_model.items(), key=lambda kv: -kv[1]))
        print(c("1", f"Cost     {money(total)}") + c("2", " at API list prices")
              + (f" · {parts}" if len(by_model) > 1 else "")
              + (c("33", "   no price known for " + ", ".join(unknown)) if unknown else ""))
    lb = live_block(s, indent="")
    if lb:
        print(c("1", "Now      ") + lb[0])
        for ln in lb[1:]:
            print("         " + ln)
    jobs = session_jobs(s)
    if jobs:
        print(c("1", "Cron jobs"))
        for j, status, text, expiry in jobs:
            print("  " + job_line(j, status, text, expiry))
            if j.get("prompt"):
                print("     " + c("2", fit(j["prompt"], 140)))
    print(c("1", "First prompts"))
    for ts, p in s["first_prompts"]:
        print(f"  {parse_ts(ts).astimezone():%b %d %H:%M}  {fit(p, 200)}")
    if s["last_prompts"]:
        print(c("1", "Latest prompts"))
        for ts, p in s["last_prompts"]:
            print(f"  {parse_ts(ts).astimezone():%b %d %H:%M}  {fit(p, 200)}")
    chain = s.get("chain") or []
    if chain:
        print(c("1", "Chain") + c("2", "    this conversation moved between tools; its number opens the latest"))
        for i, m in enumerate(chain):
            mark = (c("33", f"  ({m['broken']})") if m.get("broken")
                    else c("32", "  ← opens") if m["id"] == s["id"] else "")
            print(f"  {'→' if i else ' '} {c(APP_COLOR.get(m['app'], ''), m['app'].ljust(6))} "
                  f"{when(m['last'])}  {fit(m['name'], 50).ljust(50)}  {c('2', m['id'][:8])}{mark}")
        print(c("2", "  (s <id> opens exactly that session)"))
    if s.get("broken"):
        print(c("33", f"Note     this Codex thread is {s['broken']}: every new message fails. Continue the "
                      f"conversation from its Claude session with --codex for a fresh thread on a summary."))
    print(c("1", "Resume   ") + resume_command(s, [])[1])
    other = "codex" if app_of(s) == "claude" else "claude"
    member = chain_member(s, other)
    if member:
        hint = (f"   (resumes its {APP_LABEL[other]} session {member['id'][:8]}"
                + (f", which reads what happened here since)" if s["last"] > member["last"] else ")"))
    elif other == "codex":
        hint = "   (imports the conversation into a Codex thread)"
    else:
        hint = "   (Claude reads the Codex transcript and picks up)"
    print(c("1", APP_LABEL[other].split()[0].ljust(9)) + f"s {s['id'][:8]} --{other}" + c("2", hint))


def live_view(sessions):
    rows = sorted((s for s in sessions if running_of(s)), key=lambda s: s["last"], reverse=True)
    if not rows:
        print("no Claude Code sessions are running right now" + (" on any host" if HOSTS else ""))
        return
    for s in rows:
        r = running_of(s)
        label = r.get("name") or name(s)
        dot = c("32", "●") if r.get("status") == "busy" else c("33", "●")
        print(f"{dot} {c('1', label)} {where(s)}  {c('2', project(s))}")
        if label != name(s):
            print(f"   {c('2', 'name   ')}{name(s)}")
        for ln in live_block(s):
            print(ln)
        for j, st, text, exp in session_jobs(s):
            if st in ("live", "waiting"):
                print("   " + c("2", "cron   ") + job_line(j, st, text, exp))
        print()


def jobs_view(sessions):
    rows = []
    for m in job_index().values():
        status, text, expiry = merged_status(m)
        key = m.get("created") or (m["fires"][0] if m["fires"] else "")
        rows.append((key, job_home(m), m, status, text, expiry))
    for s in sessions:
        if is_remote(s):
            for j, status, text, expiry in s["_jobs"]:
                key = j.get("created") or (j["fires"][0] if j["fires"] else "")
                rows.append((key, s, j, status, text, expiry))
    if not rows:
        print("no in-session cron jobs found in this window (try -d 30)")
        return
    rows.sort(key=lambda r: r[0], reverse=True)
    cols, _ = term()
    label = lambda s: name(s) + (f" @{s['host']}" if is_remote(s) else "")  # noqa: E731
    nw = min(34, max(len(label(s)) for _, s, *_ in rows))
    print(c("2", f"{'status':<9}   {'schedule':<24}   {'fires':<12}   {'last fire':<12}   {'session':<{nw}}   prompt"))
    for key, s, j, status, text, expiry in rows:
        sched = fit(j.get("human") or j.get("cron") or "?", 24)
        if not j.get("recurring", True):
            sched = fit("once " + once_text(j), 24)
        last = when(j["fires"][-1]) if j["fires"] else "-"
        col = STATUS_COLOR[status]
        st = c(col, f"{status:<9}") if col else f"{status:<9}"
        rest = cols - (9 + 3 + 24 + 3 + 12 + 3 + 12 + 3 + nw + 3) - 1
        print(f"{st}   {sched:<24}   {text or ('fired' if j['fires'] else '-'):<12}   {last:<12}   "
              f"{c('1', fit(label(s), nw).ljust(nw))}   {fit(j.get('prompt') or '', max(10, rest))}")


BLOCKS = " ▏▎▍▌▋▊▉"


def money(x):
    return f"${x:,.0f}" if x >= 10_000 else f"${x:,.2f}"


def bar(value, scale, width):
    """value as a run of block characters, in eighths of a cell, out of width cells for scale."""
    eighths = int(round(value / scale * width * 8)) if scale > 0 else 0
    return "█" * (eighths // 8) + (BLOCKS[eighths % 8] if eighths % 8 else "")


def cost_chart(title, rows, label_w):
    """rows = [(label, {"claude": $, "codex": $})]: one stacked bar per row, Claude then Codex."""
    cols, _ = term()
    amount_w = 11
    width = max(10, min(70, cols - label_w - amount_w - 6))
    scale = max([sum(v.values()) for _, v in rows] + [0])
    print(c("1", title))
    for label, v in rows:
        total = sum(v.values())
        claude, codex = bar(v.get("claude", 0), scale, width), bar(v.get("codex", 0), scale, width)
        shown = len(claude) + len(codex)
        cells = c(APP_COLOR["claude"], claude) + c(APP_COLOR["codex"], codex) + " " * max(0, width - shown)
        amount = money(total) if total else c("2", "–")
        print(f"  {label:<{label_w}}  {cells}  {amount:>{amount_w}}")
    print()


def cost_view(rows, days, remote_notes, top):
    today = datetime.now().date()
    window = [(today - timedelta(days=i)).isoformat() for i in range(days - 1, -1, -1)]
    in_window = set(window)
    per_day = {d: {"claude": 0.0, "codex": 0.0} for d in window}
    by_model, unknown, ranked = {}, {}, []
    for s in rows:
        spent = 0.0
        for day, keys in (s.get("usage") or {}).items():
            if day not in in_window:
                continue
            for key, vec in keys.items():
                model, cost = key.split("|")[0], cost_of(key, vec)
                if cost is None:
                    unknown[model] = unknown.get(model, 0) + sum(vec[:5])
                    continue
                per_day[day]["codex" if model.startswith("gpt") else "claude"] += cost
                by_model[model] = by_model.get(model, 0) + cost
                spent += cost
        if spent > 0:
            ranked.append((spent, s))
    total = sum(sum(v.values()) for v in per_day.values())
    where = ", ".join(["this machine"] + sorted({s["host"] for s in rows if s.get("host") and s.get("usage")}))
    print(c("1", f"Cost at API list prices · last {days} days · {where}"))
    print(c("2", "what these tokens would cost on the pay-as-you-go API; a subscription is billed differently"))
    for note in remote_notes:
        print(c("33", note))
    legend = c(APP_COLOR["claude"], "█ Claude Code") + "  " + c(APP_COLOR["codex"], "█ Codex")
    print(f"{money(total)} in total · {money(total / days)} a day on average   {legend}\n")
    if days <= 62:
        cost_chart("Per day", [(datetime.fromisoformat(d).strftime("%a %b %d"), per_day[d]) for d in window], 10)
    weeks, months = {}, {}
    for d in window:
        date = datetime.fromisoformat(d).date()
        monday = date - timedelta(days=date.weekday())
        for bucket, key in ((weeks, monday), (months, (date.year, date.month))):
            agg = bucket.setdefault(key, {"claude": 0.0, "codex": 0.0})
            for tool, v in per_day[d].items():
                agg[tool] += v
    cost_chart("Per week", [((f"{m:%b %d}" + " – " + f"{m + timedelta(days=6):%b %d}"), v)
                            for m, v in sorted(weeks.items())], 15)
    cost_chart("Per month", [(datetime(y, mo, 1).strftime("%B %Y"), v) for (y, mo), v in sorted(months.items())], 15)
    if by_model:
        print(c("1", "By model"))
        width = max(len(m) for m in by_model)
        for model, v in sorted(by_model.items(), key=lambda kv: -kv[1]):
            share = 100 * v / total if total else 0
            print(f"  {model:<{width}}  {money(v):>11}  {c('2', f'{share:3.0f}%')}")
        print()
    if ranked:
        ranked.sort(key=lambda r: -r[0])
        shown = ranked if top <= 0 else ranked[:top]
        print(c("1", "Sessions") + c("2", f"  ({len(shown)} of {len(ranked)}; -a for all)" if len(shown) < len(ranked) else ""))
        nw = min(40, max(len(name(s)) for _, s in shown))
        where_of = lambda s: fit(short_project(s), 18) + (f" @{s['host']}" if s.get("host") else "")  # noqa: E731
        pw = max(len(where_of(s)) for _, s in shown)
        for i, (spent, s) in enumerate(shown, 1):
            print(f"  {i:>3}  {money(spent):>11}  {c(APP_COLOR.get(app_of(s), ''), f'{app_cell(s):<7}')}  "
                  f"{fit(name(s), nw):<{nw}}  {c('2', f'{where_of(s):<{pw}}')}  {c('2', s['id'][:8])}")
        print()
    if unknown:
        print(c("33", "Not counted, no published price: " + ", ".join(
            f"{m} ({ktok(t)} tokens{', ' + UNPRICED[m] if m in UNPRICED else ''})" for m, t in unknown.items())))
    print(c("2", f"List prices as of {PRICES_AS_OF}, from Anthropic's and OpenAI's pricing pages. Calls Claude Code makes "
                 "for itself (titles, compaction, auto mode's safety checks) are not in its transcripts, so Claude "
                 "totals can read a little low."))


def chain_member(s, target):
    """The newest session of s's conversation in `target` that can still be resumed, or None."""
    for m in sorted(s.get("chain") or [], key=lambda m: m["last"], reverse=True):
        found = SESSION_INDEX.get((s.get("host"), m["id"]))
        if m["app"] == target and not m.get("broken") and found:
            return found
    return None


def resume(s, extra, dry_run, target=None, prepared=None):
    target = target or app_of(s)
    if target != app_of(s) and not is_remote(s):  # (a remote session's own s does this there)
        member = chain_member(s, target)
        if member:  # the conversation's own session in that tool
            print(c("2", f"→ resuming this conversation's {APP_LABEL[target]} session {member['id'][:8]}"))
            s = member
    native = target == app_of(s)
    if native and not is_remote(s) and prepared is None and s.get("chain"):
        cu = catchup(s, write=not dry_run)
        if cu:  # the rest of the conversation went on without it
            print(c("2", f"→ it gets what happened since in {cu['tools']} "
                         + ("in its first message" if cu["inline"] else f"to read ({cu['path']})")))
            prepared = ("catchup", cu)
            r = running_of(s)
            if r and r.get("tmux"):
                print(c("33", f"note: it is already running; tell it to read {cu['path']}"))
    r = running_of(s) if native else None
    if not is_remote(s):
        cwd = s.get("cwd")
        if not cwd or not os.path.isdir(cwd):
            print(c("33", f"warning: {cwd} no longer exists, starting from {HOME}"))
            s = dict(s, cwd=HOME)
        if target == "codex" and not shutil.which("codex"):
            sys.exit("codex is not installed (npm install -g @openai/codex)")
        try:
            if not native and target == "codex":
                tokens, summary, entries = read_claude(s["path"])
                if tokens <= IMPORT_MAX_TOKENS:
                    print(c("2", f"→ {'would import' if dry_run else 'importing'} this conversation "
                                 f"(~{tokens // 1000}k tokens) into Codex as a new thread"))
                    login = login_stamp()
                    prepared = ("thread", "<new thread>" if dry_run else claude_to_codex(s))
                    if login_stamp() != login:  # the importer refreshed the ChatGPT login: let it settle
                        time.sleep(3)
                else:
                    print(c("2", f"→ this conversation is ~{tokens // 1000}k tokens, more than Codex can take "
                                 f"whole, so Codex starts fresh on Claude's summary plus the recent part"))
                    prepared = ("transcript", "<transcript>" if dry_run else claude_handoff(s))
            elif not native:
                print(c("2", f"→ {'would write' if dry_run else 'writing'} the Codex transcript for Claude to read"))
                prepared = ("transcript", "<transcript>" if dry_run else codex_handoff(s))
        except CodexError as e:
            sys.exit(f"could not continue in {APP_LABEL[target]}: {e}")
    argv, desc = resume_command(s, extra, target, prepared)
    if r and r.get("tmux"):
        print(c("2", f"→ attaching to the tmux window where this session runs: {desc}"))
    else:
        if r:
            print(c("33", f"note: this session is already running elsewhere; this starts a second {target} on it"))
        print(c("2", f"→ {desc}"))
        if "tmux new-session" in desc:
            print(c("2", "   runs inside tmux: closing this terminal or the laptop only detaches it; "
                         "ctrl-b d detaches on purpose, and picking it in s again attaches"))
    if dry_run:
        return
    if not is_remote(s):
        os.chdir(s.get("cwd") or HOME)
        os.environ["SESSIONS_CATCHUP_DONE"] = "1"  # s settled it: ai-bridge's start hook adds nothing
        if prepared and prepared[0] == "catchup" and native:
            mark_caught_up(s["id"], prepared[1]["through"], chain_watch(s))
    if target == "codex" and not is_remote(s) and os.path.basename(argv[0]) == "codex":
        sys.exit(run_codex(argv))
    os.execvp(argv[0], argv)


LOGIN_REFUSED = b"unauthorized (401)"


def login_stamp():
    try:
        return os.stat(os.path.join(CODEX_HOME, "auth.json")).st_mtime
    except OSError:
        return None


def run_codex(argv):
    """Run Codex in this terminal -> its exit code. When it can't start because the ChatGPT login
    was refused, as happens while another Codex is refreshing that login, try once more."""
    import signal
    import threading
    for attempt in (1, 2):
        try:
            p = subprocess.Popen(argv, stderr=subprocess.PIPE)
        except OSError as e:
            sys.exit(f"cannot start codex: {e}")
        signal.signal(signal.SIGINT, signal.SIG_IGN)  # ctrl-c is Codex's, not s's
        tail = [b""]

        def pump():
            for chunk in iter(lambda: os.read(p.stderr.fileno(), 65536), b""):
                os.write(2, chunk)
                tail[0] = (tail[0] + chunk)[-8192:]

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
        rc = p.wait()
        reader.join(0.5)
        if rc == 0 or LOGIN_REFUSED not in tail[0]:
            return rc
        if attempt == 1:
            print(c("33", "Codex's ChatGPT login was refused; trying again in a moment..."), file=sys.stderr)
            time.sleep(3)
    print(c("33", "Still refused. Sign in again with `codex login`, with the same ChatGPT account the "
                  "ChatGPT app uses (they share one login)."), file=sys.stderr)
    return rc


# ----------------------------------------------------------------- pickers

def pick_fzf(view, self_path, older=None):
    """-> (session, target tool), "older" (alt-o, when `older` names a longer window), or None."""
    lines = []
    apps = any(app_of(s) != "claude" or s.get("chain") for s in view)
    for s in view:
        r = running_of(s)
        mark = ("●" if r else " ") + ("↻" if s["jobs"] else " ")
        host = f"{(s.get('host') or ''):<8}" if HOSTS else ""
        lines.append("\t".join([s["id"], fit(name(s), 38).ljust(38), mark, fit(short_project(s), 18).ljust(18),
                                *([f"{app_cell(s):<7}"] if apps else []), *([host] if host else []),
                                f"{rel(s['last']):<7}", fit(s.get("match") or last_prompt(s), 60).ljust(60),
                                f"{hm(s['active_win']):>5}"]))
    try:
        res = subprocess.run(
            ["fzf", "--delimiter=\t", "--with-nth=2..", "--no-sort", "--tabstop=1",
             "--expect=alt-c,alt-x,alt-o",
             "--header=enter = resume · alt-c / alt-x = continue in Claude / Codex"
             + (f" · alt-o = older ({older})" if older else "") + " · ctrl-c = quit · ● running · ↻ cron jobs",
             "--preview", f"{sys.executable} {self_path} show {{1}}",
             "--preview-window=down,55%,wrap"],
            input="\n".join(lines), capture_output=True, text=True)
    except FileNotFoundError:
        return None
    out = res.stdout.split("\n", 1)
    if out[0].strip() == "alt-o" and older:
        return "older"
    if res.returncode != 0 or len(out) < 2 or not out[1].strip():
        return None
    sid = out[1].split("\t", 1)[0].strip()
    s = next((s for s in view if s["id"] == sid), None)
    return (s, {"alt-c": "claude", "alt-x": "codex"}.get(out[0].strip())) if s else None


def clear():
    if TTY:
        sys.stdout.write("\033[2J\033[H")
        sys.stdout.flush()


def pick_builtin(view_all, query, notes, window="", older=None, deep=None, searched=None):
    """-> (session, target tool) or None. older() -> (a longer list, its window) or None at the
    end; deep(text) -> (the conversations with a prompt matching, notes)."""
    flt, page, before = query, 0, None
    while True:
        view = [s for s in view_all if matches(s, flt)] if flt else view_all
        _, lines = term()
        per = max(5, lines - 7 - len(notes))
        pages = max(1, math.ceil(len(view) / per))
        page = min(max(page, 0), pages - 1)
        clear()
        for n in notes:
            print(c("33", n))
        if searched:
            print(c("2", f"prompts with: {searched}" + ("   (? goes back to the list)" if before is not None else "")))
        if flt:
            print(c("2", f"filter: {flt}   (/ clears)"))
        if view:
            print_list(view, page * per, per)
        else:
            print(c("33", "no sessions match"))
        print()
        status = f"{len(view)} " + ("conversations" if searched else "sessions") + (
            "" if searched or not window else f", {window}")
        if pages > 1:
            status += f" · page {page + 1}/{pages} · n / p to page"
        print(c("2", f"{status} · number = resume · c # / x # = continue in Claude / Codex · s # = details"
                     f" · /text = filter · ?text = search every prompt" + (" · o = older" if older and not searched else "")
                     + " · q = quit · ● running · ↻ cron"))
        try:
            ans = input(c("1", "> ")).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return None
        if ans in ("q", "quit", "exit"):
            return None
        if ans == "":
            continue
        if ans in ("o", "older") or (ans in ("n", "next") and page + 1 >= pages):
            more = older() if older and not searched else None
            if more:  # the next page is where the older sessions start
                view_all, window = more
                page += ans in ("n", "next")
            continue
        if ans in ("n", "next"):
            page += 1
            continue
        if ans in ("p", "prev", "b", "back"):
            page -= 1
            continue
        if ans.startswith("?"):
            text = ans[1:].strip()
            if not text:
                if before is not None:
                    view_all, searched, before, flt, page = before, None, None, "", 0
                continue
            if deep:
                print(c("2", f"searching every prompt for {text} ..."))
                rows, notes = deep(text)
                before = view_all if before is None else before
                view_all, searched, flt, page = rows, text, "", 0
            continue
        if ans.startswith("/"):
            flt, page = ans[1:].strip(), 0
            continue
        m = re.fullmatch(r"(?:s|show)\s+(\d+)", ans)
        if m:
            idx = int(m.group(1))
            if 1 <= idx <= len(view):
                clear()
                show(view[idx - 1])
                print()
                try:
                    input(c("2", "enter to go back "))
                except (EOFError, KeyboardInterrupt):
                    print()
                    return None
            continue
        m = re.fullmatch(r"(?:([cx])\s*)?(\d+)", ans)
        if m:
            idx = int(m.group(2))
            if 1 <= idx <= len(view):
                return view[idx - 1], {"c": "claude", "x": "codex"}.get(m.group(1))
            continue
        flt, page = ans, 0


# ----------------------------------------------------------------- main

def find(view, sessions, key):
    """Resolve an index (into view) or an id prefix (any session)."""
    if key.isdigit():
        idx = int(key)
        if 1 <= idx <= len(view):
            return view[idx - 1]
        sys.exit(f"no session #{key}; the list has {len(view)} entries")
    hits = [s for s in sessions if s["id"].startswith(key)]
    if len({s["id"] for s in hits}) == 1:  # on two machines when it was moved: the copy worked on last
        return max(hits, key=lambda s: s["last"])
    sys.exit(f"{'no' if not hits else 'ambiguous'} session id '{key}'")


def print_mode(hits):
    """-p: fit the screen on a terminal, print everything when piped."""
    if not TTY:
        print_list(hits)
        return
    _, lines = term()
    per = max(5, lines - 4)
    print_list(hits, 0, per)
    if len(hits) > per:
        print(c("2", f"… {len(hits) - per} more · run s to page or filter, or s -p | cat for all"))


def replace_with_release(url, path, label):
    """Download a script from the repo and put it at path. -> (old version, new version)."""
    import urllib.request
    try:
        data = urllib.request.urlopen(url, timeout=20).read()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"download failed: {e}")
    compile(data, path, "exec")  # refuse to install a broken script
    new = re.search(rb'^VERSION = "([^"]+)"', data, re.M)
    new = new.group(1).decode() if new else "?"
    try:
        with open(path) as f:
            old = re.search(r'^VERSION = "([^"]+)"', f.read(), re.M)
        old = old.group(1) if old else "?"
    except OSError:
        old = None
    if new == old:
        print(f"{label} {old} is already the latest")
        return
    tmp = path + ".new"
    with open(tmp, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o755)
    os.replace(tmp, path)
    print(f"{label} updated {old} -> {new}")


def self_update():
    me = os.path.realpath(__file__)
    replace_with_release(UPDATE_URL, me, "sessions")
    bridge = os.path.join(os.path.dirname(me), "ai-bridge")
    if os.path.exists(bridge):  # its companion, when installed beside it
        replace_with_release(UPDATE_URL.rsplit("/", 1)[0] + "/ai-bridge", bridge, "ai-bridge")


def to_json(s):
    keys = ("id", "app", "cwd", "project_dir", "host", "branch", "custom_title", "ai_title", "first", "last",
            "active", "active_win", "days", "user", "assistant", "tools", "model", "ctx_tokens", "todo",
            "last_said", "last_prompt_ts", "first_prompts", "last_prompts", "group", "chain", "broken",
            "usage", "match", "match_ts", "matches")
    return {"name": name(s), "last_prompt": last_prompt(s), "running": running_of(s), "doing": doing(s),
            "daemon": daemon_of(s),
            "jobs": [dict({k: v for k, v in j.items() if k != "sessions"}, status=st, fires_text=text,
                          expires=exp.isoformat() if exp else None)
                     for j, st, text, exp in session_jobs(s)],
            **{k: s.get(k) for k in keys}}


def main():
    global _ALL_SESSIONS, HOSTS, TMUX_MODE, DAYS, SESSION_INDEX
    argv = sys.argv[1:]
    if argv[:1] == ["_export"]:  # called over ssh by another machine's s
        items = argv[argv.index("--items") + 1].split(",") if "--items" in argv else ["memory", "configs"]
        export_cmd(items)
        return
    if argv[:1] == ["_import"]:
        import_cmd()
        return
    if argv[:1] == ["_plugins"]:  # `s hosts setup` from another machine: plugins its settings turn on
        print(json.dumps(install_plugins()))
        return
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(prog="s", add_help=False)
    ap.add_argument("rest", nargs="*")
    ap.add_argument("-d", "--days", type=int, default=None)
    ap.add_argument("--top", type=int, default=10)
    ap.add_argument("--grep")
    ap.add_argument("--since")
    ap.add_argument("-m", "--min", type=float, default=10)
    ap.add_argument("-a", "--all", action="store_true")
    ap.add_argument("--sort", choices=["recent", "active"], default="recent")
    ap.add_argument("--local", action="store_true")
    ap.add_argument("--host", action="append", default=[])
    ap.add_argument("--tmux", action="store_true")
    ap.add_argument("--no-tmux", action="store_true")
    ap.add_argument("--claude", action="store_true")
    ap.add_argument("--codex", action="store_true")
    ap.add_argument("--no-codex", action="store_true")
    ap.add_argument("--memory", action="store_true")
    ap.add_argument("--configs", action="store_true")
    ap.add_argument("--prefer", choices=["newest", "local", "remote"], default="newest")
    ap.add_argument("-y", "--yes", action="store_true")
    ap.add_argument("-p", "--print", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-n", "--dry-run", action="store_true")
    ap.add_argument("--rescan", action="store_true")
    ap.add_argument("--no-fzf", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    ap.add_argument("-v", "--version", action="store_true")
    a = ap.parse_intermixed_args(argv)  # options may come between the words
    if a.help:
        print(__doc__.strip())
        return
    if a.version:
        print(f"sessions {VERSION}")
        return
    rest = a.rest
    if a.days is None:
        a.days = 30 if rest[:1] == ["cost"] else 90 if rest[:1] == ["handoff"] else 14
    if rest == ["update"]:
        self_update()
        return
    if rest[:1] == ["hosts"]:
        hosts_cmd(rest[1:], load_hosts())
        return
    if rest[:1] in (["sync"], ["migrate"]):
        hosts = load_hosts(a.host)
        items = ["memory"] if a.memory else ["configs"] if a.configs else ["memory", "configs"]
        if rest[0] == "sync":
            label = rest[1] if len(rest) > 1 else (next(iter(hosts)) if len(hosts) == 1 else None)
            prefer, allow_delete, title = a.prefer, True, "sync with"
        else:
            if len(rest) != 3 or rest[1] not in ("to", "from"):
                sys.exit("usage: s migrate to LABEL | s migrate from LABEL")
            label = rest[2]
            prefer = "local" if rest[1] == "to" else "remote"
            allow_delete, title = False, f"migrate {rest[1]}"
        if not label or label not in hosts:
            sys.exit("which host? " + (", ".join(hosts) if hosts else "none configured (s hosts add ...)"))
        sync_cmd(label, hosts[label], items, prefer, a.dry_run, a.yes, allow_delete, title)
        return
    if a.all:
        a.min = 0
    if a.claude and a.codex:
        sys.exit("pick one of --claude and --codex")
    target = "claude" if a.claude else "codex" if a.codex else None
    TMUX_MODE = "never" if a.no_tmux else "always" if a.tmux else "auto"
    DAYS = a.days

    HOSTS = {}
    if a.host or not a.local:
        HOSTS = load_hosts(a.host)
        if a.local:  # --local --host X: only the hosts named on the command line
            named = {h.partition("=")[0] for h in a.host}
            HOSTS = {k: v for k, v in HOSTS.items() if k in named}
    # `s show <id>` (the fzf preview runs it per line) needs no other machine if the id is here
    lookup = rest[1] if rest[:1] in (["show"], ["path"]) and len(rest) == 2 and not rest[1].isdigit() else None

    def gather(days, include=(), threads=(), remote=True):
        """Every session in the window (and the Claude transcripts / Codex threads named), here and
        on the other machines, linked into conversations. -> (sessions, notes)"""
        global _ALL_SESSIONS, SESSION_INDEX
        pending = start_remote(HOSTS, days) if HOSTS and remote and not lookup else None
        with ThreadPoolExecutor(max_workers=1) as ex:
            codex_job = None if a.no_codex else ex.submit(load_codex, days, a.rescan, threads)
            local = load_sessions(days, a.rescan, include)
            codex, codex_note = codex_job.result() if codex_job else ([], None)
        _ALL_SESSIONS = local
        found = local + codex
        link_sessions(found)  # other machines link their own before answering
        found_notes = [codex_note] if codex_note else []
        if lookup and HOSTS and len([s for s in found if s["id"].startswith(lookup)]) != 1:
            pending = start_remote(HOSTS, days)
        elif lookup and HOSTS:  # found here; the other machines' last answers can still hold a newer copy
            found += cached_remote(HOSTS, days)
        if pending:
            for label, remote_sessions, note in finish_remote(pending):
                found += remote_sessions
                if note:
                    found_notes.append(f"{label}: {note}")
        SESSION_INDEX = {(s.get("host"), s["id"]): s for s in found}
        return found, found_notes

    def search(text):
        """(the conversations, here and on the other machines, with a prompt that has every word
        of text, newest match first; notes)"""
        global SEARCH_WORDS
        SEARCH_WORDS = text.lower().split()
        hits, paths, threads = deep_search(SEARCH_WORDS)
        found, found_notes = gather(a.days, paths, threads, remote=False)
        rows = matched_rows(found, hits, SEARCH_WORDS)
        for label, remote_rows, note in (remote_search(HOSTS, text) if HOSTS else []):
            rows += remote_rows
            SESSION_INDEX.update({(r["host"], r["id"]): r for r in remote_rows})
            if note:
                found_notes.append(f"{label}: {note}")
        rows.sort(key=lambda r: r.get("match_ts") or "", reverse=True)
        return rows, found_notes

    if rest[:1] == ["search"]:
        text = " ".join(rest[1:] + extra).strip()  # words after -- too, so they can start with -
        if not text:
            sys.exit("usage: s search WORDS   (finds every prompt you wrote with all of them, in any session)")
        rows, notes = search(text)
        if a.json:
            print(json.dumps([to_json(s) for s in rows], indent=1))
            return
        for n in notes:
            print(c("33", n), file=sys.stderr)
        if not rows:
            sys.exit(f"no prompt has all of: {text}")
        if a.print or not sys.stdin.isatty():
            print_mode(rows)
            return
        if not a.no_fzf and shutil.which("fzf"):
            chosen = pick_fzf(rows, os.path.abspath(__file__))
        else:
            chosen = pick_builtin(rows, "", notes, "", None, search, text)
        if chosen:
            resume(chosen[0], extra, a.dry_run, chosen[1] or target)
        return

    sessions, notes = gather(a.days)
    a.rescan = False  # once is enough when the picker reaches further back
    if rest[:1] == ["_catchup"] and len(rest) in (2, 3):  # ai-bridge's hooks: a session resumes, or
        live = rest[2:] == ["live"]                            # (live) the user sends it a message
        target = SESSION_INDEX.get((None, rest[1]))
        now = time.time()
        cu = catchup(target, live=live) if target and target.get("chain") else None
        answer = {"through": cu["through"] if cu else now, "watch": chain_watch(target) if target else []}
        if cu:
            answer["context"] = catchup_context(cu, live)
        print(json.dumps(answer))
        return
    if notes and not a.json:
        for n in notes:
            print(c("33", n), file=sys.stderr)
    view = select(merge_rows(sessions), a.days, a.min, a.sort)  # one row per conversation

    if rest == ["cost"]:
        old = sorted({s["host"] for s in sessions if s.get("host") and s.get("usage") is None})
        notes = [f"{h}: no cost data from there yet (run: s hosts setup {h})" for h in old]
        cost_view(merge_rows(sessions), a.days, notes, 0 if a.all else a.top)
        return
    if rest == ["live"]:
        pool = select(sessions, a.days, 0, "recent")
        if a.json:
            print(json.dumps([to_json(s) for s in pool if running_of(s)], indent=1))
        else:
            live_view(pool)
        return
    if rest == ["jobs"]:
        pool = select(sessions, a.days, 0, "recent")
        if a.json:
            print(json.dumps([to_json(s) for s in pool if s["jobs"]], indent=1))
        else:
            jobs_view(pool)
        return
    if rest[:1] == ["transcript"] and len(rest) == 2:
        transcript_cmd(find(view, sessions, rest[1]), a, (a.grep or "").lower().split())
        return
    if rest[:1] == ["handoff"] and len(rest) <= 2:
        root = repo_root(rest[1] if len(rest) == 2 else os.getcwd())
        there = sorted((s for s in sessions if is_remote(s) and under(s.get("cwd"), [root])),
                       key=lambda s: s["last"], reverse=True)
        if not os.path.isdir(root) and there:  # the repository lives on another machine: write it there
            host = there[0]["host"]
            args = ["handoff", root, "--local", "-d", str(a.days)] + (["--" + target] if target else []) + (
                ["-p"] if a.print else []) + (["-n"] if a.dry_run else [])
            dest = HOSTS.get(host, host)
            print(c("2", f"→ {root} is on {host}; writing the handoff there"), file=sys.stderr)
            os.execvp("ssh", ["ssh", "-t", *CONTROL_OPTS, dest, f'"$SHELL" -lic {shlex.quote(REMOTE_S + " " + shlex.join(args))}'])
        print(c("2", f"reading every session about {root} ..."), file=sys.stderr)
        path, rows = repo_handoff(root, sessions)
        if not rows:
            sys.exit(f"no sessions worked in {root} in the last {a.days} days (try -d 365)")
        if a.print:
            with open(path) as f:
                print(f.read())
            return
        size = os.path.getsize(path)
        print(c("1", f"Handoff for {os.path.basename(root)}") + c("2", f"  {path}  (about {size // 4:,} tokens)"))
        for n, r in enumerate(rows[:8], 1):
            print(f"  {n:>2}. {fit(name(r), 50):<50}  {app_cell(r):<8} {rel(r['last']):<8} {hm((r.get('active') or 0) / 60):>6}"
                  + (c("35", f"  @{r['host']}") if r.get("host") else ""))
        if len(rows) > 8:
            print(c("2", f"      … and {len(rows) - 8} more"))
        if not target:
            print(c("2", "start a new session with it:  s handoff --claude   or   s handoff --codex"
                         "   (or give any session that path)"))
            return
        prompt = repo_prompt(path, rows)
        print(c("2", f"→ starting {APP_LABEL[target]} in {root} with it"))
        if a.dry_run:
            return
        os.chdir(root)
        os.environ["SESSIONS_CATCHUP_DONE"] = "1"
        if target == "claude":
            claude = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
            os.execvp(claude, [claude, "--add-dir=" + HANDOFF_DIR, *extra, prompt])
        sys.exit(run_codex([shutil.which("codex") or "codex", *codex_args(), *extra, prompt]))
    if rest and rest[0] in ("show", "path") and len(rest) == 2:
        s = find(view, sessions, rest[1])
        if rest[0] == "show":
            show(s)
        else:
            print(s.get("cwd") or HOME)
        return

    if a.json:
        # every session on its own (with its group), so the asking machine can merge and still see
        # which ones are running
        print(json.dumps([to_json(s) for s in select(sessions, a.days, a.min, a.sort)], indent=1))
        return

    query = " ".join(rest)
    if re.fullmatch(r"[0-9a-f][0-9a-f-]{7,}", query) and not a.print:
        exact = [s for s in sessions if s["id"].startswith(query)]
        if len({s["id"] for s in exact}) == 1:  # a session id opens exactly that session, even inside a chain
            # (on two machines when it was moved: the copy worked on last)
            resume(max(exact, key=lambda s: s["last"]), extra, a.dry_run, target)
            return
    if query.isdigit():
        resume(find(view, sessions, query), extra, a.dry_run, target)
        return
    if query:
        hits = [s for s in view if matches(s, query)]
        if len(hits) == 1 and not a.print:
            resume(hits[0], extra, a.dry_run, target)
            return
    else:
        hits = view

    if a.print:
        print_mode(hits)
        return
    if not hits:
        sys.exit(f"no sessions match '{query}' in the last {a.days} days (try -d 30 or -a)")
    if not sys.stdin.isatty():
        print_mode(hits)  # no terminal to pick from: behave like -p
        return

    window = {"days": a.days}

    def older():
        """The list reaching further back -> (rows, its window), or None when it covers everything."""
        global DAYS
        days = next((d for d in DAYS_STEPS if d > window["days"]), None)
        if days is None:
            return None
        print(c("2", f"loading the sessions of the {window_label(days)[5:] if days < 36500 else 'whole history'} ..."))
        found, _ = gather(days)
        window["days"] = DAYS = days
        return select(merge_rows(found), days, a.min, a.sort), window_label(days)

    if not a.no_fzf and shutil.which("fzf"):
        while True:
            further = next((d for d in DAYS_STEPS if d > window["days"]), None)
            chosen = pick_fzf(hits, os.path.abspath(__file__), window_label(further) if further else None)
            if chosen != "older":
                break
            rows, _ = older()
            hits = [s for s in rows if matches(s, query)] if query else rows
    else:
        chosen = pick_builtin(hits, query if len(hits) != len(view) else "", notes, window_label(a.days),
                              older, search)
    if chosen:
        s, picked = chosen
        resume(s, extra, a.dry_run, picked or target)


if __name__ == "__main__":
    main()
