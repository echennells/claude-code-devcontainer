# sbe + Trail of Bits devcontainer — analysis notes

Notes on whether and how `tyrchen/sbe` composes with the
`trailofbits/claude-code-devcontainer` to harden supply-chain attack
surface, what each layer actually delivers, and where the marketing
exceeds the implementation.

Local checkouts referenced:

- `.devcontainer/` — vendored copy of the trailofbits devc, byte-identical
  to upstream HEAD `5203cb5` (2026-04-24, "Address Potential Container
  Escape via git #42").
- `sbe/` — fresh clone of `github.com/tyrchen/sbe` at `f1d2f40`
  (2026-05-12).

---

## 1. What sbe is

A per-command sandbox wrapper. You type `sbe run -- <cmd>`; `sbe` installs
kernel-level restrictions on the resulting process tree, then `execve`s
your command. Restrictions are enforced by the kernel, not by sbe, and
they survive `fork` and `execve` and cannot be removed from inside the
process — only by the process dying.

Two backends:

- **macOS** — Seatbelt / SBPL via `sandbox-exec(1)`.
- **Linux** — Landlock LSM + seccomp-bpf.

Per-ecosystem default profiles for `node`, `cargo`, `python`, `mix`,
`java` (maven/gradle/sbt), each shipping a curated read allowlist,
write allowlist, exec allowlist, and outbound domain allowlist.

---

## 2. Mechanism — how the kernel actually enforces

For each `sbe run -- npm install` on Linux, the child process, before
`execve`, runs four syscalls (see
`sbe/crates/core/src/sandbox/linux/exec.rs:69+`):

```c
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);     // required for unprivileged seccomp
rs = landlock_create_ruleset(...);
landlock_add_rule(rs, LANDLOCK_RULE_PATH_BENEATH, ...);  // per allowed path
landlock_add_rule(rs, LANDLOCK_RULE_NET_PORT, ...);      // per allowed TCP port
landlock_restrict_self(rs, 0);              // install on this task — irreversible
seccomp(SECCOMP_SET_MODE_FILTER, 0, &bpf);  // BPF program on every syscall
execve("/usr/bin/npm", argv, envp);
```

Three properties matter:

1. **Kernel is the enforcer.** When `openat()` returns `-EACCES`, it's
   because the Landlock LSM hook in the kernel refused. There is no
   library to bypass, no flag to override.
2. **Irreversible.** Nothing — root, capabilities, ptrace, exec —
   removes the ruleset from a process once installed. Only process
   death.
3. **Inherits across `fork` and `execve`.** A spawned `sh`/`node`/`bash`
   starts with the same cage glued on.

Landlock requires kernel ≥5.13 (basic) / ≥6.7 (per-port TCP filter via
ABI v4). Below 6.7 sbe falls back to a seccomp `connect()` arg-filter
unless `--allow-degraded` is passed.

---

## 3. The sbe proxy

`crates/proxy/` — 330 lines, three dependencies (`tokio`, `thiserror`,
`tracing`). Homegrown. No HTTP framework.

It is a **CONNECT-only tunnel proxy** with a hostname allowlist:

```
1. Bind 127.0.0.1:<ephemeral>.
2. accept() a TCP connection.
3. Read one plaintext line — must be "CONNECT host:port HTTP/1.1".
4. Discard the rest of the headers (until blank line).
5. allowlist.is_allowed(host)?
     no  -> reply 403, close.
     yes -> TcpStream::connect(host:port), reply "200 Connection Established".
6. tokio::io::copy_bidirectional(client, upstream) — bytes pass opaque.
```

Knowledge of "where the traffic is going" comes from the **CONNECT line
the client wrote in plaintext**, before TLS. The proxy does not parse
the TLS ClientHello, does not see SNI, does not see the cert.

### Why a proxy at all

Landlock can filter TCP egress by port number only — not by hostname.
So the design is:

- Landlock allows TCP only to the proxy's loopback port.
- `HTTPS_PROXY` env var routes well-behaved tools through the proxy.
- The proxy filters by hostname at the CONNECT layer.

Same proxy works for both Linux and macOS backends; only the kernel
egress-pinning mechanism differs.

### Caveats of the proxy

- **Trusts the CONNECT line.** No SNI verification. A client that
  CONNECTs to `registry.npmjs.org:443` but then sends TLS with
  `SNI=attacker.example` will, on shared CDN edges (Fastly,
  Cloudflare), reach the attacker's origin. Domain-fronting is not
  defended.
- **CONNECT only.** Plain-HTTP GET/POST via the proxy returns 405.
  Forces TLS, which is a feature.
- **No IP pinning.** DNS resolution is left to the OS; DNS rebinding
  is in principle possible.

---

## 4. What sbe blocks vs what it does not (Linux backend)

### Blocks well

- File reads outside the per-profile allowlist (e.g. `~/.ssh`, `~/.aws`,
  `.claude/`, `.config/gh/`).
- File writes outside the per-profile write allowlist.
- Spawning binaries outside `allowExec` (denies `sudo`, `su`, `pkexec`,
  etc. by default).
- TCP egress to non-allowlisted hosts (kernel pins to proxy; proxy
  filters by Host).
- TCP egress on non-allowlisted ports (Landlock ABI v4).
- Privilege escalation via setuid/setgid binaries (`PR_SET_NO_NEW_PRIVS`).

### Known gaps (called out in sbe README)

- **`/proc` cross-process snooping.** `/proc/` is in the baseline read
  allowlist by design. A sandboxed process can read
  `/proc/<other-pid>/environ` of any same-uid process — including the
  Claude Code process holding `CLAUDE_CODE_OAUTH_TOKEN` in env.
- **DNS-over-UDP exfiltration.** Landlock filters TCP only. A
  postinstall can encode secrets in DNS subdomains; the kernel's UDP
  resolver delivers them to the attacker's nameserver. The proxy never
  sees DNS.
- **JVM tools (Maven, Gradle resolver, sbt coursier) don't honour
  `HTTP_PROXY`.** Java profile ships with `enableProxy: false`. Kernel
  still pins to port 443, but per-domain filtering is delegated.
- **Gradle on Linux.** CLI/daemon IPC uses a random localhost TCP port
  that Landlock v4 can't express. Requires `allowAllNetwork: true`,
  which disables kernel TCP filtering for that profile.
- **`bash` `/dev/tcp/host/port`.** Same kernel syscalls; the proxy
  doesn't see this traffic.
- **Audit log is best-effort.** Requires `CAP_SYSLOG` to read
  `/dev/kmsg`; without it, violations only surface as `EACCES` exit
  codes — silent for any attack that doesn't trip a deny event (DNS
  exfil, `/proc` snooping, TLS:443 C2 in degraded mode).
- **`denyExec` is a no-op on Linux.** Landlock is allowlist-only.
- **`denyRead` is allowlist-omission**, not subtractive — it becomes a
  sealed forbidden-list that future configs cannot weaken.

---

## 5. What the trailofbits devcontainer already provides

The devc protects the **host** from the container. Mounts in
`.devcontainer/devcontainer.json:44-52`:

- `~/.gitconfig` — bind-mounted readonly.
- `.devcontainer/`, `.git/config`, `.git/hooks` — bind-mounted readonly.
- `.claude` (OAuth token, sessions, plugin state) — persistent volume.
- `gh` config — persistent volume.
- bash history — persistent volume.

Notably **not** mounted: `~/.ssh`, `~/.aws`, `~/.docker/config.json`,
the rest of `$HOME`. The devc protects against those by simply not
exposing them, which is stronger than an inner denylist.

### Hardened defaults the devc sets via `containerEnv`

| Env var | Effect |
|---|---|
| `NPM_CONFIG_IGNORE_SCRIPTS=true` | Disables npm pre/postinstall scripts entirely |
| `NPM_CONFIG_MINIMUM_RELEASE_AGE=1440` | Refuses npm packages published in the last 24h |
| `NPM_CONFIG_AUDIT=true` | Surfaces known CVEs at install |
| `NPM_CONFIG_SAVE_EXACT=true` | Pins exact versions; no caret/tilde drift |
| `PYTHONDONTWRITEBYTECODE=1` | Avoids stale `.pyc` cache attacks |
| `PIP_DISABLE_PIP_VERSION_CHECK=1` | One less network call |

`runArgs: --cap-add=NET_ADMIN, NET_RAW` — for network testing inside
the container; harmless for sbe (sbe doesn't use raw sockets) and
useful if you ever want iptables-based egress controls.

`.claude/settings.json` (upstream-shipped) denies Claude from
reading `.devcontainer/**` — closes the container-escape-via-git #42
vector by preventing Claude from modifying the bind-mounted dir then
triggering a rebuild. App-level Claude permission, not a kernel cage.

### What the devc does NOT protect (the inside of the container)

Every process in the devc shares one trust zone. Any process can:

- Read `/home/vscode/.gitconfig`, `/workspace/.git/config`.
- Read `/home/vscode/.claude/*` (Claude OAuth token, session state).
- Read `/home/vscode/.config/gh/*` (GitHub auth).
- Read env: `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`.
- Connect outbound to anywhere on the internet.

The devc has zero inner restriction on file reads or egress.

---

## 6. Threat coverage map — devc alone vs devc + sbe

| Threat | devc as-shipped | + sbe wrapping the install/build command |
|---|---|---|
| npm postinstall malware | covered (`NPM_CONFIG_IGNORE_SCRIPTS`) | redundant |
| yarn / bun postinstall malware | not covered (env var only applies to npm) | covered |
| pnpm postinstall malware | covered (reads `.npmrc` style) | redundant |
| New (< 24h) malicious npm pkg | covered (`MINIMUM_RELEASE_AGE`) | redundant |
| `cargo build` / `build.rs` exfil | not covered | covered |
| `pip install` / `setup.py` exfil | not covered | covered |
| Maven / Gradle plugin exfil | not covered | partial (JVM caveats — see §4) |
| `mix compile` hook exfil | not covered | covered |
| Ruby gem `extconf.rb` exfil | not covered | covered |
| Stage-2 download from attacker domain at build time | not covered | covered (proxy 403) |
| Read `~/.gitconfig` from build script | not covered | covered (if added to `denyRead`) |
| Read Claude/gh token files from build script | not covered | covered |
| Steal Claude token from `/proc/<claude-pid>/environ` | not covered | not covered |
| DNS-over-UDP exfil of secrets | not covered | not covered |
| Runtime malware (executed via `npm test`, `node app.js`, `pytest`) | not covered | not covered (outside sbe perimeter) |
| Supply chain integrity (malicious build producing malicious binary) | not covered | not covered (different layer — reproducible builds / SLSA) |

Empirically, install-time vectors are the preferred attack pattern
(ua-parser-js, coa, rc, rustdecimal, shai-hulud, xz-utils all
exploit install/build-time code execution). Runtime-only sabotage
(event-stream, colors/faker, node-ipc) is rarer.

---

## 7. The strong claim and where it falls apart

The aspirational pitch for a combined devc + sbe image:

> A compromised dependency inside this devc cannot reach your Claude
> token, your gh token, or call out to anywhere off the registry
> allowlists.

**Rigorous version that the basic combined image actually delivers:**

- ✅ Cannot read `~/.config/gh/hosts.yml` (Landlock denies).
- ✅ Cannot read its own `process.env.CLAUDE_CODE_OAUTH_TOKEN` (if the
  shim does `env -u` before invoking sbe).
- ✅ Cannot make a TCP connection to a non-allowlisted host (kernel
  egress pin + proxy hostname filter).

**Still reachable in the basic combined image:**

- ⚠️ Claude token via `/proc/<claude-pid>/environ` — Linux uid check
  permits same-uid reads; `/proc/` is in sbe's read allowlist by design.
- ⚠️ DNS-over-UDP exfil to attacker nameserver — Landlock cannot
  filter UDP.
- ⚠️ `~/.gitconfig` and `/workspace/.git/config` reads — both in the
  default read allowlist for most profiles.
- ⚠️ Anything via `bash`'s `/dev/tcp/host/port` if bash is in
  `allowExec` and the egress port is in the allowlist.

### To earn the strong claim, also need

1. **Strip tokens from env at the shim boundary** — `exec env -u
   CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY sbe run -- …`.
2. **Block /proc cross-process snooping** — either mount `/proc` with
   `hidepid=2`, or don't keep the OAuth token in any process's env (use
   a credential file at a path sbe denies).
3. **Block UDP egress** — the devc already has `NET_ADMIN`, so iptables
   in a `postStartCommand` can drop UDP except to a local resolver. Or
   run a filtering DNS resolver in the container and point
   `/etc/resolv.conf` at it.
4. **Add `~/.gitconfig`, `.git/config` to `denyRead` in profiles.**
5. **Audit `allowExec`** — confirm `bash` is removed or that egress is
   strict (≥6.7 kernel, no `:443` direct fallback).

Without (1) and (2), the "cannot reach Claude token" claim is false.
Without (3), "cannot call out anywhere" is false.

---

## 8. sbe is per-process opt-in — what's inside vs outside the perimeter

Landlock and seccomp live on a `task_struct`. They apply only to
processes started under `sbe run --` (or via a shim that wraps the
command) and their descendants. The devc itself is not "running under
sbe"; specific commands are.

### Inside the perimeter (with a shim covering package managers)

- `npm install` and child processes (postinstall, native builds).
- `cargo build` and `build.rs`.
- `pip install` and `setup.py`.
- `mvn`, `gradle`, `mix`, `gem`, `bundle` — and what they spawn.

### Outside the perimeter — full devc privileges

- **Claude itself.** Unconstrained by design — the trailofbits model is
  "Claude trusted but boxed by Docker."
- **Interactive shell** (zsh prompt).
- **`git`** — `git clone`, remote helpers, git hooks (husky, lefthook).
- **`gh`**, `curl`, `wget`, `bash`, `make` when invoked directly.
- **Runtime execution paths**:
  - **Test runners** (`jest`, `pytest`, `cargo test`) — these import
    deps and run their code.
  - **Dev servers** (`vite`, `next dev`, `cargo run`, `python app.py`).
  - **Editor language servers** (rust-analyzer, pyright, tsserver).
  - **Anything in a `Makefile`** target — only the shimmed binaries
    inside it get caged; the make process and raw shell calls do not.

### Install vs runtime — the critical distinction

The shim-based perimeter protects against **install-time code
execution**. It does **not** protect against **runtime code execution
of the same compromised dep**:

- `npm test` → jest → `require('compromised-pkg')` → malicious code
  runs at full devc privilege.
- `cargo test` → links compromised crate → runs malicious code at full
  privilege.
- `python app.py` → `import compromised` → same.

This trips people up. The attacker doesn't have to put the payload in
`postinstall` — they can put it in `index.js` and wait for an import.

Mitigation directions, if you care:

- Widen the shim set (`node`, `python`, `ruby`, `java`, `jest`,
  `pytest`, …). Trade-off: dev experience suffers — your `vite` dev
  server now has a hostname allowlist that doesn't include the
  third-party CDN you legitimately need.
- Run *everything* under sbe by default by making the container shell
  entrypoint `sbe run --shell -- /bin/zsh`. Awkward in practice.
- Accept that runtime is in the devc trust zone, and rely on
  `npm audit` / `cargo audit` / Renovate / minimum-release-age to
  reduce the chance of pulling a compromised dep at all.

---

## 9. Where sbe earns its keep in this devc

For **pure-npm workflows**, the existing devc covers most of the field
via `NPM_CONFIG_IGNORE_SCRIPTS` and `MINIMUM_RELEASE_AGE`. Marginal sbe
value is small unless you need to actually run scripts (native modules,
selective rebuilds).

For **Rust, Python, JVM, Ruby, Elixir** — sbe is doing real work the
devc cannot do alone. There is no equivalent of `--ignore-scripts` in
these ecosystems because the build step *requires* code execution:

- `build.rs` generates bindings, probes for libs, sets cfg flags.
- `setup.py` is the package definition.
- Maven / Gradle plugins are arbitrary code in the lifecycle.
- `extconf.rb` compiles native extensions.
- `mix compile` hooks generate code.

You cannot skip them. The only defence is containment.

### Past attacks where sbe would have changed the outcome

- **`rustdecimal`** (2022) — typosquat of `rust_decimal`. Its
  `build.rs` downloaded a second-stage payload from an attacker server.
  Under `sbe run -- cargo build`, the HTTPS_PROXY allowlist would
  reject the attacker domain; the download returns 403.
- **Hypothetical `setup.py` reading `~/.pypirc`** to steal PyPI publish
  tokens — Landlock denies the read.
- **Build script that exfils env tokens via outbound HTTPS** — proxy
  blocks.

### Past attacks sbe would NOT have prevented

- **xz-utils** (2024) — the attack injected payload during `configure`,
  but the goal was a runtime ssh backdoor in the compiled binary. sbe
  would have caught any build-time exfil component but not prevented
  the malicious binary from being produced. That's reproducible-builds
  / SLSA / sigstore territory.
- **event-stream / colors / faker / node-ipc** — runtime-only. Outside
  the perimeter of a package-manager shim.

---

## 10. Enforcement — how to make sbe actually get called

sbe is a wrapper command. If nothing prepends `sbe run --`, it is not
in the loop. The sbe repo's docs do not address this gap; every example
assumes you (or your CI) explicitly type `sbe run -- <cmd>`. No shell
aliases, PATH shims, agent integration, or hook recipes are documented.

Inside this devc, the realistic enforcement options, ordered by how
hard they are to bypass:

### 1. Claude Code `PreToolUse` hook
A hook in `.claude/settings.json` that intercepts every `Bash` call,
inspects the command, and either rewrites it to `sbe run -- <original>`
or denies it. Enforced by the harness, not by the model. Catches every
Bash call from Claude regardless of memory.

Pros: bulletproof against the model forgetting.
Cons: only applies to Claude; an interactive terminal in the devc
bypasses it.

### 2. PATH shims in the container
Drop shims at e.g. `/usr/local/bin/sbe-shims/{npm,pnpm,yarn,cargo,
pip,uv,gradle,mvn,mix,gem,bundle}`, each one:

```bash
#!/bin/sh
exec env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
  sbe run -- "/usr/bin/$(basename "$0")" "$@"
```

Prepend the shim dir to PATH. Catches every shell, every script, every
child process.

Pros: catches everything that respects PATH; also strips tokens at the
boundary (closes the env-channel gap).
Cons: tools that invoke by absolute path (`/usr/bin/npm`) bypass it.
Lockfile installers (corepack, fnm, asdf) can shadow it back.

### 3. Bash permission rules in `.claude/settings.json`
```json
{
  "permissions": {
    "deny":  ["Bash(npm:*)", "Bash(cargo:*)", "Bash(pip:*)"],
    "allow": ["Bash(sbe run -- npm:*)", "Bash(sbe run -- cargo:*)"]
  }
}
```

Simpler than a hook. Pattern-matching is shallow — `cd foo && npm
install` or `sh -c "npm install"` slip past unless patterns are very
careful.

### 4. CLAUDE.md note (soft)
"Always invoke package managers as `sbe run -- <cmd>`." Depends on the
model. Useful as a complement, not as the only layer.

### Recommended layering

1 + 2 + 4. The hook denies/rewrites bare invocations for Claude
specifically. PATH shims catch everything else in the container,
including non-Claude shells. CLAUDE.md note keeps the model from
fighting either by reaching for absolute paths.

---

## 11. Practical Dockerfile sketch (for a combined image)

This isn't a finalised recipe — it's the minimal shape:

```dockerfile
# extend the existing .devcontainer/Dockerfile

# Install sbe from prebuilt musl binary (no Rust toolchain needed)
ARG SBE_VERSION=latest
RUN ARCH=$(dpkg --print-architecture); \
    case "${ARCH}" in \
      amd64) T=x86_64-unknown-linux-musl ;; \
      arm64) T=aarch64-unknown-linux-musl ;; \
    esac; \
    curl -fsSL "https://github.com/tyrchen/sbe/releases/${SBE_VERSION}/download/sbe-${T}.tar.gz" \
      | tar -xz -C /usr/local/bin sbe

# Install shim wrappers
RUN mkdir -p /usr/local/bin/sbe-shims && \
    for tool in npm pnpm yarn cargo pip uv gradle mvn mix gem bundle; do \
      cat > /usr/local/bin/sbe-shims/$tool <<'EOF' && chmod +x /usr/local/bin/sbe-shims/$tool ; \
#!/bin/sh
exec env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
  sbe run -- "/usr/bin/$(basename "$0")" "$@"
EOF
    done

ENV PATH="/usr/local/bin/sbe-shims:$PATH"
```

Plus, in `.claude/settings.json`, a `PreToolUse` hook that rejects bare
package-manager invocations.

Plus, in CLAUDE.md, a note explaining the perimeter so the model
doesn't reach for absolute paths to bypass the shim.

Plus, optionally, in a `postStartCommand`: iptables rules dropping UDP
egress except to a local DNS resolver, to close the DNS-exfil gap.

---

## 12. Bottom line

- The trailofbits devc and sbe protect different things; they compose
  cleanly.
- The devc protects the **host** from anything in the container, and
  via env vars handles the **npm postinstall** case for free.
- sbe protects against **install-time code execution exfil** for every
  *other* ecosystem (Rust, Python, JVM, Ruby, Elixir) where there is
  no equivalent of `--ignore-scripts`. This is the strongest single
  argument for sbe in a polyglot devc.
- A combined image, as sketched, requires PATH shims (not just sbe
  installation) to actually be in the call path. Otherwise nothing
  forces invocations through sbe.
- The strong claim "compromised dep cannot reach tokens or call home"
  requires four pieces beyond shim-installation: env-stripping at the
  shim, blocking `/proc` cross-process reads, blocking UDP egress, and
  tightening default `denyRead`. Without these, two specific channels
  (`/proc/<pid>/environ`, DNS-over-UDP) remain open.
- Commands invoked outside the shim list (`node app.js`, `python3
  script.py`, bare `pytest`) run with normal devcontainer privileges,
  the same as on the upstream devc without sbe. A malicious dep that
  fires its payload when your code later imports it, rather than when
  the package manager installs it, isn't blocked by this integration.

---

## 13. Debug-session findings (post-implementation)

Things learned during the actual integration that the analysis above either
got wrong or didn't anticipate. Captured here so the next person doesn't
re-burn the same hours.

### 13.1 Profile names in sbe v0.3.2 are *ecosystems*, not *tools*

The five built-ins are `node`, `rust`, `python`, `elixir`, `java` — **not**
`cargo` and `mix`. A YAML config that uses `cargo:` / `mix:` as the profile
key is silently ignored — sbe doesn't error, it just doesn't load the
section. The override only takes effect when keyed by the ecosystem name.

The shim should pass `--profile <ecosystem>` explicitly per tool
(`cargo|rustc → rust`, `mix → elixir`, etc.) rather than rely on
auto-detect; for commands sbe can't auto-detect from (e.g. wrapping `cat`
or any non-canonical name), auto-detect returns `unknown ecosystem` and
the run fails.

### 13.2 `extends: <built-in>` *is* subtractive for `denyRead`

Confirmed in v0.3.2: writing
```yaml
profiles:
  rust:
    extends: rust
    denyRead: [~/.gitconfig, ~/.claude, ...]
```
and then running `sbe run --profile rust -- cat ~/.gitconfig` returns
EACCES. So the global config at `~/.config/sbe/config.yaml` *does* tighten
the inherited allowlist. (Earlier worry that §4 raised — that `denyRead`
is allowlist-omission, not subtractive — turned out to be moot at least
for credential paths under home.)

### 13.3 OrbStack default-enables `no-new-privileges`

OrbStack's daemon defaults `no-new-privileges:true` on container start
even when not requested in `--security-opt`. Symptom: `sudo` fails with
"The 'no new privileges' flag is set" and post_install dies. Fix is
`--security-opt=no-new-privileges:false` in `runArgs` (the colon-separated
syntax, not `=false`). Other Docker engines may default to off; OrbStack
specifically opts in.

### 13.4 Bootstrap must not run under sbe-shimmed `uv`

Critical and non-obvious. Sequence: `postCreateCommand` runs
`uv run --no-project /opt/post_install.py`. `uv` is in the shim list →
PATH lookup hits the shim → `sbe run -- uv ...`. sbe sets
`PR_SET_NO_NEW_PRIVS=1` for the wrapped process (mandatory for
unprivileged Landlock+seccomp). Python (uv's child) inherits NNP=1.
`post_install.py` shells out to `sudo` for `chown` / `tee /etc/profile.d`,
and sudo refuses to elevate under NNP. Everything downstream dies.

Fix: change `postCreateCommand` to `python3 /opt/post_install.py` —
`python3` isn't shimmed, doesn't trigger sbe, runs with NNP=0, sudo
works. **General rule: don't run trusted bootstrap code through the
cage.**

### 13.5 fnm clobbers shim PATH precedence at shell start *and* on `cd`

`eval "$(fnm env --use-on-cd)"` in `.zshrc` prepends fnm's
multishell-bin dir to `PATH`, which puts it ahead of
`/usr/local/bin/sbe-shims/` set by the Dockerfile. `which npm` returns
the fnm path, not the shim — the cage is silently bypassed for human
shells (Claude is protected by `permissions.deny` patterns; humans are
not). Worse, `--use-on-cd` re-prepends on every `cd` into a project
with `.nvmrc`.

Fix: after the `fnm env` line in `.zshrc`, add a `_sbe_pin_shims`
function that strips existing occurrences of the shim dir from PATH and
re-prepends, plus `add-zsh-hook chpwd _sbe_pin_shims`.

### 13.6 Named-volume UID/perm inheritance is fragile

Fresh `~/.claude` named volume on OrbStack: image's settings.json gets
copied into the volume, but the file ends up unreadable by the runtime
vscode user (likely UID-remap interaction with `updateRemoteUserUID:
true`, though we never proved the exact cause — diagnostic stat'd it as
matching UID with mode 0644). The conditional check `if stat_info.st_uid
!= uid` in upstream's `fix_directory_ownership` skips chown because the
dir-level UID looks right, leaving the files inside still inaccessible.

Fix: make `fix_directory_ownership` unconditional (`chown -R` regardless
of dir UID, then `chmod -R u+rwX` to guarantee owner-writable). Call it
**first** in `main()`, before any function that reads/writes those
paths. This is a latent bug in the upstream devc, not just an sbe-layer
concern — worth a separate upstream PR.

### 13.7 Audit infrastructure we explored and ultimately dropped

We initially tried to make sbe's `--audit` / `--audit-log` flags work
on Linux, which led to layering on:

- `--cap-add=SYSLOG` in runArgs (adds CAP_SYSLOG to the container's
  bounding set, but not to vscode's effective set since vscode is
  non-root — `--cap-add` only grants to root).
- `setcap cap_syslog+ep /usr/local/bin/sbe` (file cap so sbe gets
  CAP_SYSLOG when vscode execs it; requires `libcap2-bin` apt package
  and NNP=0 to take effect).
- `--device=/dev/kmsg` in runArgs (Docker doesn't expose this device
  by default; sbe needs it to read kernel-side audit messages).

After all that, the audit log was *still* empty. Root cause:
**Landlock LSM emits no kernel-side audit output as of current Linux
releases**. When Landlock denies a syscall it just returns EACCES;
nothing reaches `/dev/kmsg` or the audit subsystem. sbe cannot capture
what the kernel never tells it. There's an open kernel proposal to add
Landlock audit, but it's not in any released kernel.

In v0.3.2 specifically, `--audit` also has an upstream bug: it spawns
a kmsg reader thread that doesn't exit when the wrapped child does,
causing every shimmed command to hang indefinitely (measured: 81 ms
without `--audit`, blocks forever with it). And `--audit-log <file>`
produces a 0-byte file even when `--audit` surfaces proxy events to
stderr.

**We removed all of the syslog/kmsg machinery.** The cage works
without it; the only visible audit channel is sbe's userspace proxy
logging `WARN blocked connection to non-allowed domain host=...`
directly to the wrapped tool's stderr — and this happens by default
with no flags, no caps, no device pass-through. Verified end-to-end:
a malicious npm preinstall script's `curl` to a fake host surfaces
the WARN line in npm's stderr output.

**Practical visibility today:**
- Network/hostname denials → visible by default via proxy WARN on stderr.
- File / write / exec denials → invisible except as EACCES exit codes.
- TCP port denials (Landlock NET_PORT) → invisible.

The dropped infrastructure is documented here only so the next person
doesn't re-attempt the same path. If a future sbe release fixes the
`--audit` teardown hang AND a future kernel adds Landlock audit, the
infra can be reinstated cleanly.

### 13.8 sbe shims everything they're symlinked for, including bootstrap-time tools

If a tool needs to function *before* the cage is right for it
(post_install, devcontainer-CLI hooks, anything that uses sudo), do not
put it in the shim symlink list. The shim catches both bootstrap and
runtime invocations identically.

Concrete: `uv` was on the list because we want `uv pip install` caged,
but the same shim caught the bootstrap `uv run`. Net was that
post_install died for non-obvious reasons. If we want both behaviors,
the shim has to discriminate by arg (`uv run` vs `uv pip install`),
which is fragile. Easier: don't shim `uv` for the postCreate call (call
python3 directly), accept that bare `uv run` from interactive shells
isn't caged.

### 13.9 The strong-claim deliverable list, updated

Effective phase-1 state achieved by the implementation and verified
end-to-end with an adversarial npm preinstall test:

- ✅ Credential reads (`~/.gitconfig`, `~/.claude`, `~/.config/gh`,
  `.git/config`) denied by Landlock under the sbe profiles.
- ✅ Outbound TCP egress pinned to sbe's loopback proxy; proxy filters
  by CONNECT-line hostname per ecosystem allowlist.
- ✅ UDP egress dropped via iptables except DNS to docker's embedded
  resolver (postStartCommand applies at every container start).
- ✅ Token env vars stripped at shim boundary (`env -u ...`) and unset
  in new login shells (`/etc/profile.d/99-unset-claude-tokens.sh`).
- ✅ Claude harness denies absolute-path package-manager invocations
  via `~/.claude/settings.json` `permissions.deny` (merged at
  postCreate, so applies in every container, not just the devc repo).
- ✅ Network denial visibility via the proxy's `WARN blocked connection
  ...` line on the wrapped tool's stderr (no flags required, no caps,
  no kmsg pass-through — proxy logs go straight through).

Known gaps remaining after phase 1:

- ⚠️ `/proc/<claude-pid>/environ` snooping — claude itself still has
  the OAuth token in env. Phase 2 work: move token to a credential
  file at a path sbe denies.
- ⚠️ Landlock file/exec denials are silent (kernel limitation, not ours).
- ⚠️ Commands not invoked through a shimmed package manager
  (`node app.js`, `python3 script.py`, bare `pytest`) run with normal
  devcontainer privileges. A malicious dep that fires its payload at
  import time rather than during install isn't blocked.
- ⚠️ JVM hostname allowlist (java profile's `enableProxy: false`
  exception) — by sbe design.
- ⚠️ TLS SNI domain fronting at sbe proxy — by sbe design.

---

## 14. Upgrade to sbe 0.4.1 (2026-09-02)

Pin moved from `sbexec-v0.3.2` (2026-05-12) to `sbexec-v0.4.1` (2026-08-29),
spanning a breaking security release and the usability patch that followed it
four days later.

### What forced code changes

1. **`version: 1` is rejected.** The 0.4 config schema refuses unknown
   top-level fields; the key is simply dropped.
2. **`extends: <same-name>` is a cycle.** A profile keyed by an ecosystem name
   already merges onto that built-in. `extends` exists for chaining custom
   bases, and self-referencing it now fails the profile lint.
3. **Verify merges with `sbe inspect`, not `sbe profiles`.** The latter prints
   built-in defaults and will not show config-supplied entries, which makes a
   working merge look broken.

### What the built-ins now cover

0.4's `node` profile denies `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`,
`~/.config/gcloud`, `~/.kube/config`, `~/.docker/config.json`, `~/.netrc`,
`~/.password-store`, cargo credentials, `~/.pypirc`, `~/.config/gh`, browser
profiles, and `/workspace/.env{,.local,.production}`.

`~/.claude` is **not** among them, which is why the global config in the
Dockerfile still exists. `~/.gitconfig`, `~/.config/git` and
`/workspace/.git/config` are likewise still ours to deny.

The `/workspace/.env*` denial is worth noting against §7: the 0.4.1 release
notes say standard mode treats the workspace as readable untrusted input
"including `.env*`", but the shipped profile denies those paths and the denial
was confirmed to hold. Built-in secret denials win over the workspace grant.

### Strict mode is unavailable on Linux

`sbe run --strict` refuses to start:

> sandbox backend cannot enforce 'strict-domain-egress' on this kernel: Linux
> Landlock authorizes destination ports, not destination addresses. A malicious
> child can bypass the CONNECT proxy.

This is upstream conceding §3's criticism directly. Standard mode is therefore
the only workable configuration here, and it prints a warning on every
invocation stating that domain egress is not enforced while filesystem,
environment, descriptor, privilege and proxy protections remain active. The
warning is honest and is deliberately not suppressed.

Consequently the §6 row "Stage-2 download from attacker domain at build time —
covered (proxy 403)" is now **best-effort on Linux**, not covered. The
iptables UDP drop in `postStartCommand` and the kernel port pin still stand.

### Verified on 0.4.1 (arm64, kernel 7.0.14)

- `npm install` through the shim succeeds and packages land.
- `~/.claude/.credentials.json` — Permission denied.
- `~/.config/gh/hosts.yml` — Permission denied.
- `/workspace/.env` — Permission denied.
- Token stripping through the shim — `process.env.CLAUDE_CODE_OAUTH_TOKEN`
  is undefined. 0.4 also clears ambient environment by default, so the shim's
  `env -u` is now defence in depth rather than the primary control.
