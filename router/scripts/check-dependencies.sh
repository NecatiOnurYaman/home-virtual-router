#!/usr/bin/env bash
set -euo pipefail

default_commands="ip nft dnsmasq sysctl ping curl tcpdump python3 ss systemctl"
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
      sysctl) package="procps" ;;
      ping) package="iputils-ping" ;;
      curl) package="curl" ;;
      tcpdump) package="tcpdump" ;;
      python3) package="python3" ;;
      ss) package="iproute2" ;;
      systemctl) package="systemd" ;;
      *) package="package providing $command_name" ;;
    esac
    printf '  missing %s (Ubuntu/Debian package: %s)\n' "$command_name" "$package"
  fi
done

if [ "$missing" -ne 0 ]; then
  printf '\nOne or more dependencies are missing. Install them explicitly inside the lab VM.\n' >&2
  exit 1
fi

printf 'All requested dependencies are available.\n'
