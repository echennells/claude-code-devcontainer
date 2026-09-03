# Claude Code Devcontainer
# Based on Microsoft devcontainer image for better devcontainer integration
FROM ghcr.io/astral-sh/uv:0.10@sha256:10902f58a1606787602f303954cea099626a4adb02acbac4c69920fe9d278f82 AS uv
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:4bcb1b466771b1ba1ea110e2a27daea2f6093f9527fb75ee59703ec89b5561cb

ARG TZ
ENV TZ="$TZ"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install additional system packages (base image already includes git, curl, sudo, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
  # Sandboxing support for Claude Code
  bubblewrap \
  socat \
  # Modern CLI tools
  fd-find \
  ripgrep \
  tmux \
  zsh \
  # Build tools
  build-essential \
  # Utilities
  jq \
  nano \
  unzip \
  vim \
  # Network tools (for security testing)
  dnsutils \
  ipset \
  iptables \
  iproute2 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install git-delta
# renovate: datasource=github-releases depName=dandavison/delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" -o /tmp/git-delta.deb && \
  dpkg -i /tmp/git-delta.deb && \
  rm /tmp/git-delta.deb

# Install uv (Python package manager) via multi-stage copy
COPY --from=uv /uv /usr/local/bin/uv

# Install fzf from GitHub releases (newer than apt, includes built-in shell integration)
# renovate: datasource=github-releases depName=junegunn/fzf
ARG FZF_VERSION=0.70.0
RUN ARCH=$(dpkg --print-architecture) && \
  case "${ARCH}" in \
    amd64) FZF_ARCH="linux_amd64" ;; \
    arm64) FZF_ARCH="linux_arm64" ;; \
    *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
  esac && \
  curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-${FZF_ARCH}.tar.gz" | tar -xz -C /usr/local/bin

# Create directories and set ownership (combined for fewer layers)
RUN mkdir -p /commandhistory /workspace /home/vscode/.claude /opt && \
  touch /commandhistory/.bash_history && \
  touch /commandhistory/.zsh_history && \
  chown -R vscode:vscode /commandhistory /workspace /home/vscode/.claude /opt

# Set environment variables
ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

WORKDIR /workspace

# Switch to non-root user for remaining setup
USER vscode

# Set PATH early so claude and other user-installed binaries are available
ENV PATH="/home/vscode/.local/bin:$PATH"

# Install Claude Code natively with marketplace plugins
RUN curl -fsSL https://claude.ai/install.sh | bash && \
  claude plugin marketplace add anthropics/skills && \
  claude plugin marketplace add trailofbits/skills && \
  claude plugin marketplace add trailofbits/skills-curated

# Install Python 3.13 via uv (fast binary download, not source compilation)
RUN uv python install 3.13 --default

# Install ast-grep (AST-based code search)
RUN uv tool install ast-grep-cli

# Install fnm (Fast Node Manager) and Node
ARG NODE_VERSION=24
ENV FNM_DIR="/home/vscode/.fnm"
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell && \
  export PATH="$FNM_DIR:$PATH" && \
  eval "$(fnm env)" && \
  fnm install ${NODE_VERSION} && \
  fnm default ${NODE_VERSION}

# fnm's shell hook is zsh-only, so without this node/npm are missing from bash/sh
ENV PATH="$FNM_DIR/aliases/default/bin:$PATH"

# Install Oh My Zsh
# renovate: datasource=github-releases depName=deluan/zsh-in-docker
ARG ZSH_IN_DOCKER_VERSION=1.2.1
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -x

# Copy zsh configuration
COPY --chown=vscode:vscode .zshrc /home/vscode/.zshrc.custom

# Append custom zshrc to the main one
RUN echo 'source ~/.zshrc.custom' >> /home/vscode/.zshrc

# Install sbe (per-command Linux sandbox: Landlock LSM + seccomp + CONNECT-only proxy).
# SHA256 values from the GitHub release; bump manually when SBE_VERSION changes.
# renovate: datasource=github-releases depName=tyrchen/sbe
ARG SBE_VERSION=sbexec-v0.4.1
USER root
RUN ARCH=$(dpkg --print-architecture) && \
  case "${ARCH}" in \
    amd64) T=x86_64-unknown-linux-musl;  SHA=726a1a6a32534e7213a6246469a3a3b6c77fe01fccb32856088a0bfc22aae18d ;; \
    arm64) T=aarch64-unknown-linux-musl; SHA=11ac7fd3bb383041eb40acca7f4b72b6eb399c40d717727b4b94f0b974d38d7b ;; \
    *) echo "unsupported arch ${ARCH}" && exit 1 ;; \
  esac && \
  curl -fsSL -o /tmp/sbe.tgz \
    "https://github.com/tyrchen/sbe/releases/download/${SBE_VERSION}/sbe-${SBE_VERSION}-${T}.tar.gz" && \
  echo "${SHA}  /tmp/sbe.tgz" | sha256sum -c - && \
  tar -xzf /tmp/sbe.tgz -C /usr/local/bin sbe && \
  chmod 0755 /usr/local/bin/sbe && \
  rm /tmp/sbe.tgz

# Sbe PATH shims: single _sbe-shim script + symlinks per package manager.
# Resolves the real binary by stripping the shim dir from PATH then `command -v`,
# so fnm multishell paths (where node/npm live under ~/.fnm/, not /usr/bin/) work.
RUN <<'SHIM_SETUP'
mkdir -p /usr/local/bin/sbe-shims
cat > /usr/local/bin/sbe-shims/_sbe-shim <<'SHIM'
#!/bin/sh
set -eu
tool=$(basename "$0")
cleaned=
IFS=:
for p in $PATH; do
  case "$p" in
    /usr/local/bin/sbe-shims|/usr/local/bin/sbe-shims/) ;;
    *) cleaned="${cleaned:+$cleaned:}$p" ;;
  esac
done
unset IFS
real=$(PATH="$cleaned" command -v "$tool" 2>/dev/null || true)
if [ -z "$real" ] || [ "$real" = "/usr/local/bin/sbe-shims/$tool" ]; then
  echo "sbe-shim: cannot find real $tool on PATH" >&2
  exit 127
fi
# Map tool -> sbe ecosystem profile. sbe v0.3.2 supports: node, rust, python,
# elixir, java. Explicit --profile avoids auto-detect failures.
case "$tool" in
  npm|pnpm|yarn|bun|npx)         prof=node ;;
  cargo|rustc)                   prof=rust ;;
  pip|pip3|uv|poetry)            prof=python ;;
  mvn|gradle|sbt)                prof=java ;;
  mix)                           prof=elixir ;;
  *)                             prof= ;;
esac
profile_arg=
[ -n "$prof" ] && profile_arg="--profile $prof"
# Do NOT pass --audit by default. 0.4 reports correlated process-tree audit
# streaming as unavailable on both backends and --audit now fails outright
# rather than hanging as it did in 0.3.2. Denials still surface as EACCES from
# the wrapped tool. See SBE_DEVC_NOTES.md §13.7.
#
# Standard mode is deliberate: --strict refuses to start on Linux because
# Landlock authorizes destination ports, not addresses, so domain egress
# cannot be enforced. Standard mode keeps filesystem, environment, descriptor,
# privilege and proxy protections and says so on stderr each run.
# Admit Safe Chain's CA bundle into the cage.
#
# Safe Chain sits outside the cage and MITMs the download to screen it, then
# overwrites SSL_CERT_FILE / REQUESTS_CA_BUNDLE / NODE_EXTRA_CA_CERTS to point
# at a bundle it writes under /tmp -- it says so on stderr and does it whatever
# we set at build time. The caged child cannot read that path, so TLS fails
# with UnknownIssuer and every uv install breaks.
#
# Grant read on exactly the paths those variables name, nothing wider. The
# bundle already exists by the time this shim runs, because Safe Chain is the
# outer layer. sbe's built-in secret denials still win over --allow-read, so
# this cannot be used to smuggle a credential path in.
#
# NOTE ON WHAT THIS DOES AND DOES NOT BUY. It keeps TLS working; it does not
# restore Safe Chain's proxy screening inside the cage. sbe reserves
# HTTPS_PROXY for its own authenticated proxy and refuses --keep-env for it
# ("environment variable 'HTTPS_PROXY' is reserved by sbe"), so a caged child
# always talks to sbe's proxy, never Safe Chain's. Consequence, measured:
#   npm    -- screened. Safe Chain's pre-install scan runs OUTSIDE the cage,
#             so a known-bad package is refused before sbe is ever invoked.
#   python -- NOT screened. Safe Chain screens pip/uv only by MITM through its
#             proxy, and that proxy is unreachable from inside the cage.
#             Python keeps the sbe cage and the age gate, not the intel feed.
# Closing this needs upstream support for chaining sbe's proxy to an outer one.
ca_args=""
for v in "${SSL_CERT_FILE:-}" "${REQUESTS_CA_BUNDLE:-}" "${NODE_EXTRA_CA_CERTS:-}"; do
  [ -n "$v" ] && [ -f "$v" ] || continue
  case " $ca_args " in *" $v "*) continue ;; esac
  ca_args="$ca_args --allow-read $v"
done

exec env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
  sbe run $profile_arg $ca_args -- "$real" "$@"
SHIM
chmod 0755 /usr/local/bin/sbe-shims/_sbe-shim
for t in npm pnpm yarn bun npx cargo rustc pip pip3 uv poetry mvn gradle sbt mix; do
  ln -sf _sbe-shim /usr/local/bin/sbe-shims/$t
done
SHIM_SETUP

# Egress filter — run by postStartCommand as root via sudo. iptables rules don't
# survive docker stop/start, so postStartCommand re-applies each container start.
RUN <<'EGRESS_SETUP'
cat > /opt/sbe-egress.sh <<'EGRESS'
#!/bin/sh
set -eu
iptables -F OUTPUT
DNS=$(awk '/^nameserver / {print $2}' /etc/resolv.conf | tr '\n' ' ')
for s in $DNS; do
  iptables -A OUTPUT -p udp -d "$s" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$s" --dport 53 -j ACCEPT
done
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p tcp -j ACCEPT
iptables -A OUTPUT -p icmp -j ACCEPT
iptables -A OUTPUT -j DROP
EGRESS
chmod 0755 /opt/sbe-egress.sh
EGRESS_SETUP

USER vscode

# Global sbe config: extend built-in profiles to denyRead credential paths.
# In sbe 0.4 a profile keyed by an ecosystem name merges onto that built-in;
# `extends` is only for chaining custom bases and self-referencing it is
# rejected as a cycle. Verify a merge with `sbe inspect`, not `sbe profiles`
# (the latter prints built-in defaults only).
# 0.4's built-ins already deny ~/.config/gh, ~/.pypirc and /workspace/.env*;
# ~/.claude (the Claude OAuth token and session state) is not covered by them,
# which is the main reason this file still exists.
RUN <<'SBE_CONFIG'
mkdir -p /home/vscode/.config/sbe
cat > /home/vscode/.config/sbe/config.yaml <<'YAML'
profiles:
  node:
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - /workspace/.git/config
  rust:
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - /workspace/.git/config
  python:
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - /workspace/.git/config
      - ~/.pypirc
  java:
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - ~/.m2/settings.xml
      - ~/.gradle/gradle.properties
  elixir:
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
YAML
SBE_CONFIG

# Install Aikido Safe Chain: screens npm/PyPI installs against Aikido Intel by
# routing registry downloads through a local proxy, blocking known-malicious
# packages (including transitive ones) before they land.
#
# --ci installs PATH shims (~/.safe-chain/shims) instead of shell aliases. The
# alias flavour only fires in interactive shells, and Claude Code runs its
# commands non-interactively, so aliases would leave the container's main
# consumer of npm unprotected.
#
# The installer verifies the checksum of the binary it downloads; the SHA256
# below covers the installer script itself and is tied to this exact version
# (the script hardcodes the version it installs), so bump both together.
# renovate: datasource=github-releases depName=AikidoSec/safe-chain
ARG SAFE_CHAIN_VERSION=1.5.15
ARG SAFE_CHAIN_INSTALLER_SHA256=de0565e3d6346407a604e84e639e95fea8758748063da2216bbfdca5feda5dd2
RUN curl -fsSL "https://github.com/AikidoSec/safe-chain/releases/download/${SAFE_CHAIN_VERSION}/install-safe-chain.sh" -o /tmp/install-safe-chain.sh && \
  echo "${SAFE_CHAIN_INSTALLER_SHA256}  /tmp/install-safe-chain.sh" | sha256sum -c - && \
  sh /tmp/install-safe-chain.sh --ci && \
  rm /tmp/install-safe-chain.sh

# Safe Chain's CA into the system trust store.
#
# Safe Chain screens Python by MITM-ing the download through a local proxy, so
# the client must trust its CA. It drops a bundle in /tmp and points the child
# at it -- but the child runs inside the sbe cage, which gives sandboxed
# processes a private temp root, so that path is unreadable and the handshake
# fails with "invalid peer certificate: UnknownIssuer". Every uv install breaks.
#
# /etc/ssl/certs IS readable inside the cage, so install the CA there instead
# and point the TLS clients at the system bundle.
#
# The tradeoff is explicit: a MITM CA in the system store means whoever holds
# ~/.safe-chain/certs/ca-key.pem can mint a trusted cert for any host in this
# container. That is the trust Safe Chain already asks for by design -- this
# only makes it durable and readable from inside the sandbox. The key stays
# denied to sandboxed children, which is what keeps a caged install from
# minting its own.
USER root
RUN cp /home/vscode/.safe-chain/certs/ca-cert.pem \
       /usr/local/share/ca-certificates/safe-chain.crt && \
    update-ca-certificates >/dev/null 2>&1 && \
    echo "[build] safe-chain CA installed into system trust store"
USER vscode

# Point TLS clients at the system bundle rather than Safe Chain's /tmp copy.
# UV_NATIVE_TLS makes uv use the OS trust store instead of its vendored roots.
ENV UV_NATIVE_TLS=1 \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# Baseline shim order for EVERY process, login shell or not. The .zshrc hook
# only repairs what fnm disturbs in interactive zsh; this is what makes the
# chain hold for `bash -c` and `sh -c`, which is how Claude Code and opencode
# actually invoke commands.
# Order: Safe Chain (screen) -> sbe (cage) -> real binary.
ENV PATH="/home/vscode/.safe-chain/shims:/usr/local/bin/sbe-shims:/home/vscode/.safe-chain/bin:$PATH"

# Startup health check.
#
# Presence checks are not enough here, and that is the whole lesson of this
# stack: a merged image once passed "both shims are on PATH" while Safe Chain's
# proxy layer was dead (its CA bundle lives in /tmp, which the sbe cage denies)
# and every Python install was broken. So this asserts EFFECTS -- a known-bad
# fixture is actually refused, and a sandboxed child is actually denied -- not
# that files exist.
#
# It matters because every failure in this stack is silent. Safe Chain prints
# nothing on a clean package, so "screening ran and found nothing" and
# "screening never ran" look identical. Claude Code runs non-interactively
# under bypassPermissions, so there is no human to notice either.
RUN <<'HEALTHCHECK_SETUP'
cat > /opt/supply-chain-healthcheck.sh <<'CHECK'
#!/bin/sh
set -eu
FAILED=0
fail() { echo "  FAIL: $1" >&2; FAILED=1; }
ok()   { echo "  ok:   $1"; }

echo "[supply-chain] verifying the chain is actually enforcing..."

# --- layer presence (cheap, and locates a break) ---
command -v safe-chain >/dev/null 2>&1 || fail "safe-chain not on PATH"
command -v sbe        >/dev/null 2>&1 || fail "sbe not on PATH"

# --- PATH order: Safe Chain outermost, sbe next ---
npm_path=$(command -v npm 2>/dev/null || echo none)
case "$npm_path" in
  "$HOME/.safe-chain/shims/"*) ok "npm -> Safe Chain shim" ;;
  *) fail "npm resolves to '$npm_path', not the Safe Chain shim" ;;
esac
inner=$(PATH=$(echo "$PATH" | sed "s|$HOME/.safe-chain/shims:||") command -v npm 2>/dev/null || echo none)
case "$inner" in
  /usr/local/bin/sbe-shims/*) ok "next hop -> sbe shim" ;;
  *) fail "second hop is '$inner', not the sbe shim (cage layer skipped)" ;;
esac

# --- EFFECT 1: the cage actually denies a credential read ---
if sbe run --profile node -- cat "$HOME/.claude/.credentials.json" 2>&1 |
     grep -q "Permission denied"; then
  ok "sbe denies ~/.claude to a sandboxed child"
else
  # An absent file is not proof of a working cage; make one and retry.
  mkdir -p "$HOME/.claude" && echo probe > "$HOME/.claude/.credentials.json"
  if sbe run --profile node -- cat "$HOME/.claude/.credentials.json" 2>&1 |
       grep -q "Permission denied"; then
    ok "sbe denies ~/.claude to a sandboxed child"
  else
    fail "sandboxed child could read ~/.claude -- cage not enforcing"
  fi
fi

# --- EFFECT 2: npm package-manager config is age-gated ---
age=$(npm config get min-release-age 2>/dev/null | tr -d '\r')
case "$age" in
  ""|null|undefined|0) fail "npm min-release-age is '$age' -- age gate off" ;;
  *) ok "npm min-release-age=$age" ;;
esac

# --- EFFECT 3 (opt-in): a known-bad fixture is actually refused ---
# Costs a network round trip, so it is off by default. Set
# SUPPLY_CHAIN_DEEP_CHECK=1 to exercise the real screening path.
if [ "${SUPPLY_CHAIN_DEEP_CHECK:-0}" = "1" ]; then
  d=$(mktemp -d)
  ( cd "$d" && echo '{"name":"probe","version":"1.0.0"}' > package.json
    if npm install safe-chain-test >/dev/null 2>&1 && [ -d node_modules/safe-chain-test ]; then
      echo "  FAIL: known-malicious fixture INSTALLED -- screening is not active" >&2
      exit 1
    fi ) || FAILED=1
  [ "$FAILED" = "1" ] || ok "known-malicious npm fixture refused"
  rm -rf "$d"
  # Deliberately npm-only. Safe Chain screens Python through its proxy, which
  # sbe's reserved HTTPS_PROXY makes unreachable inside the cage, so there is
  # no Python screening here to assert. Checking it would fail honestly but
  # noisily every start; claiming it passes would be worse.
fi

if [ "$FAILED" = "1" ]; then
  echo "======================================================================" >&2
  echo "SUPPLY CHAIN HEALTH CHECK FAILED" >&2
  echo "Installs may run WITHOUT screening, WITHOUT the sandbox, or both." >&2
  echo "Do not install dependencies until this passes." >&2
  echo "======================================================================" >&2
  exit 1
fi
echo "[supply-chain] all layers enforcing."
CHECK
chmod 0755 /opt/supply-chain-healthcheck.sh
HEALTHCHECK_SETUP

# supply-chain-hardening: hardened defaults for every package manager present.
#
# This is the layer the other two do not cover. sbe contains what an install
# can do and Safe Chain judges whether a package is known-bad; this decides how
# the package managers behave in the first place -- age gates, script blocking,
# locked resolution, signature checks -- across npm, pnpm, yarn, pip, uv, bun,
# maven, gradle, nuget and more.
#
# The CI-shaped harden.sh is used rather than the Ansible role deliberately: it
# is the subset without the PAM layer, podman, or interactive npq. npq would be
# redundant here anyway, since Safe Chain's PATH shims screen interactive and
# non-interactive shells alike.
#
# Pinned to a commit, not a tag: the action postdates v1.2.1 and there is no
# release containing it yet.
# renovate: datasource=github-tags depName=echennells/supply-chain-hardening
ARG SCH_COMMIT=22be713
ARG SCH_HARDEN_SHA256=f595c82497721ead72c5fb8bd6b60b024d9b2ef08d96c0adff5290918d5b85d2
USER root
RUN curl -fsSL "https://raw.githubusercontent.com/echennells/supply-chain-hardening/${SCH_COMMIT}/action/harden.sh" \
      -o /tmp/harden.sh && \
    echo "${SCH_HARDEN_SHA256}  /tmp/harden.sh" | sha256sum -c - && \
    install -m 0755 /tmp/harden.sh /opt/supply-chain-harden.sh && \
    rm /tmp/harden.sh

# Write the config-file layer (~/.npmrc, uv.toml, bunfig.toml, cargo, ...) at
# build time. Config files are shell-independent, which is what makes them the
# primary control: they apply to `bash -c` from an agent exactly as they do to
# a human's login shell.
USER vscode
RUN bash /opt/supply-chain-harden.sh --emit=plain || \
    echo "[build] harden.sh reported degraded ecosystems; see the table above"

# The env layer, promoted from /etc/profile.d to image ENV.
#
# harden.sh calls env a "redundant second layer behind (1)", and routes it
# through a platform adapter because CI needs step-to-step propagation. A
# container has a better mechanism than either: ENV reaches every process
# regardless of shell, so agent tool calls through `bash -c` -- which never
# source /etc/profile.d -- get the env layer too.
#
# NPM_CONFIG_MIN_RELEASE_AGE is the one value that conflicted with upstream's
# containerEnv (upstream 1 day, this 2). npm resolves env above .npmrc, so
# leaving upstream's in place would silently halve the gate. Upstream's copies
# of these keys are dropped from devcontainer.json; this is the single source
# of truth, derived from release_age_hours=48.
ENV NPM_CONFIG_IGNORE_SCRIPTS=true \
    NPM_CONFIG_AUDIT=true \
    NPM_CONFIG_SAVE_EXACT=true \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_MIN_RELEASE_AGE=2 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_LINK_MODE=copy \
    COMPOSER_ALLOW_SUPERUSER=1 \
    GOSUMDB=sum.golang.org \
    GOPROXY=https://proxy.golang.org,direct \
    GOFLAGS=-mod=readonly \
    GOTOOLCHAIN=local \
    GRADLE_USER_HOME=/home/vscode/.gradle \
    DOTNET_NUGET_SIGNATURE_VERIFICATION=true

# Copy post_install script
COPY --chown=vscode:vscode post_install.py /opt/post_install.py
