# JediSec Termux Bootstrap

**v3.0 — Android / Termux only.**

The original [jedisec-bootstrap](https://github.com/jedisecX/jedisec-bootstrap) tried to be Termux + Debian + Fedora + Arch. The `ai` category installed `openai ollama chromadb`. That dies on a phone.

This repo is the lifeboat version:

- `pkg` only. Refuses to run outside Termux.
- Phone-sane package lists.
- `py:ai` = `openai` + `httpx`. No ollama daemon. No chromadb native build.
- Heavy toolchain (`clang` / `rust` / `golang`) is `--heavy` only.
- `pkg update` by default. `pkg upgrade` is `--upgrade` because it can kill the session.
- Logs + JSON summary under `~/.jedisec`.

## Quick start

```bash
pkg update -y
pkg install -y git
git clone https://github.com/jedisecX/jedisec-termux-bootstrap.git
cd jedisec-termux-bootstrap
chmod +x jedisec-termux-bootstrap.sh
bash jedisec-termux-bootstrap.sh --phone
```

If `pkg upgrade` murdered your last session, just reopen Termux and run `--phone` again. Already-installed packages are skipped.

## Profiles

| Flag | What it does |
|---|---|
| `--phone` | core + dev + android + py core/ai + dirs + storage + aliases + health |
| `--full` | every phone-safe sys + py category (not rust/clang) |
| `--heavy` | clang cmake ninja rust golang — opt-in, RAM hungry |
| `--upgrade` | `pkg upgrade -y` (can kill Termux) |

## CLI

```
bash jedisec-termux-bootstrap.sh --phone
bash jedisec-termux-bootstrap.sh --full --dry-run
bash jedisec-termux-bootstrap.sh --sys=core --py=ai
bash jedisec-termux-bootstrap.sh --sys=all --py=all
bash jedisec-termux-bootstrap.sh --heavy
bash jedisec-termux-bootstrap.sh --health
bash jedisec-termux-bootstrap.sh --update-self
bash jedisec-termux-bootstrap.sh --json --phone
```

No flags + a TTY = interactive menu.

### System categories

`core` `dev` `data` `media` `network` `osint` `android`

### Python categories

`core` `web` `data` `ai` `security` `db` `osint`

## Why AI failed on the old script

Old `PY_CATEGORIES[ai]`:

```
openai ollama chromadb
```

On Termux:

- `openai` — fine
- `ollama` pip package is a client stub; the daemon is a fat binary
- `chromadb` pulls hnswlib / onnx / rust and OOMs or fails to build on aarch64

This script does not install the last two.

Local models on a phone are a separate project (llama.cpp compile, or talk to a remote box). Do not pretend pip can summon a 7B model into Termux.

## Config override

`~/.jedisec/packages.conf` is sourced if present. Plain bash:

```bash
PY_CATEGORIES[ai]="openai httpx groq"
SYS_CATEGORIES[osint]="tesseract exiftool"
```

## Paths

| Path | Purpose |
|---|---|
| `~/.jedisec/logs/` | timestamped run logs |
| `~/.jedisec/state/last_run_summary.txt` | last run |
| `~/.jedisec/state/last_run_summary.json` | machine summary |
| `~/Projects/{JediSec,Scripts,AI,OSINT}` | created by `--phone` / `--dirs` |

## Related

- Desktop / multi-distro installer: https://github.com/jedisecX/jedisec-bootstrap
- JediSec: https://jedi-sec.com

---

JediSec · Termux lifeboat · 2026-09-26
