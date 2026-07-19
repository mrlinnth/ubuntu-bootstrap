# AGENTS.md

## Repo structure

- `setup.sh` — single-file modular bootstrap (1086 lines, 20 modules)
- `README.md` — usage docs

No tests, no CI, no build step. All changes go into `setup.sh`.

## Architecture

Two-phase dispatch via `main()`:
- **Root phase** (9 modules): runs as root inline
- **User phase** (11 modules): hands off via `sudo -u yan` with a staged copy of the script in `/tmp`

Module catalog is ordered — execution order matches catalog order regardless of selection order.

## Key gotchas

- **Never use `bash <(curl ...)` process substitution** — `$0` becomes `/dev/fd/63` and phase 2's `cp "$0"` fails silently. Download to a file first (`curl -fsSL ... -o /tmp/setup.sh`).
- **`sudo -u` does NOT use `-E`** — only `DOTFILES_TOKEN` is forwarded via `env`. Root's `HOME` is not leaked to the user phase.
- **User-phase modules** run without a user D-Bus session after `sudo` handoff. `mod_syncthing` sets `XDG_RUNTIME_DIR` explicitly for `systemctl --user`.
- **GitHub API rate limit** — `github_latest_asset_url()` hits the unauthenticated API (60 req/hr). A full run makes 5 calls. Set `GITHUB_TOKEN` to raise the limit.
- **`mod_vnstat`** warns if `telebash` wasn't selected in the same run (cron needs it).
- **`mod_telebash`** and `ensure_local_bin()` both write `/etc/profile.d/yan-local-bin.sh` and `/etc/zsh/zprofile`.
- **`mod_cli_tools`** symlinks `fdfind` → `fd` in `~/.local/bin` (Debian names it fdfind).
- **`mod_node`** bootstraps via apt Node.js, then removes the apt packages after `n lts`.
- **`mod_tui_tools`** handles helix manually (binary is `hx`, needs `runtime/` dir).

## Conventions

- All modules are **idempotent** — guard with `command -v`, file/dir existence, or `grep -qF` before acting.
- User-phase helpers: `ensure_local_bin`, `release_arch_pattern`, `github_latest_asset_url`, `install_github_binary`.
- Module names use hyphens in the catalog, function names use underscores (`mod_name` → `mod_name` transforms inside phase2 dispatch).
