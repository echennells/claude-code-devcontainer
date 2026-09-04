# Notes for Claude when editing this devcontainer

## The stack, in order

A package-manager command passes through up to four layers before it runs:

```
npm  ->  supply-chain-harden wrapper (some tools)
     ->  Safe Chain shim   (~/.safe-chain/shims)      screen: is it known-bad?
     ->  sbe shim          (/usr/local/bin/sbe-shims) cage:   Landlock + seccomp
     ->  the real binary
```

Each shim finds its target by stripping only its own directory from `PATH` and
re-running `command -v`, so they chain without knowing about each other. One
hook, `_pin_supply_chain_shims` in `.zshrc`, owns the order on `chpwd` and
`precmd`; the vendor hooks are deliberately removed. Do not add a second pin --
two functions racing for the front of `PATH` means the loser's layer is
silently skipped, and nothing reports it.

Safe Chain is deliberately OUTSIDE the cage. It needs `intel.aikido.dev`, which
no sbe profile allowlists, and sbe will not exec its binary anyway.

Invoke package managers bare (`npm install`, `cargo build`). Absolute paths
(`/usr/bin/npm`, `/usr/local/bin/uv`, `~/.fnm/...`, `~/.local/bin/python3`)
reach the real binary directly and are denied in `~/.claude/settings.json`,
written at postCreate.

## What each layer actually covers

| | defaults | Aikido screening | sbe cage |
|---|---|---|---|
| npm / node | yes | yes | yes |
| pip / uv / poetry | yes | **no** | yes |
| python / python3 | yes | yes | **no** |
| cargo, mvn, gradle, mix | yes | n/a | yes |

Two gaps, both deliberate and both structural:

- **PyPI is not screened.** Safe Chain screens Python by MITM through its
  proxy; sbe reserves `HTTPS_PROXY` and refuses `--keep-env` for it, so a caged
  process never reaches that proxy. npm survives because its scan runs before
  the cage is entered. Do not claim PyPI screening in docs or commit messages.
- **`python`/`python3` are screened but not caged.** An sbe shim there would
  cage every python process, not just installs.

If a build needs a host outside the default allowlist, extend it in a
project-local `.sbe.yaml` at the git root rather than working around the shim.

## Before changing any of this

Run the suite -- it asserts effects, not presence, because every failure in
this stack is silent:

```
docker build -t devc:local .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v "$PWD:/repo:ro" devc:local bash /repo/test/verify-supply-chain.sh
```

CI runs the same script on every push (`.github/workflows/verify.yml`), and is
the only place the amd64 artifacts get exercised.

Two traps that have already bitten, recorded so they do not again:

- Verify an sbe config merge with `sbe inspect`, never `sbe profiles` -- the
  latter prints built-in defaults and makes a working merge look broken.
- `sbe ... | grep -q` under `set -o pipefail` returns sbe's exit status, not
  grep's. A denied read makes the caged command exit non-zero, so the check
  inverts and a working cage reports as a failure.

The design analysis is in [`SBE_DEVC_NOTES.md`](./SBE_DEVC_NOTES.md); section
15 covers the merge and its limits.

## Editing mechanics

`.devcontainer/` is a bind-mounted readonly copy of the root files and is
read-blocked by `.claude/settings.json`. The root files are canonical; edits
propagate to user projects via `devc template`.
