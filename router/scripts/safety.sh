#!/usr/bin/env bash

# Shared guards for future Linux lab scripts. Sourcing this file changes no state.

readonly HVR_LAB_MARKER="/etc/home-virtual-router-lab"

die() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

require_linux() {
  [ "$(uname -s)" = "Linux" ] || die "this command must run inside the Linux lab VM"
}

require_lab_environment() {
  require_linux || return 1
  [ -f "$HVR_LAB_MARKER" ] || die "lab marker not found at $HVR_LAB_MARKER; refusing to modify networking"
}

require_explicit_name() {
  local kind="${1:-name}"
  local value="${2:-}"
  [ -n "$value" ] || die "$kind must be specified explicitly"
  case "$value" in
    *[!a-zA-Z0-9_.-]*) die "$kind contains unsafe characters: $value" ;;
  esac
}

require_explicit_interface() {
  local value="${1:-}"
  require_explicit_name "interface" "$value" || return 1
  [ "$value" != "lo" ] || die "loopback is not an allowed lab interface"
  case "$value" in
    hvr-*) return 0 ;;
    *) die "lab interface must use the explicit hvr- prefix: $value" ;;
  esac
}

require_not_default_route_interface() {
  local value="${1:-}"
  local default_interfaces
  require_explicit_interface "$value" || return 1
  command -v ip >/dev/null 2>&1 || die "ip is required to identify the VM default-route interface"
  default_interfaces="$(ip -o route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')"
  if printf '%s\n' "$default_interfaces" | grep -F -x -- "$value" >/dev/null 2>&1; then
    die "interface $value carries the VM default route; refusing to use it for the lab"
  fi
}

require_explicit_namespace() {
  local value="${1:-}"
  require_explicit_name "namespace" "$value" || return 1
  case "$value" in
    hvr-*) return 0 ;;
    *) die "lab namespace must use the explicit hvr- prefix: $value" ;;
  esac
}

require_explicit_nft_table() {
  local value="${1:-}"
  require_explicit_name "nftables table" "$value" || return 1
  case "$value" in
    hvr-*) return 0 ;;
    *) die "lab nftables table must use the explicit hvr- prefix: $value" ;;
  esac
}
