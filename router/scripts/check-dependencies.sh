#!/usr/bin/env bash
set -euo pipefail

default_commands="ip nft dnsmasq dhclient sysctl ping curl tcpdump python3 ss systemctl getent dig pmacctd ps readlink"
commands="${HVR_CHECK_COMMANDS:-$default_commands}"
missing=0

printf 'Checking Linux router-lab dependencies...\n'
for command_name in $commands; do
  case "$command_name" in
    *[!a-zA-Z0-9_.+-]*)
      printf 'error: invalid command name: %s\n' "$command_name" >&2
      exit 2
      ;;
  esac
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '  ok      %s\n' "$command_name"
  else
    missing=1
    case "$command_name" in
      ip) package="iproute2" ;;
      nft) package="nftables" ;;
      dnsmasq) package="dnsmasq" ;;
      dhclient) package="isc-dhcp-client" ;;
      sysctl) package="procps" ;;
      ping) package="iputils-ping" ;;
      curl) package="curl" ;;
      tcpdump) package="tcpdump" ;;
      python3) package="python3" ;;
      ss) package="iproute2" ;;
      systemctl) package="systemd" ;;
      getent) package="libc-bin" ;;
      dig) package="dnsutils" ;;
      pmacctd) package="pmacct" ;;
      ps) package="procps" ;;
      readlink) package="coreutils" ;;
      *) package="package providing $command_name" ;;
    esac
    printf '  missing %s (Ubuntu/Debian package: %s)\n' "$command_name" "$package"
  fi
done

if printf '%s\n' " $commands " | grep -F ' pmacctd ' >/dev/null 2>&1 && command -v pmacctd >/dev/null 2>&1; then
  version_output="$(pmacctd -V 2>&1 || true)"
  if [ -z "$version_output" ]; then
    printf '  missing pmacctd capability metadata (pmacctd -V returned no output)\n'
    missing=1
  else
    printf '  info    %s\n' "$(printf '%s\n' "$version_output" | head -n 1)"
    if command -v dpkg-query >/dev/null 2>&1; then
      package_version="$(dpkg-query -W -f='${Version}' pmacct 2>/dev/null || true)"
      [ -z "$package_version" ] || printf '  info    Ubuntu/Debian pmacct package %s\n' "$package_version"
    fi
    printf '          nfprobe/IPFIX capability is proven by the namespace-scoped startup check\n'
  fi
fi

if [ "$missing" -ne 0 ]; then
  printf '\nOne or more dependencies are missing. Install them explicitly inside the lab VM.\n' >&2
  exit 1
fi

printf 'All requested dependencies are available.\n'
