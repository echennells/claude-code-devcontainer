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
ARG SBE_VERSION=sbexec-v0.3.2
USER root
RUN ARCH=$(dpkg --print-architecture) && \
  case "${ARCH}" in \
    amd64) T=x86_64-unknown-linux-musl;  SHA=315cc352f3c663b2555e33a00ad850e7cafca6fefdfdad2d35726ad268bf4caf ;; \
    arm64) T=aarch64-unknown-linux-musl; SHA=345122b20f2cc8a05f65cc404afd909f85789a73fba93c3784c8b5c753dac99b ;; \
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
# Do NOT pass --audit by default — sbe v0.3.2's --audit hangs at teardown
# (kmsg reader thread doesn't exit when child does), and the kmsg/syslog
# infrastructure to make it work was deliberately removed. Network denials
# surface as the proxy's WARN line on stderr without any flags. See
# SBE_DEVC_NOTES.md §13.7 for the full rationale.
exec env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
  sbe run $profile_arg -- "$real" "$@"
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
RUN <<'SBE_CONFIG'
mkdir -p /home/vscode/.config/sbe
cat > /home/vscode/.config/sbe/config.yaml <<'YAML'
version: 1
profiles:
  node:
    extends: node
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - /workspace/.git/config
  rust:
    extends: rust
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - /workspace/.git/config
  python:
    extends: python
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - /workspace/.git/config
      - ~/.pypirc
  java:
    extends: java
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
      - ~/.m2/settings.xml
      - ~/.gradle/gradle.properties
  elixir:
    extends: elixir
    denyRead:
      - ~/.gitconfig
      - ~/.config/git
      - ~/.claude
      - ~/.config/gh
YAML
SBE_CONFIG

# Shims win PATH lookup so package-manager invocations are sandboxed by default.
ENV PATH="/usr/local/bin/sbe-shims:$PATH"

# Copy post_install script
COPY --chown=vscode:vscode post_install.py /opt/post_install.py
