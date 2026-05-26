# Notes for Claude when editing this devcontainer

Package managers (`npm`, `pnpm`, `yarn`, `bun`, `cargo`, `pip`, `uv`, `poetry`,
`mvn`, `gradle`, `sbt`, `mix`, `gem`, `bundle`) inside the container are wrapped
by `sbe run --` via PATH shims at `/usr/local/bin/sbe-shims/`. Invoke them bare
(`npm install`, `cargo build`); the shim applies automatically and routes the
real binary through a Landlock + seccomp cage with hostname-filtered HTTPS proxy.
**Do not reach for absolute paths** (`/usr/bin/npm`) or fnm multishell paths
(`/home/vscode/.fnm/...`) — those bypass the sandbox and are explicitly denied
in `~/.claude/settings.json` (configured by `post_install.py`).

If a build legitimately needs network access to a host not in sbe's default
profile, extend allowlists in a project-local `.sbe.yaml` at the git root rather
than working around the shim. The full design rationale and threat-coverage
analysis is in [`SBE_DEVC_NOTES.md`](./SBE_DEVC_NOTES.md); the user-facing
section is in the README under "Build-time Sandboxing (sbe)".

When modifying the Dockerfile / devcontainer.json / post_install.py, remember
that `.devcontainer/` is a bind-mounted readonly copy of the root files and is
read-blocked by `.claude/settings.json`. The root files are canonical; edits to
them propagate to user projects via `devc template`.
