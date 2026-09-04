#!/usr/bin/env bash
#
# Build this fork and install it over the herdr on PATH.
#
# For local iteration on the patch. The binaries that actually go onto machines
# come from the fork's own `Build artifacts (manual)` workflow, which uses the
# upstream release recipe for every target; this script only covers the host.
#
# Three things it does that are easy to forget by hand:
#
#   * stamps the build. A stock 0.8.2 and a patched 0.8.2 are otherwise the same
#     string in `herdr status`, and there is no way back from that confusion.
#     With HERDR_BUILD_CHANNEL set, `version()` renders `0.8.2-<channel>.<id>`.
#   * pins updates off. `[update] version_check` is on by default, and one
#     accepted prompt replaces the patched binary with the stock one.
#   * says how to activate it. Replacing the file changes nothing on its own:
#     the running server keeps its own copy, and on v0.8.2 the sidebar grouping
#     this fork patches is computed server-side.
#
# Usage:
#   scripts/build-herdr-local.sh [--target <triple>] [--no-install] [--keep-updates]

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly INSTALL_PATH="${HERDR_INSTALL_PATH:-$HOME/.local/bin/herdr}"
readonly CONFIG_PATH="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
readonly CHANNEL="${HERDR_BUILD_CHANNEL:-many-spaces}"

target=''
install_binary=1
pin_updates=1

while (( $# )); do
  case "$1" in
    --target) target="${2:?--target needs a triple}"; shift 2 ;;
    --no-install) install_binary=0; shift ;;
    --keep-updates) pin_updates=0; shift ;;
    -h|--help) sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "build-herdr-local: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

# --- prerequisites -----------------------------------------------------------
#
# rust-toolchain.toml pins 1.96.1, and only rustup honours that pin. A Homebrew
# cargo silently builds with whatever version it happens to be, which is not the
# version this tree is locked against.
command -v rustup >/dev/null 2>&1 || die \
  "rustup is required (rust-toolchain.toml pins 1.96.1; a Homebrew cargo ignores it).
   Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"

# build.rs builds the vendored libghostty-vt with Zig 0.15.x. Upstream's macOS
# release job uses Homebrew's zig@0.15 specifically, so prefer that one.
if [[ -z "${ZIG:-}" ]]; then
  if brew_prefix="$(brew --prefix zig@0.15 2>/dev/null)" && [[ -x "$brew_prefix/bin/zig" ]]; then
    ZIG="$brew_prefix/bin/zig"
  elif command -v zig >/dev/null 2>&1; then
    ZIG="$(command -v zig)"
  else
    die "zig 0.15.x is required to build the vendored libghostty-vt.
   macOS: brew install zig@0.15    elsewhere: https://ziglang.org/download/"
  fi
fi
export ZIG
zig_version="$("$ZIG" version)"
[[ "$zig_version" == 0.15.* ]] || die "zig $zig_version found at $ZIG, but 0.15.x is required"

# --- build -------------------------------------------------------------------
commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
dirty=''
git -C "$REPO_ROOT" diff --quiet || dirty='-dirty'

export HERDR_BUILD_CHANNEL="$CHANNEL"
export HERDR_BUILD_ID="${commit}${dirty}"
export HERDR_BUILD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
# Same values the upstream release matrix uses; the manual workflow defaults to
# ReleaseSafe/false, which is not what a stock binary is built with.
export LIBGHOSTTY_VT_OPTIMIZE="${LIBGHOSTTY_VT_OPTIMIZE:-ReleaseFast}"
export LIBGHOSTTY_VT_SIMD="${LIBGHOSTTY_VT_SIMD:-true}"

say "building ${HERDR_BUILD_CHANNEL}.${HERDR_BUILD_ID}${target:+ for $target} (zig $zig_version)"
if [[ -n "$target" ]]; then
  rustup target add "$target" >/dev/null
  cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --locked --target "$target"
  built="$REPO_ROOT/target/$target/release/herdr"
else
  cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --locked
  built="$REPO_ROOT/target/release/herdr"
fi
[[ -x "$built" ]] || die "build reported success but $built is missing"
say "built $built"

if (( ! install_binary )); then
  echo "not installing (--no-install)"
  exit 0
fi

# A cross-built binary cannot be installed over the host's herdr.
if [[ -n "$target" && "$target" != "$(rustc -vV | awk '/^host:/{print $2}')" ]]; then
  die "refusing to install a $target binary on this host; copy it to the target machine instead"
fi

# --- install -----------------------------------------------------------------
mkdir -p "$(dirname "$INSTALL_PATH")"
if [[ -e "$INSTALL_PATH" ]]; then
  backup="$INSTALL_PATH.$("$INSTALL_PATH" --version 2>/dev/null | awk '{print $2}' || echo unknown).bak"
  cp -p "$INSTALL_PATH" "$backup"
  say "previous binary kept at $backup"
fi
install -m 0755 "$built" "$INSTALL_PATH"
say "installed $INSTALL_PATH -> $("$INSTALL_PATH" --version)"

# --- keep the update checker from replacing it -------------------------------
if (( pin_updates )); then
  if [[ -f "$CONFIG_PATH" ]] && grep -qE '^[[:space:]]*version_check[[:space:]]*=[[:space:]]*false' "$CONFIG_PATH"; then
    say "updates already pinned off in $CONFIG_PATH"
  else
    mkdir -p "$(dirname "$CONFIG_PATH")"
    [[ -f "$CONFIG_PATH" ]] && cp -p "$CONFIG_PATH" "$CONFIG_PATH.bak"
    {
      printf '\n[update]\n'
      printf '# Pinned by scripts/build-herdr-local.sh: this install is a patched build,\n'
      printf '# and an accepted update prompt would replace it with the stock binary.\n'
      printf 'version_check = false\n'
    } >> "$CONFIG_PATH"
    say "appended [update] version_check = false to $CONFIG_PATH (previous kept as $CONFIG_PATH.bak)"
  fi
fi

cat <<'ACTIVATE'

The new binary is on disk, and the running server is still the old one — it keeps
its own copy, and on v0.8.2 the sidebar grouping this fork changes is computed
server-side. To pick it up:

  1. detach from herdr (prefix+q),
  2. herdr server stop
  3. herdr

Sessions and worktrees survive that; a 0.8.2 restart restores the whole
arrangement from its session snapshot.
ACTIVATE
