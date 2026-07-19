#!/usr/bin/env bash
# =============================================================================
# Server Bootstrap Script (modular)
# Target: Ubuntu 24.04 LTS
#
# Usage:
#   bash setup.sh                       # interactive checklist
#   bash setup.sh docker caddy          # run specific modules
#   bash setup.sh all                   # run every module
#   bash setup.sh --help                # list modules
#
# This script itself lives in the public ubuntu-bootstrap repo, so it can be
# fetched with a plain curl — no token needed for that part.
#
# If the 'dotfiles' module is included and DOTFILES_TOKEN isn't already set
# in the environment, you'll be prompted to enter your GitHub PAT at the
# terminal (input hidden, same as the Telegram bot token prompt). This token
# is only for chezmoi to clone the private dotfiles repo, not for fetching
# this script. Pass it via env instead if you want to skip the prompt, e.g.
# for unattended runs:
#   DOTFILES_TOKEN="ghp_xxxx" bash setup.sh dotfiles
#
# Remote one-liner — download first, then run (don't use
# `bash <(curl ...)`: phase 2 re-reads $0 to stage a copy for `sudo -u`,
# which fails against a process-substitution pipe and aborts the run
# after phase 1 but before phase 2):
#   curl -fsSL \
#     https://raw.githubusercontent.com/mrlinnth/ubuntu-bootstrap/main/setup.sh \
#     -o /tmp/setup.sh && bash /tmp/setup.sh
#
# Or pass modules (or 'all') directly:
#   curl -fsSL \
#     https://raw.githubusercontent.com/mrlinnth/ubuntu-bootstrap/main/setup.sh \
#     -o /tmp/setup.sh && bash /tmp/setup.sh all
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

USERNAME="yan"
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLqeQQXVi4u+rmYMAV/gs9a8gw4vB7ks2IF3J0QQ47xxILeCoEVktRcZNux/1v8FicED7niq9k53pKEQIuCpGtmq8eMV5AHGYe8KMJ07vCCc8a/IuF5JmOyUkoQQ3cgSwya1/a1SqaQ07kftKIJ86tyG+EQepSEqP7Vf+no2wp4xoaDWql7xej4JKQMXeLRcJ018TcAG1SieMBDmznp0PT4ybCwMwhofNdKV5d2tZoDXdocsKCKqSIFw/yWY4XeLI8JwDmDYMM5mqTvlz6OnFTc+UveblXTV3bcsvN1ixr7bp19R1DXUJ9pdjgFyPMAWhMYlCbr0gAGTkpfgPUMxUP yanlinnthor@YLT-ASUSMINT"
# DOTFILES_TOKEN may come from the env, or be prompted for interactively by
# require_token() when the 'dotfiles' module runs — see dotfiles_repo_url()
# below, which builds the clone URL from whatever value is set at call time.
TIMEZONE="Asia/Yangon"
SWAP_SIZE="2G"
SWAP_FILE="/swapfile"
# Primary network interface for the vnstat bandwidth alert. Left unset by
# default — mod_vnstat auto-detects it from the default route (see
# detect_primary_interface()). Set this only if auto-detection picks the
# wrong interface on a given VPS provider, e.g.:
#   VNSTAT_INTERFACE="ens5" bash setup.sh vnstat
VNSTAT_INTERFACE="${VNSTAT_INTERFACE:-}"

# =============================================================================
# MODULE CATALOG
# Format: name|phase|description
# phase is either "root" (runs in phase 1, as root) or "user" (runs in
# phase 2, as USERNAME). Order here is the execution order — later modules
# may depend on earlier ones (e.g. "user" checks for docker group before
# "docker" would exist if run out of order, so we always execute in this
# canonical order regardless of how modules were selected).
# =============================================================================

MODULE_CATALOG=(
    "packages|root|Update apt and install base packages (git, curl, tmux, fail2ban, etc.)"
    "caddy|root|Install Caddy web server"
    "docker|root|Install Docker Engine and Compose plugin"
    "unattended-upgrades|root|Enable automatic security updates"
    "timezone|root|Set timezone to ${TIMEZONE}"
    "swap|root|Create a ${SWAP_SIZE} swap file"
    "user|root|Create ${USERNAME} user, sudo/docker groups, install SSH key"
    "ssh-harden|root|Disable root login and password auth over SSH"
    "vnstat|root|Install vnstat and set up a bandwidth alert via telebash every 4h (auto-detects the network interface, prompts for a server label)"
    "zsh|user|Install oh-my-zsh and plugins"
    "dotfiles|user|Apply dotfiles via chezmoi (will prompt for GitHub PAT if DOTFILES_TOKEN isn't set)"
    "node|user|Install Node.js via n"
    "syncthing|user|Install syncthing (official apt repo), enable user service with linger, create ~/syncthing"
    "cli-tools|user|Install CLI tools via apt (zoxide, fzf, ripgrep, fd)"
    "tui-tools|user|Install TUI tools from GitHub releases (helix, yazi, lazygit, lazydocker)"
    "aichat|user|Install aichat from GitHub releases"
    "claude-code|user|Install Claude Code CLI"
    "opencode|user|Install OpenCode CLI"
    "codex|user|Install Codex CLI"
    "telebash|user|Install telebash CLI and save Telegram bot token + favorites"
)

# =============================================================================
# HELPERS
# =============================================================================

log()  { echo "" >&2; echo "==> $*" >&2; }
info() { echo "    $*" >&2; }
err()  { echo "Error: $*" >&2; }

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "Must run as root."
        exit 1
    fi
}

# Finds the interface carrying the default route — the interface with real
# internet traffic on it, which is what the vnstat bandwidth alert cares
# about. Falls back to the first non-loopback interface if there's no
# default route for some reason (e.g. a box behind unusual routing).
detect_primary_interface() {
    local iface
    iface="$(ip -4 route show to default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [[ -z "${iface}" ]]; then
        iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')"
    fi
    echo "${iface}"
}

# Prompts once for a short label to prefix bandwidth alert messages with
# (useful once you're running this on more than one server), defaulting to
# the machine's hostname if the person just hits enter.
require_server_label() {
    if [[ -z "${SERVER_LABEL:-}" ]]; then
        local default_label
        default_label="$(hostname -s 2>/dev/null || hostname)"
        read -rp "Server identifier for bandwidth alerts [${default_label}]: " SERVER_LABEL
        SERVER_LABEL="${SERVER_LABEL:-${default_label}}"
        export SERVER_LABEL
    fi
}

require_token() {
    if [[ -z "${DOTFILES_TOKEN:-}" ]]; then
        echo "" >&2
        read -rsp "Enter your GitHub PAT (for the dotfiles repo, e.g. ghp_xxxx): " DOTFILES_TOKEN
        echo "" >&2
        export DOTFILES_TOKEN
    fi
    if [[ -z "${DOTFILES_TOKEN:-}" ]]; then
        err "A GitHub PAT is required for the 'dotfiles' module."
        exit 1
    fi
}

# Builds the chezmoi clone URL from the current DOTFILES_TOKEN. Called lazily
# (not assigned once at the top of the script) because DOTFILES_TOKEN may not
# be known until require_token() has prompted for it.
dotfiles_repo_url() {
    echo "https://oauth2:${DOTFILES_TOKEN:-}@github.com/mrlinnth/dotfiles.git"
}

# Looks up the phase for a module name. Echoes phase and returns 0 if found,
# returns 1 if the module name doesn't exist in the catalog.
module_phase() {
    local target="$1" name phase desc
    for entry in "${MODULE_CATALOG[@]}"; do
        IFS='|' read -r name phase desc <<< "$entry"
        if [[ "$name" == "$target" ]]; then
            echo "$phase"
            return 0
        fi
    done
    return 1
}

print_modules() {
    local i=1 name phase desc
    for entry in "${MODULE_CATALOG[@]}"; do
        IFS='|' read -r name phase desc <<< "$entry"
        printf "  %2d) [%-4s] %-22s %s\n" "$i" "$phase" "$name" "$desc" >&2
        ((i++))
    done
}

print_help() {
    echo "Usage: setup.sh [module ...]" >&2
    echo "       setup.sh              (interactive checklist)" >&2
    echo "       setup.sh all          (run every module)" >&2
    echo "       setup.sh --help" >&2
    echo "" >&2
    echo "Available modules:" >&2
    print_modules
}

validate_modules() {
    local m
    for m in "$@"; do
        if ! module_phase "$m" >/dev/null; then
            err "Unknown module: $m"
            echo "Available modules:" >&2
            print_modules
            exit 1
        fi
    done
}

# Echoes every module name in the catalog, space-separated.
all_module_names() {
    local name phase desc
    local -a names=()
    for entry in "${MODULE_CATALOG[@]}"; do
        IFS='|' read -r name phase desc <<< "$entry"
        names+=("$name")
    done
    echo "${names[@]}"
}

# Prints a numbered checklist to stderr, reads a selection from stdin, and
# echoes the selected module names (space-separated) to stdout.
interactive_select() {
    local i=1 name phase desc
    local -a names=()
    # shellcheck disable=SC2207
    names=($(all_module_names))

    echo "" >&2
    echo "Select modules to run:" >&2
    echo "" >&2
    for entry in "${MODULE_CATALOG[@]}"; do
        IFS='|' read -r name phase desc <<< "$entry"
        printf "  %2d) [%-4s] %-22s %s\n" "$i" "$phase" "$name" "$desc" >&2
        ((i++))
    done
    echo "" >&2
    echo "Enter numbers separated by spaces or commas, or 'all':" >&2
    read -rp "> " reply

    reply="${reply//,/ }"
    local -a selected=()
    if [[ "$reply" == "all" ]]; then
        selected=("${names[@]}")
    else
        local token
        for token in $reply; do
            if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#names[@]} )); then
                selected+=("${names[$((token - 1))]}")
            else
                info "Ignoring invalid selection: $token"
            fi
        done
    fi
    echo "${selected[@]}"
}

# Splits the given module names into the global ROOT_MODULES and
# USER_MODULES arrays, in canonical catalog order (not selection order).
build_ordered_lists() {
    local -a selected=("$@")
    local name phase desc s
    ROOT_MODULES=()
    USER_MODULES=()
    for entry in "${MODULE_CATALOG[@]}"; do
        IFS='|' read -r name phase desc <<< "$entry"
        for s in "${selected[@]}"; do
            if [[ "$s" == "$name" ]]; then
                if [[ "$phase" == "root" ]]; then
                    ROOT_MODULES+=("$name")
                else
                    USER_MODULES+=("$name")
                fi
            fi
        done
    done
}

# =============================================================================
# ROOT-PHASE MODULES
# =============================================================================

mod_packages() {
    log "Updating system packages"
    apt-get update -qq
    apt-get upgrade -y -qq

    log "Installing base packages"
    apt-get install -y -qq \
        curl \
        git \
        wget \
        unzip \
        build-essential \
        htop \
        ncdu \
        jq \
        rsync \
        mosh \
        tmux \
        zsh \
        fail2ban \
        unattended-upgrades
}

mod_caddy() {
    log "Installing Caddy"
    if ! command -v caddy &>/dev/null; then
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq
        apt-get install -y -qq caddy
        info "Caddy installed: $(caddy version)"
    else
        info "Caddy already installed, skipping"
    fi
}

mod_docker() {
    log "Installing Docker"
    if ! command -v docker &>/dev/null; then
        apt-get install -y -qq ca-certificates
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
            https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
        systemctl enable docker
        systemctl start docker
        info "Docker installed: $(docker --version)"
    else
        info "Docker already installed, skipping"
    fi
}

mod_unattended_upgrades() {
    log "Enabling automatic security updates"
    dpkg-reconfigure -f noninteractive unattended-upgrades
}

mod_timezone() {
    log "Setting timezone to ${TIMEZONE}"
    timedatectl set-timezone "${TIMEZONE}"
    info "Timezone: $(timedatectl show --property=Timezone --value)"
}

mod_swap() {
    log "Creating swap file (${SWAP_SIZE})"
    if [[ ! -f "${SWAP_FILE}" ]]; then
        fallocate -l "${SWAP_SIZE}" "${SWAP_FILE}"
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}"
        swapon "${SWAP_FILE}"
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        info "Swap created and enabled"
    else
        info "Swap file already exists, skipping"
    fi
}

mod_user() {
    log "Creating user: ${USERNAME}"
    if ! id "${USERNAME}" &>/dev/null; then
        adduser --disabled-password --gecos "" "${USERNAME}"
        usermod -aG sudo "${USERNAME}"
        if command -v docker &>/dev/null; then
            usermod -aG docker "${USERNAME}"
        fi
        echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
        chmod 440 "/etc/sudoers.d/${USERNAME}"
        info "User ${USERNAME} created with sudo (and docker if installed) access"
    else
        info "User ${USERNAME} already exists, ensuring group memberships"
        usermod -aG sudo "${USERNAME}"
        if command -v docker &>/dev/null; then
            usermod -aG docker "${USERNAME}"
        fi
    fi

    if command -v zsh &>/dev/null; then
        chsh -s "$(which zsh)" "${USERNAME}"
        info "Login shell set to zsh"
    fi

    log "Configuring SSH access for ${USERNAME}"
    local ssh_dir="/home/${USERNAME}/.ssh"
    mkdir -p "${ssh_dir}"
    echo "${SSH_PUBLIC_KEY}" > "${ssh_dir}/authorized_keys"
    chmod 700 "${ssh_dir}"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${USERNAME}:${USERNAME}" "${ssh_dir}"
    info "SSH public key installed"
}

mod_ssh_harden() {
    log "Hardening SSH configuration"

    # Refuse to disable password auth if there's no key-based access in
    # place yet — otherwise this can lock you out of the server entirely.
    if [[ ! -s "/home/${USERNAME}/.ssh/authorized_keys" && ! -s "/root/.ssh/authorized_keys" ]]; then
        err "No authorized_keys found for ${USERNAME} or root. Refusing to disable password auth — this would lock you out."
        err "Run the 'user' module first (or include it in this run)."
        exit 1
    fi

    local sshd_config="/etc/ssh/sshd_config"
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "${sshd_config}"
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "${sshd_config}"
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "${sshd_config}"
    systemctl restart ssh
    info "SSH hardened: root login disabled, password auth disabled"
}

mod_vnstat() {
    log "Installing vnstat"
    apt-get install -y -qq vnstat
    systemctl enable --now vnstat
    info "vnstat installed and running"

    local iface="${VNSTAT_INTERFACE}"
    if [[ -z "${iface}" ]]; then
        iface="$(detect_primary_interface)"
        if [[ -z "${iface}" ]]; then
            err "Could not auto-detect the primary network interface."
            echo "Set it manually: VNSTAT_INTERFACE=\"ens5\" bash setup.sh vnstat" >&2
            exit 1
        fi
        info "Auto-detected primary interface: ${iface}"
    else
        info "Using manually-set interface: ${iface}"
    fi
    # Idempotent — no-ops if vnstat is already tracking this interface.
    vnstat --add -i "${iface}" &>/dev/null || true

    require_server_label

    # Also apply SERVER_LABEL as the actual system hostname, so the alert
    # prefix and `hostname` stay in sync without maintaining them
    # separately. Sanitized to valid hostname characters (lowercase
    # alphanumeric + hyphens) since what the person types is meant
    # primarily for the Telegram message, not hostname syntax rules.
    local new_hostname
    new_hostname="$(echo "${SERVER_LABEL}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
    if [[ -z "${new_hostname}" ]]; then
        info "Server label has no usable hostname characters, skipping hostname change"
    else
        local old_hostname
        old_hostname="$(hostname -s 2>/dev/null || hostname)"
        if [[ "${new_hostname}" == "${old_hostname}" ]]; then
            info "Hostname already matches server label (${new_hostname}), skipping"
        else
            hostnamectl set-hostname "${new_hostname}"
            # Keep /etc/hosts' 127.0.1.1 entry (Debian/Ubuntu convention)
            # in sync so local hostname resolution doesn't break.
            if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
                sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_hostname}/" /etc/hosts
            else
                printf '127.0.1.1\t%s\n' "${new_hostname}" >> /etc/hosts
            fi
            info "Hostname changed: ${old_hostname} -> ${new_hostname} (takes effect immediately, no reboot needed)"
        fi
    fi

    local bin_dir="/home/${USERNAME}/.local/bin"
    local status_script="${bin_dir}/vnstat_status.sh"

    log "Creating bandwidth alert script (interface: ${iface}, label: ${SERVER_LABEL})"
    mkdir -p "${bin_dir}"
    # vnstat_status.sh is written by root but must run as ${USERNAME} via
    # cron, and it calls telebash independently of any login shell — so it
    # reads the saved token file directly rather than relying on PATH or
    # profile.d exports, which cron never sources.
    cat > "${status_script}" << EOF
#!/bin/bash
TELEBASH_TOKEN="\$(cat /home/${USERNAME}/.config/telebash/token 2>/dev/null)"
export TELEBASH_TOKEN
TOTAL=\$(/usr/bin/vnstat -m -i ${iface} | grep "\$(date +%Y-%m)" | awk '{print \$8 " " \$9}')
/home/${USERNAME}/.local/bin/telebash -t "📊 [${SERVER_LABEL}] Bandwidth used this month: \$TOTAL"
EOF
    chmod +x "${status_script}"
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.local"
    info "Bandwidth alert script created at ${status_script}"

    if [[ ! -x "${bin_dir}/telebash" ]] && ! printf '%s\n' "${SELECTED_MODULES[@]:-}" | grep -qx "telebash"; then
        info "Warning: telebash isn't installed and the 'telebash' module wasn't selected in this run."
        info "The cron job below won't be able to send alerts until 'telebash' is also run."
    fi

    log "Adding cron job"
    local cron_line="0 */4 * * * ${status_script}"
    if crontab -u "${USERNAME}" -l 2>/dev/null | grep -qF "${status_script}"; then
        info "Cron job already present, skipping"
    else
        (crontab -u "${USERNAME}" -l 2>/dev/null || true; echo "${cron_line}") | crontab -u "${USERNAME}" -
        info "Cron job added: ${cron_line}"
    fi
}

# =============================================================================
# USER-PHASE HELPERS
# =============================================================================

# ~/.local/bin is where every non-apt binary in phase 2 lands. mod_telebash
# writes the profile.d file that puts it on PATH, but cli-tools/tui-tools/
# aichat must not depend on telebash having been selected in the same run —
# so they call this to guarantee the directory exists and is on PATH both
# for the remainder of this script and for future login shells.
ensure_local_bin() {
    local bin_dir="/home/${USERNAME}/.local/bin"
    mkdir -p "${bin_dir}"

    case ":${PATH}:" in
        *":${bin_dir}:"*) ;;
        *) export PATH="${bin_dir}:${PATH}" ;;
    esac

    # Same file mod_telebash writes. Creating it here (without the token
    # export, which telebash adds later) means PATH works even when
    # telebash was never run. mod_telebash overwrites it wholesale, so
    # there's no conflict either way.
    if [[ ! -f /etc/profile.d/yan-local-bin.sh ]]; then
        sudo tee /etc/profile.d/yan-local-bin.sh > /dev/null << EOF
export PATH="${bin_dir}:\$PATH"
EOF
        sudo chmod 644 /etc/profile.d/yan-local-bin.sh
        info "Created /etc/profile.d/yan-local-bin.sh for PATH"
    fi

    # zsh doesn't read /etc/profile.d on its own — see the longer note in
    # mod_telebash. Kept in sync here for the same reason.
    local zprofile="/etc/zsh/zprofile"
    sudo mkdir -p "$(dirname "${zprofile}")"
    sudo touch "${zprofile}"
    if ! grep -qF "yan-local-bin.sh" "${zprofile}"; then
        echo "[ -f /etc/profile.d/yan-local-bin.sh ] && . /etc/profile.d/yan-local-bin.sh" \
            | sudo tee -a "${zprofile}" > /dev/null
    fi
}

# Maps uname -m to the arch strings used in GitHub release asset names.
# Echoes a regex alternation because projects disagree (x86_64 vs amd64,
# aarch64 vs arm64), and matching either is simpler than a per-project map.
release_arch_pattern() {
    # Anchored with (_|-|\.) delimiters on both sides so that a 64-bit
    # pattern can't accidentally match a 32-bit asset. lazydocker, for
    # instance, ships both Linux_x86.tar.gz and Linux_x86_64.tar.gz — a
    # bare "x86_64|x64" alternation risks selecting the wrong one.
    case "$(uname -m)" in
        x86_64)  echo "[_.-](x86_64|amd64)([_.-]|$)" ;;
        aarch64) echo "[_.-](aarch64|arm64)([_.-]|$)" ;;
        *)       err "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
}

# Resolves the newest release of a GitHub repo and echoes the download URL
# of the first asset matching the given regex.
#
# Uses the unauthenticated API (60 requests/hour per IP). A full run makes
# five calls total, so the limit is not a practical concern — but if you
# ever hit it, export GITHUB_TOKEN and it'll be used automatically.
github_latest_asset_url() {
    local repo="$1" pattern="$2"
    local api="https://api.github.com/repos/${repo}/releases/latest"
    local -a auth=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    curl -fsSL "${auth[@]}" "${api}" \
        | grep -oE '"browser_download_url": *"[^"]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/' \
        | grep -E "${pattern}" \
        | head -n1
}

# Downloads the matching asset for a repo, extracts it, locates the named
# binary anywhere in the archive, and installs it to ~/.local/bin.
#
# Handles .tar.gz, .tar.xz and .zip because these five projects don't agree
# on a format. Skips entirely if the command already resolves — per the
# "exists, skip" idempotency rule the rest of this script follows.
install_github_binary() {
    local repo="$1" binary="$2" asset_pattern="$3"
    local bin_dir="/home/${USERNAME}/.local/bin"

    if command -v "${binary}" &>/dev/null; then
        info "${binary} already installed ($(command -v "${binary}")), skipping"
        return 0
    fi

    local url
    url="$(github_latest_asset_url "${repo}" "${asset_pattern}")"
    if [[ -z "${url}" ]]; then
        err "Could not find a ${binary} release asset for this architecture."
        err "Checked ${repo} against pattern: ${asset_pattern}"
        return 1
    fi
    info "Downloading ${binary} from ${url##*/}"

    local tmp
    tmp="$(mktemp -d)"
    # Cleaned up on every exit path, including the error returns below.
    trap 'rm -rf "${tmp}"' RETURN

    local archive="${tmp}/${url##*/}"
    curl -fsSL "${url}" -o "${archive}"

    case "${archive}" in
        *.tar.gz|*.tgz) tar -xzf "${archive}" -C "${tmp}" ;;
        *.tar.xz)       tar -xJf "${archive}" -C "${tmp}" ;;
        *.zip)          unzip -qo "${archive}" -d "${tmp}" ;;
        *)              err "Unrecognized archive format: ${archive##*/}"; return 1 ;;
    esac

    # Release tarballs vary in whether they nest the binary in a versioned
    # directory, so search rather than assuming a path.
    local found
    found="$(find "${tmp}" -type f -name "${binary}" -perm -u+x | head -n1)"
    if [[ -z "${found}" ]]; then
        err "Extracted ${repo} archive but found no '${binary}' executable inside."
        return 1
    fi

    install -m 755 "${found}" "${bin_dir}/${binary}"
    info "${binary} installed to ${bin_dir}/${binary}"
}

# =============================================================================
# USER-PHASE MODULES (run as USERNAME)
# =============================================================================

mod_zsh() {
    local home_dir="/home/${USERNAME}"

    log "Installing oh-my-zsh"
    if [[ ! -d "${home_dir}/.oh-my-zsh" ]]; then
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
        info "oh-my-zsh installed"
    else
        info "oh-my-zsh already installed, skipping"
    fi

    log "Installing zsh plugins"
    local zsh_custom="${home_dir}/.oh-my-zsh/custom"

    if [[ ! -d "${zsh_custom}/plugins/zsh-autosuggestions" ]]; then
        git clone --depth=1 \
            https://github.com/zsh-users/zsh-autosuggestions \
            "${zsh_custom}/plugins/zsh-autosuggestions"
        info "zsh-autosuggestions installed"
    else
        info "zsh-autosuggestions already installed, skipping"
    fi

    if [[ ! -d "${zsh_custom}/plugins/zsh-syntax-highlighting" ]]; then
        git clone --depth=1 \
            https://github.com/zsh-users/zsh-syntax-highlighting \
            "${zsh_custom}/plugins/zsh-syntax-highlighting"
        info "zsh-syntax-highlighting installed"
    else
        info "zsh-syntax-highlighting already installed, skipping"
    fi
}

mod_dotfiles() {
    require_token
    local home_dir="/home/${USERNAME}"

    log "Installing chezmoi and applying dotfiles"
    if ! command -v chezmoi &>/dev/null; then
        sh -c "$(curl -fsSL https://get.chezmoi.io)" -- -b "${home_dir}/.local/bin"
        export PATH="${home_dir}/.local/bin:$PATH"
        info "chezmoi installed"
    else
        info "chezmoi already installed, skipping install"
        export PATH="${home_dir}/.local/bin:$PATH"
    fi

    chezmoi init --apply "$(dotfiles_repo_url)"
    info "Dotfiles applied from repo"
}

mod_node() {
    log "Installing Node.js via n"
    if ! command -v node &>/dev/null || [[ "$(node --version)" < "v18" ]]; then
        info "Bootstrapping Node.js via apt temporarily"
        sudo apt-get install -y -qq nodejs npm
        sudo npm install -g n
        sudo n lts
        sudo apt-get remove -y -qq nodejs npm
        sudo apt-get autoremove -y -qq
        export PATH="/usr/local/bin:$PATH"
        info "Node.js installed via n: $(node --version)"
    else
        info "Node.js already installed: $(node --version)"
    fi
}

mod_syncthing() {
    local home_dir="/home/${USERNAME}"
    local keyring="/etc/apt/keyrings/syncthing-archive-keyring.gpg"

    log "Installing syncthing"
    # Ubuntu's own syncthing package lags the upstream release badly, and
    # syncthing's protocol compatibility window is version-sensitive — so
    # use the official repo rather than universe.
    if ! command -v syncthing &>/dev/null; then
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://syncthing.net/release-key.gpg \
            | sudo tee "${keyring}" > /dev/null
        sudo chmod a+r "${keyring}"
        echo "deb [signed-by=${keyring}] https://apt.syncthing.net/ syncthing stable" \
            | sudo tee /etc/apt/sources.list.d/syncthing.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq syncthing
        info "syncthing installed: $(syncthing --version | head -n1)"
    else
        info "syncthing already installed, skipping"
    fi

    log "Creating sync directory"
    mkdir -p "${home_dir}/syncthing"
    info "Sync directory ready at ${home_dir}/syncthing"

    # Without linger, the user manager is torn down when the last SSH
    # session ends, taking syncthing with it. On a server there's usually
    # no logged-in session at all, so linger is what makes --user services
    # behave like system services.
    log "Enabling linger for ${USERNAME}"
    if [[ "$(loginctl show-user "${USERNAME}" --property=Linger --value 2>/dev/null)" == "yes" ]]; then
        info "Linger already enabled, skipping"
    else
        sudo loginctl enable-linger "${USERNAME}"
        info "Linger enabled — user services now survive logout"
    fi

    log "Enabling syncthing user service"
    # The handoff from root via sudo doesn't set up a user D-Bus session,
    # so systemctl --user needs to be pointed at the user manager socket
    # explicitly. Without this it fails with "Failed to connect to bus".
    export XDG_RUNTIME_DIR="/run/user/$(id -u "${USERNAME}")"
    if systemctl --user is-enabled syncthing.service &>/dev/null; then
        info "syncthing user service already enabled"
        systemctl --user restart syncthing.service
    else
        systemctl --user enable --now syncthing.service
        info "syncthing user service enabled and started"
    fi

    info "GUI listens on 127.0.0.1:8384 (local only, as intended)"
    info "Reach it with: ssh -L 8384:127.0.0.1:8384 ${USERNAME}@<server>"
    info "Then open http://127.0.0.1:8384 and add ${home_dir}/syncthing as a folder"
}

mod_cli_tools() {
    local bin_dir="/home/${USERNAME}/.local/bin"

    ensure_local_bin

    log "Installing CLI tools via apt"
    # All four are in Ubuntu 24.04 universe. Versions trail upstream, but
    # they come with unattended-upgrades coverage for free.
    sudo apt-get install -y -qq \
        zoxide \
        fzf \
        ripgrep \
        fd-find

    # Debian ships fd's binary as 'fdfind' to avoid a name collision with
    # the unrelated fdclone package. The symlink is the documented fix and
    # is what makes `fd` work as expected.
    log "Linking fdfind as fd"
    if [[ -x "${bin_dir}/fd" ]]; then
        info "fd already linked, skipping"
    elif command -v fdfind &>/dev/null; then
        ln -sf "$(command -v fdfind)" "${bin_dir}/fd"
        info "Linked $(command -v fdfind) -> ${bin_dir}/fd"
    else
        err "fd-find installed but fdfind not found on PATH — skipping symlink"
    fi

    info "Installed: zoxide, fzf, ripgrep, fd"
}

mod_tui_tools() {
    local home_dir="/home/${USERNAME}"
    local arch
    arch="$(release_arch_pattern)"

    ensure_local_bin

    # yazi shells out to `file` for MIME detection. The richer preview
    # dependencies (ffmpegthumbnailer, poppler-utils, imagemagick) are
    # deliberately omitted — they're dead weight on a headless server.
    log "Installing yazi dependency: file"
    sudo apt-get install -y -qq file

    log "Installing helix"
    if command -v hx &>/dev/null; then
        info "helix already installed, skipping"
    else
        # helix is the one tool here that isn't a standalone binary: it
        # needs its runtime/ directory for syntax highlighting and LSP
        # config, and the binary is named 'hx'. So it can't go through
        # install_github_binary and is handled manually.
        local url tmp
        url="$(github_latest_asset_url "helix-editor/helix" "${arch}linux.*\.tar\.xz$")"
        if [[ -z "${url}" ]]; then
            err "Could not find a helix release asset for this architecture."
            return 1
        fi
        info "Downloading helix from ${url##*/}"
        tmp="$(mktemp -d)"
        curl -fsSL "${url}" -o "${tmp}/helix.tar.xz"
        tar -xJf "${tmp}/helix.tar.xz" -C "${tmp}"

        local hx_bin runtime_src
        hx_bin="$(find "${tmp}" -type f -name hx -perm -u+x | head -n1)"
        runtime_src="$(find "${tmp}" -type d -name runtime | head -n1)"
        if [[ -z "${hx_bin}" || -z "${runtime_src}" ]]; then
            err "helix archive did not contain the expected hx binary and runtime/ directory."
            rm -rf "${tmp}"
            return 1
        fi

        install -m 755 "${hx_bin}" "${home_dir}/.local/bin/hx"
        mkdir -p "${home_dir}/.local/share/helix"
        rm -rf "${home_dir}/.local/share/helix/runtime"
        cp -r "${runtime_src}" "${home_dir}/.local/share/helix/runtime"
        rm -rf "${tmp}"
        info "helix installed as 'hx', runtime at ${home_dir}/.local/share/helix/runtime"
    fi

    log "Installing yazi"
    # yazi ships a zip with the binary nested in a versioned directory;
    # install_github_binary finds it by name regardless of depth.
    install_github_binary "sxyazi/yazi" "yazi" "${arch}unknown-linux-gnu\.zip$"

    log "Installing lazygit"
    install_github_binary "jesseduffield/lazygit" "lazygit" "[Ll]inux${arch}tar\.gz$"

    log "Installing lazydocker"
    install_github_binary "jesseduffield/lazydocker" "lazydocker" "[Ll]inux${arch}tar\.gz$"
}

mod_aichat() {
    local arch
    arch="$(release_arch_pattern)"

    ensure_local_bin

    log "Installing aichat"
    # Config lives in ~/.config/aichat/config.yaml and is managed by the
    # dotfiles repo, so nothing is seeded here.
    install_github_binary "sigoden/aichat" "aichat" "${arch}unknown-linux-musl\.tar\.gz$"
}

mod_claude_code() {
    log "Installing Claude Code"
    if ! command -v claude &>/dev/null; then
        curl -fsSL https://claude.ai/install.sh | bash
        info "Claude Code installed"
    else
        info "Claude Code already installed, skipping"
    fi
}

mod_opencode() {
    log "Installing OpenCode"
    if ! command -v opencode &>/dev/null; then
        curl -fsSL https://opencode.ai/install | bash
        info "OpenCode installed"
    else
        info "OpenCode already installed, skipping"
    fi
}

mod_codex() {
    log "Installing Codex"
    if ! command -v codex &>/dev/null; then
        CODEX_NON_INTERACTIVE=1 sh -c "$(curl -fsSL https://chatgpt.com/codex/install.sh)"
        info "Codex installed"
    else
        info "Codex already installed, skipping"
    fi
}

mod_telebash() {
    local home_dir="/home/${USERNAME}"
    local bin_dir="${home_dir}/.local/bin"
    local config_dir="${home_dir}/.config/telebash"

    log "Installing telebash"
    mkdir -p "${bin_dir}"
    if [[ ! -x "${bin_dir}/telebash" ]]; then
        curl -fsSL https://raw.githubusercontent.com/mrlinnth/Telebash/main/telebash -o "${bin_dir}/telebash"
        chmod +x "${bin_dir}/telebash"
        info "telebash installed to ${bin_dir}/telebash"
    else
        info "telebash already installed, skipping download"
    fi

    log "Saving favorites"
    mkdir -p "${config_dir}"
    echo "5784395925" > "${config_dir}/favorites.txt"
    info "Favorites saved to ${config_dir}/favorites.txt"

    log "Storing Telegram bot token"
    if [[ -s "${config_dir}/token" ]]; then
        info "Token file already exists, skipping prompt"
    else
        if [[ -z "${TELEBASH_TOKEN:-}" ]]; then
            echo "" >&2
            read -rsp "Enter your Telegram bot token (from @BotFather): " TELEBASH_TOKEN
            echo "" >&2
        fi
        if [[ -z "${TELEBASH_TOKEN}" ]]; then
            err "Telegram bot token is required for the telebash module."
            exit 1
        fi
        # Stored, not exported globally, since cron (vnstat_status.sh) can't
        # see shell exports anyway — see mod_vnstat for how it's consumed.
        printf '%s' "${TELEBASH_TOKEN}" > "${config_dir}/token"
        chmod 600 "${config_dir}/token"
        info "Token saved to ${config_dir}/token (chmod 600)"
    fi

    log "Adding ${bin_dir} to PATH for login shells"
    sudo tee /etc/profile.d/yan-local-bin.sh > /dev/null << EOF
export PATH="${bin_dir}:\$PATH"
if [ -r "${config_dir}/token" ]; then
    export TELEBASH_TOKEN="\$(cat "${config_dir}/token")"
fi
EOF
    sudo chmod 644 /etc/profile.d/yan-local-bin.sh
    info "PATH + token export added via /etc/profile.d/yan-local-bin.sh"

    # /etc/profile.d/*.sh is only sourced automatically by bash login shells
    # (via /etc/profile). USERNAME's login shell is zsh (set in mod_user),
    # and zsh does not read /etc/profile.d on its own — so without this,
    # the file above would silently never take effect for USERNAME no
    # matter how many times they log in. /etc/zsh/zprofile is zsh's
    # equivalent of /etc/profile for login shells.
    local zprofile="/etc/zsh/zprofile"
    local source_line="[ -f /etc/profile.d/yan-local-bin.sh ] && . /etc/profile.d/yan-local-bin.sh"
    sudo mkdir -p "$(dirname "${zprofile}")"
    sudo touch "${zprofile}"
    if ! grep -qF "yan-local-bin.sh" "${zprofile}"; then
        echo "${source_line}" | sudo tee -a "${zprofile}" > /dev/null
        info "Added sourcing line to ${zprofile} so zsh login shells pick it up too"
    else
        info "${zprofile} already sources yan-local-bin.sh, skipping"
    fi
    info "Takes effect on next login (or run: source /etc/profile.d/yan-local-bin.sh)"
}

# =============================================================================
# PHASE 2 DISPATCH (runs as USERNAME)
# =============================================================================

phase2() {
    local -a modules=("$@")
    local name phase desc m

    require_token_if_needed() {
        for m in "${modules[@]}"; do
            if [[ "$m" == "dotfiles" ]]; then
                require_token
            fi
        done
        return 0
    }
    require_token_if_needed

    log "Phase 2: user setup (running as $(whoami))"
    cd "/home/${USERNAME}"

    for entry in "${MODULE_CATALOG[@]}"; do
        IFS='|' read -r name phase desc <<< "$entry"
        for m in "${modules[@]}"; do
            if [[ "$m" == "$name" ]]; then
                "mod_${name//-/_}"
            fi
        done
    done

    echo ""
    echo "============================================================"
    echo " Phase 2 complete: ${modules[*]}"
    echo "============================================================"
    echo ""
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

main() {
    if [[ "${1:-}" == "--phase2" ]]; then
        shift
        phase2 "$@"
        exit 0
    fi

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        print_help
        exit 0
    fi

    require_root

    local -a selected
    if [[ $# -eq 0 ]]; then
        # shellcheck disable=SC2207
        selected=($(interactive_select))
    elif [[ $# -eq 1 && "$1" == "all" ]]; then
        # shellcheck disable=SC2207
        selected=($(all_module_names))
    else
        selected=("$@")
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        err "No modules selected. Nothing to do."
        exit 1
    fi

    validate_modules "${selected[@]}"

    # Exposed as a global so individual module functions can check whether
    # a related module was also selected in this same run (e.g. mod_vnstat
    # checking whether 'telebash' is coming later in the user phase).
    SELECTED_MODULES=("${selected[@]}")

    local m
    for m in "${selected[@]}"; do
        if [[ "$m" == "dotfiles" ]]; then
            require_token
            break
        fi
    done

    build_ordered_lists "${selected[@]}"

    if [[ ${#ROOT_MODULES[@]} -gt 0 ]]; then
        log "Running root-phase modules: ${ROOT_MODULES[*]}"
        for m in "${ROOT_MODULES[@]}"; do
            "mod_${m//-/_}"
        done
    fi

    if [[ ${#USER_MODULES[@]} -gt 0 ]]; then
        if ! id "${USERNAME}" &>/dev/null; then
            err "User ${USERNAME} does not exist yet. Include the 'user' module in this run, or run it first."
            exit 1
        fi
        log "Handing off to ${USERNAME} for user-phase modules: ${USER_MODULES[*]}"

        # $0 may live somewhere USERNAME can't reach (e.g. under /root, mode
        # 700), so sudo -u "${USERNAME}" bash "$0" would fail to even open
        # the file before phase2 runs. Stage a world-readable copy in /tmp
        # (mode 1777, so it's reachable regardless of where the repo was
        # cloned) and hand off from there instead.
        local staged_script
        staged_script="$(mktemp /tmp/setup-XXXXXX.sh)"
        cp "$0" "${staged_script}"
        chmod 644 "${staged_script}"

        # No -E here on purpose: preserving the whole environment would also
        # drag along root's HOME=/root, breaking anything in phase2 that
        # trusts $HOME (e.g. the oh-my-zsh installer, which would then try
        # to write into /root and get Permission denied). Forwarding just
        # DOTFILES_TOKEN via 'env' lets sudo set HOME correctly for
        # USERNAME on its own, as it does by default without -E.
        local handoff_status=0
        sudo -u "${USERNAME}" env DOTFILES_TOKEN="${DOTFILES_TOKEN:-}" \
            bash "${staged_script}" --phase2 "${USER_MODULES[@]}" || handoff_status=$?
        rm -f "${staged_script}"

        if [[ ${handoff_status} -ne 0 ]]; then
            exit "${handoff_status}"
        fi
    fi

    log "Done."
}

main "$@"
