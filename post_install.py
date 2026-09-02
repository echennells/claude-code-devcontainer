#!/usr/bin/env python3
"""Post-install configuration for Claude Code devcontainer.

Runs on container creation to set up:
- Onboarding bypass (when CLAUDE_CODE_OAUTH_TOKEN is set)
- Claude settings (bypassPermissions + deny absolute-path package managers)
- Token-strip /etc/profile.d drop-in (reduces /proc env exposure)
- Tmux configuration (200k history, mouse support)
- Directory ownership fixes for mounted volumes
- Global gitignore + local git config
"""

import contextlib
import json
import os
import subprocess
import sys
from pathlib import Path


def setup_onboarding_bypass():
    """Bypass the interactive onboarding wizard when CLAUDE_CODE_OAUTH_TOKEN is set.

    Runs `claude -p` to seed ~/.claude.json with auth state. The subprocess
    writes the config file during startup before the API call completes, so
    a timeout is expected and acceptable. After the subprocess finishes (or
    times out), we check whether ~/.claude.json was populated and only then
    set hasCompletedOnboarding.

    Workaround for https://github.com/anthropics/claude-code/issues/8938.
    """
    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "").strip()
    if not token:
        print(
            "[post_install] No CLAUDE_CODE_OAUTH_TOKEN set, skipping onboarding bypass",
            file=sys.stderr,
        )
        return

    # When `CLAUDE_CONFIG_DIR` is set, as is done in `devcontainer.json`, `claude` unexpectedly 
    # looks for `.claude.json` in *that* folder, instead of in `~`, contradicting the documentation.
    #  See https://github.com/anthropics/claude-code/issues/3833#issuecomment-3694918874
    claude_json_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home()))
    claude_json = claude_json_dir / ".claude.json"

    print("[post_install] Running claude -p to populate auth state...", file=sys.stderr)
    try:
        result = subprocess.run(
            ["claude", "-p", "ok"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            print(
                f"[post_install] claude -p exited {result.returncode}: "
                f"{result.stderr.strip()}",
                file=sys.stderr,
            )
    except subprocess.TimeoutExpired:
        print(
            "[post_install] claude -p timed out (expected on cold start)",
            file=sys.stderr,
        )
    except (FileNotFoundError, OSError) as e:
        print(
            f"[post_install] Warning: could not run claude ({e}) — "
            "onboarding bypass skipped",
            file=sys.stderr,
        )
        return

    if not claude_json.exists():
        print(
            f"[post_install] Warning: {claude_json} not created by claude -p — "
            "onboarding bypass skipped",
            file=sys.stderr,
        )
        return

    config: dict = {}
    try:
        config = json.loads(claude_json.read_text())
    except json.JSONDecodeError as e:
        print(
            f"[post_install] Warning: {claude_json} has invalid JSON ({e}), "
            "starting fresh",
            file=sys.stderr,
        )

    config["hasCompletedOnboarding"] = True

    claude_json.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    print(
        f"[post_install] Onboarding bypass configured: {claude_json}", file=sys.stderr
    )


def setup_claude_settings():
    """Configure Claude Code with bypassPermissions and deny absolute-path
    invocations of package managers so they cannot bypass the sbe PATH shims."""
    claude_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
    claude_dir.mkdir(parents=True, exist_ok=True)

    settings_file = claude_dir / "settings.json"

    # Load existing settings or start fresh. Tolerate unreadable / malformed
    # state: settings.json may be present from the image layer with permissions
    # that fix_directory_ownership couldn't resolve (rare but seen on
    # OrbStack/Colima named volumes).
    settings = {}
    if settings_file.exists():
        try:
            settings = json.loads(settings_file.read_text())
        except (json.JSONDecodeError, OSError) as e:
            print(
                f"[post_install] Warning: cannot read {settings_file} ({e}), "
                "regenerating from scratch",
                file=sys.stderr,
            )

    # Set bypassPermissions mode
    if "permissions" not in settings:
        settings["permissions"] = {}
    settings["permissions"]["defaultMode"] = "bypassPermissions"

    # Sbe shims at /usr/local/bin/sbe-shims/ are first on PATH, but an absolute
    # path to the real binary reaches it unsandboxed. Deny the known locations.
    #
    # /usr/local/bin matters as much as /usr/bin here: uv ships at
    # /usr/local/bin/uv, so covering only /usr/bin left a live bypass.
    # ~/.local/bin holds uv's python/python3 symlinks and that interpreter
    # carries its own pip, and ~/.local/share/uv/python is the referent.
    # Bare names are untouched and remain the supported way to call these.
    home = Path.home()
    managers = [
        "npm", "pnpm", "yarn", "bun", "npx",
        "cargo", "rustc",
        "pip", "pip3", "uv", "uvx", "poetry",
        "mvn", "gradle", "sbt", "mix",
        "python", "python3",
    ]
    deny = settings["permissions"].setdefault("deny", [])
    desired_denies = [f"Bash(/usr/bin/{m}:*)" for m in managers]
    desired_denies += [f"Bash(/usr/local/bin/{m}:*)" for m in managers]
    desired_denies += [
        f"Bash({home}/.fnm/**)",
        f"Bash({home}/.local/state/fnm_multishells/**)",
        f"Bash({home}/.local/bin/**)",
        f"Bash({home}/.local/share/uv/python/**)",
    ]
    for d in desired_denies:
        if d not in deny:
            deny.append(d)

    try:
        settings_file.write_text(
            json.dumps(settings, indent=2) + "\n", encoding="utf-8"
        )
        print(
            f"[post_install] Claude settings configured: {settings_file}",
            file=sys.stderr,
        )
    except OSError as e:
        print(
            f"[post_install] Warning: could not write {settings_file} ({e}). "
            "Claude defaults will apply; bypassPermissions + sbe denies are not "
            "in effect for this container. Check sudo / no-new-privileges.",
            file=sys.stderr,
        )


def setup_tmux_config():
    """Configure tmux with 200k history, mouse support, and vi keys."""
    tmux_conf = Path.home() / ".tmux.conf"

    if tmux_conf.exists():
        print("[post_install] Tmux config exists, skipping", file=sys.stderr)
        return

    config = """\
# 200k line scrollback history
set-option -g history-limit 200000

# Enable mouse support
set -g mouse on

# Use vi keys in copy mode
setw -g mode-keys vi

# Start windows and panes at 1, not 0
set -g base-index 1
setw -g pane-base-index 1

# Renumber windows when one is closed
set -g renumber-windows on

# Faster escape time for vim
set -sg escape-time 10

# True color support
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"

# Terminal features (ghostty, cursor shape in vim)
set -as terminal-features ",xterm-ghostty:RGB"
set -as terminal-features ",xterm*:RGB"
set -ga terminal-overrides ",xterm*:colors=256"
set -ga terminal-overrides '*:Ss=\\E[%p1%d q:Se=\\E[ q'

# Status bar
set -g status-style 'bg=#333333 fg=#ffffff'
set -g status-left '[#S] '
set -g status-right '%Y-%m-%d %H:%M'
"""
    tmux_conf.write_text(config, encoding="utf-8")
    print(f"[post_install] Tmux configured: {tmux_conf}", file=sys.stderr)


def fix_directory_ownership():
    """Normalize ownership AND mode of named-volume mount points.

    Fresh docker named volumes get initialized from the image's content, which
    preserves the build-time UID/mode. With updateRemoteUserUID and on
    OrbStack/Colima, files inside the volume can end up unreadable by the
    runtime vscode user even when the mount point itself looks fine — so we
    chown -R unconditionally (idempotent) and chmod -R u+rwX to ensure the
    owner has read+write everywhere."""
    uid = os.getuid()
    gid = os.getgid()

    dirs_to_fix = [
        Path.home() / ".claude",
        Path("/commandhistory"),
        Path.home() / ".config" / "gh",
    ]

    for dir_path in dirs_to_fix:
        if not dir_path.exists():
            continue
        try:
            subprocess.run(
                ["sudo", "chown", "-R", f"{uid}:{gid}", str(dir_path)],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["sudo", "chmod", "-R", "u+rwX", str(dir_path)],
                check=True,
                capture_output=True,
                text=True,
            )
            print(
                f"[post_install] Normalized ownership/perms: {dir_path}",
                file=sys.stderr,
            )
        except subprocess.CalledProcessError as e:
            print(
                f"[post_install] Warning: could not normalize {dir_path}: "
                f"exit {e.returncode}; stderr={e.stderr.strip() if e.stderr else ''}",
                file=sys.stderr,
            )


def setup_global_gitignore():
    """Set up global gitignore and local git config.

    Since ~/.gitconfig is mounted read-only from host, we create a local
    config file that includes the host config and adds container-specific
    settings like core.excludesfile and delta configuration.

    GIT_CONFIG_GLOBAL env var (set in devcontainer.json) points git to this
    local config as the "global" config.
    """
    home = Path.home()
    gitignore = home / ".gitignore_global"
    local_gitconfig = home / ".gitconfig.local"
    host_gitconfig = home / ".gitconfig"

    # Create global gitignore with common patterns
    patterns = """\
# Claude Code
.claude/

# macOS
.DS_Store
.AppleDouble
.LSOverride
._*

# Python
*.pyc
*.pyo
__pycache__/
*.egg-info/
.eggs/
*.egg
.venv/
venv/
.mypy_cache/
.ruff_cache/

# Node
node_modules/
.npm/

# Editors
*.swp
*.swo
*~
.idea/
.vscode/
*.sublime-*

# Misc
*.log
.env.local
.env.*.local
"""
    gitignore.write_text(patterns, encoding="utf-8")
    print(f"[post_install] Global gitignore created: {gitignore}", file=sys.stderr)

    # Create local git config that includes host config and sets excludesfile + delta
    # Delta config is included here so it works even if host doesn't have it configured
    # safe.directory takes no path glob, and repos can sit anywhere under /workspace
    local_config = f"""\
# Container-local git config
# Includes host config (mounted read-only) and adds container settings

[include]
    path = {host_gitconfig}

[core]
    excludesfile = {gitignore}
    pager = delta

[interactive]
    diffFilter = delta --color-only

[delta]
    navigate = true
    light = false
    line-numbers = true
    side-by-side = false

[merge]
    conflictstyle = diff3

[diff]
    colorMoved = default

[gpg "ssh"]
    program = /usr/bin/ssh-keygen

# Bind mounts report a foreign uid, which trips git's ownership check
[safe]
    directory = *
"""
    local_gitconfig.write_text(local_config, encoding="utf-8")
    print(
        f"[post_install] Local git config created: {local_gitconfig}", file=sys.stderr
    )


def setup_token_strip_profile():
    """Drop /etc/profile.d/99-unset-claude-tokens.sh so new login shells start
    without CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY in env. Reduces the
    /proc/<pid>/environ exposure for child processes that build scripts spawn.

    Does NOT close the gap for long-lived processes that were started with the
    tokens in env (Claude itself, the VS Code server). See README's
    Build-time Sandboxing section for the documented limitation."""
    profile = "/etc/profile.d/99-unset-claude-tokens.sh"
    body = (
        "# Unset Claude tokens in new login shells (set by post_install.py).\n"
        "unset CLAUDE_CODE_OAUTH_TOKEN\n"
        "unset ANTHROPIC_API_KEY\n"
    )
    try:
        subprocess.run(
            ["sudo", "tee", profile],
            input=body,
            text=True,
            check=True,
            capture_output=True,
        )
        subprocess.run(["sudo", "chmod", "0644", profile], check=True)
        print(f"[post_install] Token-strip profile: {profile}", file=sys.stderr)
    except subprocess.CalledProcessError as e:
        print(
            f"[post_install] Warning: could not install token-strip profile: {e}",
            file=sys.stderr,
        )


def main():
    """Run all post-install configuration."""
    print("[post_install] Starting post-install configuration...", file=sys.stderr)

    # Must run first: fresh named volumes (~/.claude, /commandhistory, gh) come up
    # owned by the image's build-time UID 1000, but `updateRemoteUserUID: true`
    # remaps vscode to the host UID at container start. Without chowning here,
    # subsequent setup steps hit PermissionError reading/writing those paths.
    fix_directory_ownership()
    setup_onboarding_bypass()
    setup_claude_settings()
    setup_token_strip_profile()
    setup_tmux_config()
    setup_global_gitignore()

    print("[post_install] Configuration complete!", file=sys.stderr)


if __name__ == "__main__":
    main()
