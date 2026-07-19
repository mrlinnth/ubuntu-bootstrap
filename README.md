# ubuntu-bootstrap

Modular bootstrap script for fresh Ubuntu 24.04 LTS servers.

## Usage

Download the script:
```
curl -fsSL https://raw.githubusercontent.com/mrlinnth/ubuntu-bootstrap/main/setup.sh -o /tmp/setup.sh
```

Interactive checklist:
```
bash /tmp/setup.sh
```

Run everything:
```
bash /tmp/setup.sh all
```

Run specific modules:
```
bash /tmp/setup.sh docker caddy
```

List modules:
```
bash /tmp/setup.sh --help
```

> **Note:** don't use the `bash <(curl -fsSL ...)` process-substitution
> one-liner — phase 2 (the user-phase handoff) needs to re-read `$0` to
> stage a copy for `sudo -u`, and that read can fail against a process
> substitution's pipe (`$0` ends up as something like `/dev/fd/63`),
> aborting the run after phase 1 (root modules) but before phase 2 (user
> modules) with no clear error. Downloading to a real file first avoids
> this entirely.

## Programs installed

**Root phase**
- **packages** — curl, git, wget, unzip, build-essential, htop, ncdu, jq, rsync, mosh, tmux, zsh, fail2ban, unattended-upgrades
- **caddy** — Caddy web server
- **docker** — Docker Engine, Docker Compose plugin
- **vnstat** — vnstat (bandwidth monitoring) + cron-based Telegram alert

**User phase**
- **zsh** — oh-my-zsh, zsh-autosuggestions, zsh-syntax-highlighting
- **dotfiles** — chezmoi (applies personal dotfiles from a private repo)
- **node** — Node.js via `n`
- **syncthing** — Syncthing (official apt repo), user service with linger
- **cli-tools** — zoxide, fzf, ripgrep, fd-find (via apt)
- **tui-tools** — helix (hx), yazi, lazygit, lazydocker (GitHub releases)
- **aichat** — aichat CLI from GitHub releases (sigoden/aichat)
- **claude-code** — Claude Code CLI
- **opencode** — OpenCode CLI
- **codex** — Codex CLI
- **telebash** — telebash CLI (Telegram messaging from the shell)

Modules that configure the system rather than install software (`timezone`, `swap`, `user`, `ssh-harden`, `unattended-upgrades`) aren't listed here — see `setup.sh --help` for the full module list including those.

## How it works

Runs as root over SSH. Two phases:
- **Root phase**: packages, caddy, docker, unattended-upgrades, timezone, swap, user creation, ssh-harden, vnstat
- **User phase**: hands off to the created user for zsh, dotfiles, node, syncthing, cli-tools, tui-tools, aichat, claude-code, opencode, codex, telebash

All modules are idempotent — safe to re-run.

## Notes

- `ssh-harden` disables root login and password auth. Reconnect as the new user (key-based) after it runs.
- `dotfiles` module applies personal dotfiles via chezmoi from a separate private repo, and will prompt for a GitHub PAT (or set `DOTFILES_TOKEN` env var to skip the prompt). Not required for the rest of the script.
- No credentials needed to fetch this script itself — it's public.

