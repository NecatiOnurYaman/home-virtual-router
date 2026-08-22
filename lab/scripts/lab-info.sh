#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
config="$repo_dir/lab/config/defaults.env"
checker="$repo_dir/router/scripts/check-dependencies.sh"

printf 'Home Virtual Router lab: Stage R4 IPv4 masquerading\n'
printf 'Repository: %s\n' "$repo_dir"
if [ -r /etc/os-release ]; then
  distribution="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1 | sed 's/^"//; s/"$//')"
  printf 'Distribution: %s\n' "${distribution:-unknown Linux distribution}"
else
  printf 'Distribution: unavailable (run this command inside the Ubuntu UTM VM)\n'
fi
printf 'Kernel: %s %s\n' "$(uname -s)" "$(uname -r)"
printf 'Lab strategy: Linux namespaces inside the dedicated Ubuntu UTM VM\n'
printf 'Topology state: see namespace report below\n'
printf 'Defaults: %s\n' "$config"
if [ "$(uname -s)" = "Linux" ] && [ -f /etc/home-virtual-router-lab ]; then
  printf 'Isolation marker: present\n'
else
  printf 'Isolation marker: absent\n'
fi

printf '\nConfigured lab subnets:\n'
while IFS='=' read -r key value; do
  case "$key" in
    UPSTREAM_SUBNET|LAN_SUBNET) printf '  %-16s %s\n' "$key" "$value" ;;
  esac
done < "$config"

printf '\nR2 namespaces (informational only):\n'
for namespace in hvr-upstream hvr-router hvr-client; do
  if command -v ip >/dev/null 2>&1 && ip netns list 2>/dev/null | awk '{print $1}' | grep -F -x -- "$namespace" >/dev/null 2>&1; then
    printf '  present %s\n' "$namespace"
  else
    printf '  absent  %s\n' "$namespace"
  fi
done

printf '\nDependency availability:\n'
if ! "$checker"; then
  printf 'Dependency status: incomplete (no packages were installed)\n'
fi
