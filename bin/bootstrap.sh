#!/bin/sh
# System Diagnostics secure-execution bootstrap.
#
# Sourced immediately after a script's shebang. It normalizes the environment
# so that no diagnostic helper can be influenced by anything inherited from the
# long-lived Quickshell shell process:
#
#   * PATH is replaced with a fixed, root-owned allowlist. A shadow executable
#     dropped anywhere else on the user's PATH (~/bin, a repo dir, ...) can
#     never be resolved here.
#   * Locale is pinned to C so ip/ping/df/lsblk/sensors output parsing is
#     deterministic.
#   * Dynamic-loader and interpreter module injection variables are dropped.
#   * The plugin state directory is guaranteed to exist.
#
# This plugin is READ-ONLY with respect to system configuration: nothing here
# grants write access to /etc or ~/.config. The state dir holds only diagnostic
# cache and scan history.
umask 077

export PATH=/usr/bin:/bin
export LC_ALL=C

unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_LIBRARY_PATH_64 \
  PYTHONHOME PYTHONSTARTUP PYTHONPATH PERL5LIB PERLLIB 2>/dev/null || true

: "${SYSDIAG_STATE_DIR:=$HOME/.local/state/system-diagnostics}"
export SYSDIAG_STATE_DIR
mkdir -p "$SYSDIAG_STATE_DIR" 2>/dev/null || true

# Scan mode (quick|full). Sections read this to decide whether to run expensive
# probes (network/GPU/SMART). Defaults to quick so an accidental direct run is
# cheap.
: "${SYSDIAG_MODE:=quick}"
export SYSDIAG_MODE
