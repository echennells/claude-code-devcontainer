# Notes for Claude when editing this devcontainer

Package managers (`npm`, `pnpm`, `yarn`, `bun`, `npx`, `cargo`, `rustc`, `pip`,
`pip3`, `uv`, `poetry`, `mvn`, `gradle`, `sbt`, `mix`) in this container are
routed through `sbe run --` via PATH shims at `/usr/local/bin/sbe-shims/`.
Invoke them bare (`npm install`, `cargo build`); the shim handles the rest.
Do not reach for absolute paths (`/usr/bin/npm`) or fnm multishell paths
(`/home/vscode/.fnm/...`) — those bypass the shim and are denied in
`~/.claude/settings.json` (configured at postCreate).

If a build needs a host not in the default allowlist, extend it in a
project-local `.sbe.yaml` at the git root rather than working around the shim.
The user-facing section is in the README under "Package-manager sandboxing
(sbe)"; the design analysis is in [`SBE_DEVC_NOTES.md`](./SBE_DEVC_NOTES.md).

When modifying the Dockerfile / devcontainer.json / post_install.py, remember
that `.devcontainer/` is a bind-mounted readonly copy of the root files and is
read-blocked by `.claude/settings.json`. The root files are canonical; edits to
them propagate to user projects via `devc template`.
