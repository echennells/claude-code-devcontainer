#!/usr/bin/env bash
# Effects-based verification of the four-layer supply-chain stack.
#
# Asserts what the layers DO, not that their files exist. A presence check once
# passed on a build where Safe Chain's proxy was dead and every Python install
# was broken -- see SBE_DEVC_NOTES.md section 15.
#
# Run inside a built image:
#   docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
#     -v "$PWD:/repo:ro" <image> bash /repo/test/verify-supply-chain.sh
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mskip\033[0m  %s -- %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# zsh login shell, stripped of the noise a non-tty zsh emits
zl() { zsh -lic "$1" 2>/dev/null | grep -v 'zle' | tail -1; }

SC_SHIMS="$HOME/.safe-chain/shims"
SBE_SHIMS="/usr/local/bin/sbe-shims"

# ---------------------------------------------------------------- capability
# sbe needs Landlock; a runner kernel without it can still verify every other
# layer. Skip the cage assertions loudly rather than failing for the wrong
# reason -- but never skip silently.
#
# Probe with `sh -c` and not `true`: /bin/true is not in any profile's
# allowExec, so probing with it reports "no cage" on a perfectly good kernel
# and silently skips every containment assertion below.
# Which layers is this image supposed to have? The branches carry different
# subsets (sbe only, Safe Chain only, or the full merge), so detect rather than
# assume -- but announce what was detected, so a layer going missing by
# accident is visible instead of quietly untested.
SCREEN=yes; [ -d "$SC_SHIMS" ] && command -v safe-chain >/dev/null 2>&1 || SCREEN=no
printf '\n\033[1m== layers detected ==\033[0m\n'
printf '  Safe Chain (screening): %s\n' "$SCREEN"

CAGE=yes
if ! command -v sbe >/dev/null 2>&1; then
  CAGE=no; CAGE_WHY="sbe not on PATH"
elif ! sbe run --profile node -- sh -c 'exit 0' >/dev/null 2>&1; then
  CAGE=no; CAGE_WHY="sbe cannot install a policy on this kernel (Landlock >= 5.13 required)"
fi

DEFAULTS=yes; [ -f /opt/supply-chain-harden.sh ] || DEFAULTS=no
printf '  sbe (containment):      %s\n' "$CAGE"
printf '  hardened defaults:      %s\n' "$DEFAULTS"

# Whichever shim should win PATH in THIS image
if [ "$SCREEN" = yes ]; then EXPECTED_OUTER="$SC_SHIMS"; else EXPECTED_OUTER="$SBE_SHIMS"; fi

head_ "PATH chain"
npm_path=$(zl 'command -v npm')
if [ "$SCREEN" = yes ]; then
  case "$npm_path" in
    "$SC_SHIMS"/*) ok "npm -> Safe Chain shim (outer)" ;;
    *) bad "npm -> ${npm_path:-none}, expected the Safe Chain shim" ;;
  esac
  inner=$(zl "PATH=\$(echo \$PATH | sed 's|$SC_SHIMS:||') command -v npm")
else
  case "$npm_path" in
    "$SBE_SHIMS"/*) ok "npm -> sbe shim (no screening layer in this image)" ;;
    *) bad "npm -> ${npm_path:-none}, expected the sbe shim" ;;
  esac
  inner="$npm_path"
fi
if [ "$CAGE" = yes ]; then
  case "$inner" in
    "$SBE_SHIMS"/*) ok "next hop -> sbe shim (cage)" ;;
    *) bad "next hop -> ${inner:-none}, expected the sbe shim" ;;
  esac
else
  skip "sbe hop" "no sbe layer in this image"
fi
real=$(zl "PATH=\$(echo \$PATH | sed 's|$SC_SHIMS:||; s|$SBE_SHIMS:||') command -v npm")
[ -n "$real" ] && ok "chain terminates at a real npm ($real)" \
                || bad "chain does not terminate at a real npm"

# PATH order must survive a cd -- fnm re-prepends its multishell dir
mkdir -p /tmp/vsc-proj && echo 24 > /tmp/vsc-proj/.nvmrc
after_cd=$(zsh -lic 'cd /tmp/vsc-proj && command -v npm' 2>/dev/null | grep -v 'zle' | tail -1)
case "$after_cd" in
  "$EXPECTED_OUTER"/*) ok "order survives cd into an .nvmrc project" ;;
  *) bad "after cd npm -> ${after_cd:-none}, expected $EXPECTED_OUTER (fnm shadowed the shims)" ;;
esac

head_ "Package-manager defaults (supply-chain-hardening)"
if [ "$DEFAULTS" = no ]; then
  skip "hardened defaults" "supply-chain-hardening not applied in this image"
fi
age_login=$(zl 'npm config get min-release-age')
if [ "$DEFAULTS" = yes ]; then
  case "$age_login" in
    ""|null|undefined|0) bad "min-release-age is '${age_login:-empty}' -- age gate off" ;;
    *) ok "min-release-age=$age_login (login shell)" ;;
  esac
fi
# The agent path: profile.d never fires here, so this proves ENV + npmrc carry it
if [ "$DEFAULTS" = yes ]; then
  age_nonlogin=$(bash -c 'npm config get min-release-age' 2>/dev/null | tail -1)
  [ "$age_nonlogin" = "$age_login" ] \
    && ok "same gate in a non-login shell (agent path)" \
    || bad "non-login shell sees '$age_nonlogin', login sees '$age_login'"
  ig=$(bash -c 'npm config get ignore-scripts' 2>/dev/null | tail -1)
  [ "$ig" = "true" ] && ok "ignore-scripts=true" || bad "ignore-scripts=$ig"
fi

head_ "Reputation screening (Safe Chain)"
work=$(mktemp -d); cd "$work" || exit 1
if [ "$SCREEN" = no ]; then
  skip "screening assertions" "Safe Chain not installed in this image"
fi
echo '{"name":"probe","version":"1.0.0"}' > package.json
if [ "$SCREEN" = yes ]; then
  timeout 300 zsh -lic "cd $work && npm install safe-chain-test" >/dev/null 2>&1 || true
  if [ -d node_modules/safe-chain-test ]; then
    bad "known-malicious npm fixture INSTALLED -- screening not active"
  else
    ok "known-malicious npm fixture refused"
  fi
fi
rm -rf node_modules
if timeout 300 zsh -lic "cd $work && npm install is-odd" >/dev/null 2>&1 && [ -d node_modules/is-odd ]; then
  ok "benign npm install still works"
else
  bad "benign npm install failed -- screening is blocking good packages"
fi

head_ "Python path (regression: Safe Chain CA vs the cage's private /tmp)"
# This broke every uv install with UnknownIssuer before the shim granted
# --allow-read on the CA bundle. It is the single most valuable regression here.
if command -v uv >/dev/null 2>&1; then
  if timeout 300 zsh -lic "cd /tmp && uv venv cienv >/dev/null 2>&1 && . /tmp/cienv/bin/activate && uv pip install six" >/dev/null 2>&1; then
    ok "benign uv install works (CA bundle reachable inside the cage)"
  else
    bad "uv install failed -- likely UnknownIssuer from the CA bundle regression"
  fi
else
  skip "uv install" "uv not present"
fi

head_ "Containment (sbe)"
if [ "$CAGE" = "no" ]; then
  skip "cage assertions" "$CAGE_WHY"
else
  mkdir -p "$HOME/.claude" "$HOME/.ssh"
  echo probe > "$HOME/.claude/.credentials.json"
  echo probe > "$HOME/.ssh/id_rsa"
  # NOTE: capture into a variable before matching. A denied read makes the
  # caged command exit non-zero, and under `set -o pipefail` a
  # `sbe ... | grep -q` pipeline returns THAT, not grep's result -- so the
  # assertion inverts and a working cage reports as a failure.
  denied() { case "$1" in *"Permission denied"*) return 0 ;; *) return 1 ;; esac; }

  for prof in node python; do
    out=$(sbe run --profile "$prof" -- cat "$HOME/.claude/.credentials.json" 2>&1)
    if denied "$out"; then ok "cage denies ~/.claude ($prof profile)"
    else bad "sandboxed child read ~/.claude under the $prof profile"; fi
  done

  out=$(sbe run --profile node -- cat "$HOME/.ssh/id_rsa" 2>&1)
  denied "$out" && ok "cage denies ~/.ssh" || bad "sandboxed child read ~/.ssh"

  # The cage must survive fork/exec, which is the whole point of Landlock
  out=$(sbe run --profile node -- sh -c 'sh -c "cat $HOME/.claude/.credentials.json"' 2>&1)
  denied "$out" && ok "cage inherited through nested sh" || bad "cage lost across fork/exec"
  # Token must not be visible to a shimmed install
  cd "$work" || exit 1
  cat > package.json <<'PKG'
{"name":"probe","version":"1.0.0","scripts":{"t":"node -e \"console.log(0+process.env.CLAUDE_CODE_OAUTH_TOKEN)\""}}
PKG
  tok=$(CLAUDE_CODE_OAUTH_TOKEN=sk-ci-probe zsh -lic "cd $work && npm run t" 2>/dev/null | tail -1)
  [ "$tok" = "NaN" ] && ok "OAuth token stripped inside the shim perimeter" \
                     || bad "token visible to shimmed child (got '$tok')"
fi

head_ "Claude deny-list (absolute-path bypasses)"
if [ -f /opt/post_install.py ]; then
  python3 /opt/post_install.py >/dev/null 2>&1
  s="$HOME/.claude/settings.json"
  if [ -f "$s" ]; then
    for want in '/usr/local/bin/uv:' '.local/bin/' '.local/share/uv/python/' '.fnm/'; do
      if grep -q -- "$want" "$s"; then ok "deny-list covers $want"
      else bad "deny-list missing $want"; fi
    done
  else
    bad "post_install.py wrote no settings.json"
  fi
else
  skip "deny-list" "/opt/post_install.py not present"
fi

head_ "Startup health check"
if [ -x /opt/supply-chain-healthcheck.sh ]; then
  if /opt/supply-chain-healthcheck.sh >/dev/null 2>&1; then
    ok "health check passes"
  else
    bad "health check failed"
  fi
else
  skip "health check" "script not present"
fi

printf '\n\033[1m== summary ==\033[0m\n  passed=%d failed=%d skipped=%d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
