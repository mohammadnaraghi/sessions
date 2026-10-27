<h1 align="center">sessions</h1>

<p align="center">
  Find, watch and resume every <a href="https://claude.com/claude-code">Claude Code</a> and Codex session you have, on every machine you own. One command: <code>s</code>.
</p>

<p align="center">
  <img alt="macOS and Linux" src="https://img.shields.io/badge/macOS%20%C2%B7%20Linux-supported-2ea44f">
  <img alt="Python 3.8+" src="https://img.shields.io/badge/python-3.8%2B-3776ab">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-2ea44f">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-lightgrey">
</p>

<p align="center">
  <img src="docs/picker.svg" width="100%" alt="The s picker: every session on every machine in one list">
</p>

Claude Code and Codex keep each session inside the folder it was started in, so their resume
pickers only ever show you one folder's worth. `s` puts all of them in one list: what each
session was about, how much real work went into it, which ones are running right now, and which
ones have scheduled jobs ticking inside them. Type a number and you are back in that session,
even when it lives on another computer, and in either tool.

## Highlights

- **One list for everything.** Every project, newest first, with the session's name, the hours
  you actually spent in it, and the last thing you asked. Filter by typing, and reach further
  back in time without leaving the list.
- **Find anything you ever asked.** `s search` looks through every prompt you wrote, in every
  session on every machine, however old, and takes you straight back to that conversation.
- **Claude Code and Codex in one list.** If you also use the Codex CLI, its sessions show up
  beside your Claude ones, and any session can be continued in the other tool. A conversation
  that moved between the two stays one row and opens wherever you worked on it last.
- **Every return starts from the whole story.** Go Claude, then Codex, then Claude again: each
  session you come back to keeps its own history and is told what the others did since it last
  saw them (where they ended, what they changed, what went wrong), however you open it.
- **Hand a repository to a new session.** `s handoff` writes one overview of everything done in
  a repository, in both tools on every machine, with any detail one command away.
- **One memory for both tools.** The companion `ai-bridge` shares memories and MCP servers
  between Claude Code and Codex, with nothing to run once it is set up.
- **See what is running.** `s live` shows each open session: busy or idle, what you asked,
  what it is doing this second, the last thing it said, and how far through its checklist it is.
- **What it costs.** `s cost` charts what your sessions would cost at API list prices, per
  day, week and month, by model and by session, across both tools and all your machines.
- **Scheduled jobs, tracked.** Sessions that set up cron jobs are marked. You see the schedule,
  how many times it has fired, and whether it is still alive or died with the terminal.
- **Your other computers too.** Add a machine once; its sessions join the list. Resuming one
  opens it there over ssh. Sessions running inside tmux are attached, not duplicated.
- **Memories and settings travel with you.** Keep two machines in step with one command,
  in both directions, for Claude Code and Codex alike, with a plan shown first and backups kept.
- **Private by design.** Plain Python files, no dependencies, no accounts, no servers. They read
  what Claude Code and Codex already store on your disk and talk only to machines you name.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mohammadnaraghi/sessions/main/install.sh | sh
```

That is the whole setup. It needs `python3` and Claude Code, puts `s` in `~/.local/bin` (with
its companion `ai-bridge`, which does nothing until you run its setup; see
[below](#shared-memory-between-claude-code-and-codex)), and tells you if that folder is not on
your `PATH` yet. Open a new terminal and type `s`.

- Update any time with `s update` (it updates `ai-bridge` too)
- Remove with `rm ~/.local/bin/s ~/.local/bin/ai-bridge`

If you have [fzf](https://github.com/junegunn/fzf) installed, `s` uses it automatically for
fuzzy search with a live preview.

## What is running right now

<p align="center">
  <img src="docs/live.svg" width="100%" alt="s live: open sessions, what they are doing, and their jobs">
</p>

`s live` is the view you want when you come back to your desk. For every open session, on
every machine, it tells you what you asked for, which command it is running, what it last
reported, and the checklist progress when the session keeps one. Scheduled jobs that are still
alive are listed underneath.

## Scheduled jobs

<p align="center">
  <img src="docs/jobs.svg" width="100%" alt="s jobs: every scheduled job and whether it is alive">
</p>

Jobs scheduled inside a Claude Code session only run while that session is open, and they stop
after a week. That is easy to forget. `s jobs` lists every job you ever set up with its
schedule, how many of its possible runs have happened, and a plain status: live, waiting,
done, expired, cancelled, or dead because the terminal closed.

## Hand a repository to a new session

<p align="center">
  <img src="docs/handoff.svg" width="100%" alt="s handoff: one overview of everything done in a repository">
</p>

`s handoff` (in a repository, or `s handoff ~/code/api`) writes one document for a new session
about everything done there, in Claude Code and Codex, on every machine:

- the repository now: branch, uncommitted work, latest commits, recent branches, worktrees and
  open pull requests
- what Claude remembers about the project
- every conversation about it, latest first: what it set out to do, what you last asked, where it
  ended, the files it changed, the last problem it hit, an unfinished checklist
- the latest conversation in more detail
- how to read any detail on demand

It is an overview on purpose: big enough to know what happened and where things stand, small
enough to read at once. A detail is one command away, `s transcript <session id>`: a session as a
document (where it ended, files it changed, problems it hit, the latest part of the
conversation), with `--all` for all of it, `--grep WORDS` for the parts about something and
`--since 2d` for the recent part, for sessions on any machine in either tool. `s handoff
--claude` (or `--codex`) starts the new session with it and asks it to say what the repository
is, where it stands and what looks unfinished or fragile.

## Find anything you ever asked

<p align="center">
  <img src="docs/search.svg" width="100%" alt="s search: every conversation with a prompt that has the words">
</p>

`s search stripe paywall` finds every prompt you wrote with all of those words, in any session,
on any of your machines, from today back to the oldest transcript on disk. You get one row per
conversation, with the matching prompt and the words highlighted, newest match first, and a
number takes you back into it like anywhere else. In the picker, `?stripe paywall` does the same
without leaving it, and `?` returns to the list.

The first search reads your whole history once, a few seconds. After that a search takes a
fraction of a second, because `s` keeps an index of your prompts (`~/.cache/sessions/prompts.json`)
and only reads what was added since.

The list itself covers the last two weeks. Type `o` in the picker (or `n` past the last page) to
reach further back: 30 days, 90 days, a year, then everything. With fzf it is alt-o.

## Every detail of a session

<p align="center">
  <img src="docs/show.svg" width="100%" alt="s show: the full picture of one session">
</p>

`s show 2` gives you the full picture before you jump in: when it started, how the work was
spread across days, the first and latest prompts, its jobs, and the exact command that resumes
it.

## What it costs

<p align="center">
  <img src="docs/cost.svg" width="100%" alt="s cost: spend per day, week and month, by model and by session">
</p>

`s cost` shows what your sessions would cost at API list prices: what the same tokens would
cost on the pay-as-you-go API, not what a subscription charges you. You get a bar chart per
day, per week and per month (Claude Code and Codex in different colours), the split by model,
and the sessions that cost the most, on every machine you added. It covers the last 30 days;
`-d 90` looks further back, `-a` lists every session, and `s show 3` gives one session's cost.

The numbers are worked out from the tokens each response used, as recorded in the transcripts:
input, output, both cache-write lengths and cache reads, fast mode, US-only inference and web
searches, at Anthropic's and OpenAI's published per-model prices (the date is printed with the
result). A session's subagents and workflow agents count toward it (in Codex too: its subagent
and reviewer threads count toward the thread they worked for), and a conversation that moved
between the tools counts once. Checked against the cost snapshots Claude Code keeps in its
transcripts, they match to the cent for most sessions; the calls Claude Code makes for itself,
such as titles and compaction, are not in its transcripts, so Claude totals can read slightly low.

## Claude Code and Codex

When the [Codex CLI](https://github.com/openai/codex) or the ChatGPT app has been used, its
sessions join the list with an `app` column. `s` reads them straight from Codex's own session
index and files (read-only, cached per thread) and never starts Codex to look. Every `codex`
process shares, and may refresh, your ChatGPT login, and extra ones racing to refresh it can sign
the rest out. Picking a session runs `codex resume` in its folder.

Any session can also be continued in the other tool:

- `s 3 --codex` (or `x 3` in the picker) imports a Claude conversation into Codex as a new
  thread, with the whole history, using Codex's own importer, and opens it. A conversation too
  big for Codex to take whole (over about 150k tokens; Codex models read about 272k) starts a
  fresh Codex thread on Claude's own summary of the earlier work plus the most recent part.
- `s 3 --claude` (or `c 3`) writes the Codex conversation out as a transcript and starts
  Claude Code in the same folder, asking it to read the transcript and say where things stand.
- When the conversation already has a session in the tool you pick (it came from there, or
  went there before), that session is resumed instead of starting a new one. It keeps its own
  full history, and gets just what the rest of the conversation did since it last saw it: from
  every other session of it, in either tool, oldest first. For each one: where it ended, the
  files it changed, the problems it hit, Claude's own summary of any part left out, and the
  conversation; then the working tree now and the commits since. A short catch-up is in its
  first message; a long one is a file it reads, and `s transcript` pulls any part in full.

With `ai-bridge` set up, the same catch-up happens however you open a session: `claude
--resume`, `codex resume`, or the ChatGPT app. As a session resumes, its start hook asks `s`
what the rest of the conversation did since that session was last caught up, and adds it to
the session's context. A session you keep open gets it too: when you send it a message after
working in the other tool, a per-message hook adds what happened there to that message. It
costs nothing when nothing happened: the hook only looks at whether the other sessions' files
changed, and asks `s` when one did (or every few minutes). So you can keep Claude and Codex open
side by side, or go Claude, then Codex, then Claude again, and every turn starts from the whole
story. Codex asks you once to review its new hooks (`/hooks`, or "Trust all and continue" when
it starts); `s sync` then carries that approval to your other machine.

What a catch-up holds for each other session: where it ended, the files it changed, what
changed in the repository while it worked (commits and uncommitted files, which covers edits
made through shell commands), the problems it hit, its subagents' reports, Claude's own summary
of any part left out, and as much of the conversation as fits; then the working tree now.

A conversation that moved between the tools stays one row, marked `⇄`, with the work of both
added up. Its number always opens wherever you worked on it last, in that tool, so you never
land in a stale copy. `s show` lists every step of the chain, and `s <session id>` opens one
particular step. `s` recognises the moves it makes itself, Codex's own `/codex:transfer`
imports, and a session that read the other tool's transcript to pick up where it left off.

`s codex` and `s claude` filter the list by tool. Set `SESSIONS_CODEX_ARGS` to pass flags to
every Codex that `s` starts, for example `export SESSIONS_CODEX_ARGS="-p work"` for a profile.

Codex sometimes refuses to start with `account/read failed ... unauthorized (401)`. That
happens when its ChatGPT login was refreshed a moment earlier by another Codex process, such as
the ChatGPT app. A Codex that `s` starts tries once more after a few seconds, and so does
`codex` in a shell set up by `ai-bridge`. If it still fails, `codex login` signs in again. Use
the same ChatGPT account in the app and the CLI: they share one login.

## Shared memory between Claude Code and Codex

`ai-bridge`, installed next to `s`, makes the two tools work as one. Run it once:

```sh
ai-bridge setup                       # or: ai-bridge setup --model gpt-6.1-sol
```

From then on there is nothing to run. You start `claude` or `codex` as usual, anywhere, and:

- **Codex knows what Claude knows.** Each Codex session starts with Claude Code's memories for
  that project, and saves what it learns in Claude's own memory format.
- **Claude learns what Codex learned.** When Claude Code starts in a project, Codex's new
  memories are added to its memory, and Claude is told about them.
- **One set of MCP servers.** The MCP servers you add to Claude Code are copied into Codex: your
  own ones into `~/.codex/config.toml`, a project's `.mcp.json` and local servers into that
  project's `.codex/config.toml` (kept out of git). Servers that sign in with OAuth need a
  sign-in once per tool and per machine: `ai-bridge mcp-login` signs both tools in to every one
  that needs it. On another machine run it over `ssh -t`: no browser opens there, so you open
  the link it prints, sign in, and paste back the address you land on (a Mac's keychain, where
  the sign-ins are kept, is locked over ssh until you unlock it, which it offers to do).
  `s hosts setup` tells you which servers still need a sign-in there.
- **Pick up where the other left off.** A session you resume is told what its conversation
  did in the other tool (or another session) since it last saw it, without asking. A new
  session is told about the other tool's latest session in the folder; ask it to continue where
  Claude or Codex left off and it reads the transcript.
- **Your model by default.** In zsh, `codex` starts with the bridge's profile (GPT-6 Astra, or
  the `--model` you gave setup), and so do the Codex sessions `s` starts.

| Command | What it does |
|---|---|
| `mem` | what each tool remembers about this folder, and what Codex saved since |
| `mem pull` · `mem show` | move Codex's new memories into Claude now · see what Codex is given |
| `to-codex` · `to-claude` | continue this folder's latest session in the other tool (like `s N --codex` / `--claude`) |
| `cx` | `codex` with the bridge's profile, from shells other than zsh |
| `ai-bridge sync` | copy Claude's MCP servers into Codex now |
| `ai-bridge mcp-login` | sign both tools in to every MCP server that needs it here (`--check` to only list them) |
| `ai-bridge update` | the latest release (`s update` does this too) |

### Which memory is which

Five things get called memory, and only some of them reach your coding sessions:

| Where | What it is | Who reads it |
|---|---|---|
| `~/.claude/CLAUDE.md`, a project's `CLAUDE.md` | instructions you write | Claude Code always; Codex too with `ai-bridge` |
| `~/.claude/projects/<project>/memory/` | what Claude learns as it works, per project (an index plus one file per memory) | Claude Code; Codex too with `ai-bridge`, which also brings back what Codex learns |
| `~/.codex/AGENTS.md`, a project's `AGENTS.md` | instructions for Codex | Codex |
| Codex's own memories (`memories = true` under `[features]`) | a separate store Codex writes in the background | Codex only |
| Your ChatGPT and claude.ai account memory | what the chat apps remember about you | the ChatGPT and Claude chat apps, not Codex or Claude Code |

With `ai-bridge`, keep one store: Claude Code's memory, which both tools read and write and
`s sync` keeps the same on your machines. Leave Codex's own memories off, or they become a second
store Claude never sees. Put rules that must always hold in `CLAUDE.md` or `AGENTS.md`, not in
memory. Account memory only affects the chat apps, so turn it on or off for them alone; if you
have more than one ChatGPT account, each keeps its own.

Setup links those commands next to `ai-bridge` and edits, after backing each one up as
`*.bak-ai-bridge-<time>`: SessionStart and UserPromptSubmit hooks in `~/.claude/settings.json`,
the same two in `~/.codex/hooks.json` (Codex asks you to trust them the first time), a marked block in
`~/.zshrc`, and `~/.codex/config.toml` (Codex may write its memories, and reads `CLAUDE.md` when
a repository has no `AGENTS.md`). To undo it, remove those hook entries and the marked blocks.
`s hosts setup NAME` copies `ai-bridge` to that machine as well and refreshes it there when it
is already set up.

## Your other computers

```sh
s hosts add studio sam@studio.local   # a name you choose, then the ssh address
s hosts setup studio                  # copies s over, done
```

<p align="center">
  <img src="docs/hosts.svg" width="100%" alt="s hosts: each machine, reachable, ready">
</p>

From then on the other machine's sessions sit in the same list with a host column, and
`s live` and `s jobs` cover it as well. Picking one of its sessions starts it there inside
tmux, so closing your laptop only detaches you: the session and its scheduled jobs keep
running, and picking it again drops you back into the same window. A session that is already
running there is attached to, never started twice. Add as many machines as you like, Mac or
Linux, any names you want. It needs ssh with keys, the normal setup between your own machines,
and tmux on the other machine for the keep-running part (`brew install tmux` or
`apt install tmux`; without it `s` still resumes over plain ssh and says so).

Want the same safety on this machine? `s --tmux 3` runs a local session inside tmux too.

## Keep two machines in sync

<p align="center">
  <img src="docs/sync.svg" width="100%" alt="s sync: the plan for both machines, before anything changes">
</p>

Claude Code learns things about you and your projects as you work, and keeps them on the
machine you were using. `s sync studio` carries that knowledge, plus your settings, across
both machines in both directions:

- what Claude remembers about each project, and about you (which, with `ai-bridge`, is also
  what Codex remembers)
- your Claude Code settings, instructions, key bindings, custom commands, agents, hooks and skills
- your MCP server list (which `ai-bridge` then gives Codex too)
- Codex's instructions (`AGENTS.md`), hooks and command rules, and the settings in its
  `config.toml` and profiles that belong to you rather than to the machine: model, reasoning
  effort, approvals and permissions, trusted folders and hook approvals. The ChatGPT app's own
  window preferences, plugin paths and feature flags stay as they are on each machine.

Nothing changes until you have seen the plan and said yes. Newer copies win (`--prefer local`
lets this machine win instead), settings and memory indexes are merged rather than overwritten,
something you deleted on one machine is removed from the other, and everything replaced is kept
in a dated backup folder first.
Setting up a brand new machine is `s migrate to studio`, which copies everything over and
deletes nothing.

## Cheat sheet

| Command | What it does |
|---|---|
| `s` | the picker: last two weeks, newest first |
| `s 3` | resume number 3, wherever you last worked on it |
| `s 3 --codex` · `s 3 --claude` | continue number 3 in Codex · in Claude Code |
| `s 1a2b3c4d` | open exactly that session (by id), even one step of a `⇄` chain |
| `s tiktok` | filter by any word; resumes at once if only one matches |
| `s search stripe paywall` | every prompt you ever wrote with those words, on every machine |
| `s handoff` · `s handoff --claude` | a handoff of everything done in this repository · and start a new session with it |
| `s transcript 1a2b3c4d --grep auth` | read any session (or the parts about something) on demand |
| `s running` · `s cron` · `s @studio` | only running sessions, only sessions with jobs, only one machine |
| `s codex` · `s claude` | only Codex sessions · only Claude Code sessions |
| `s cost` | spend at API list prices per day, week and month, by model and session |
| `s live` | what every open session is doing |
| `s jobs` | every scheduled job and its status |
| `s show 3` | the full story of one session |
| `s hosts add NAME user@host` | add another machine, then `s hosts setup NAME` |
| `s sync NAME` | two-way sync of memories and settings, `-n` for a dry run |
| `s migrate to NAME` | set up a new machine from this one |
| `s -d 30` · `s -a` | look back 30 days · show every session, however short |
| `s --tmux 3` | run a local session inside tmux so it survives closing the window |
| `s 3 -- --model opus` | pass extra flags to Claude Code (or Codex) |
| `ai-bridge setup` | share memory and MCP servers between Claude Code and Codex (once) |
| `mem` | what Claude and Codex remember about this folder |

Inside the picker: a number resumes, `c 3` and `x 3` continue in Claude Code or Codex, `s 3`
shows details, `/text` filters, `?text` searches every prompt, `n` and `p` page, `o` reaches
further back, `q` quits. With fzf: enter resumes, alt-c and alt-x continue in Claude Code or
Codex, alt-o reaches further back.

## Questions

**Does anything leave my machine?** No. There is no account, no server and no telemetry. The
only network traffic is ssh to machines you added yourself, and the update check when you run
`s update`.

**I use more than one Claude account.** That is fine. Sessions are files on your disk, not
tied to an account, so `s` sees all of them and resumes any of them.

**Will it slow things down?** The first run reads your history once, a few seconds. After that
it opens instantly. Other machines get about a second to answer; one that is asleep or slow is
shown as of its last answer while a fresh one is fetched in the background, and the ssh
connection is kept open for a few minutes so the next run skips the handshake.

**Can I name my machines whatever I want?** Yes. The name is just a label you type; the ssh
address can be a hostname, an IP, or an alias from your ssh config.

**Does resuming change anything?** It runs the same `claude --resume` or `codex resume` you
would type yourself, in the session's own folder. The only addition: when the rest of the
conversation went on without that session, its first message (or, with `ai-bridge`, its start
context) says what happened meanwhile. Continuing in the other tool resumes the conversation's
own session there if it has one, and otherwise creates a new session there; the original is
left untouched either way.

**Why `s`?** It is the shortest thing to type when all you want is to get back to work. The
project is called sessions.

## Requirements

- macOS or Linux
- Python 3.8 or newer, which both already have (3.11 or newer for `ai-bridge setup`)
- Claude Code, and optionally the Codex CLI

## License

MIT
