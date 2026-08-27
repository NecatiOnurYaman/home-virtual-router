#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab/scripts/topology-common.sh
source "$script_dir/topology-common.sh"
require_root
load_topology_config
[ "$TELEMETRY_MODE" = "lab" ] || die "R11 isolated acceptance requires TELEMETRY_MODE=lab"
[ "$METRICS_EXPORT_HOST" = "$UPSTREAM_GATEWAY" ] || die "R11 isolated receiver must use the upstream namespace address"
mkdir -p -- "$METRICS_EXPORT_RUNTIME_DIR"
stop_metrics_exporter_if_present
rm -f -- "$METRICS_EXPORT_RESULT_FILE" "$METRICS_EXPORT_READY_FILE"
receiver_pid=""
receiver_starttime=""
cleanup() {
  "$script_dir/disable-metrics-export.sh" >/dev/null 2>&1 || true
  if [ -n "$receiver_pid" ] && process_is_running "$receiver_pid"; then
    current="$(process_starttime "$receiver_pid" 2>/dev/null || true)"
    command_line="$(tr '\0' '\n' < "/proc/$receiver_pid/cmdline" 2>/dev/null || true)"
    if [ "$current" = "$receiver_starttime" ] && printf '%s\n' "$command_line" | grep -F -x -- "$METRICS_TEST_RECEIVER" >/dev/null; then
      kill "$receiver_pid"
      wait "$receiver_pid" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT
ip netns exec "$UPSTREAM_NAMESPACE" python3 "$METRICS_TEST_RECEIVER" --bind "$METRICS_EXPORT_HOST" --port "$METRICS_EXPORT_PORT" --path "$METRICS_EXPORT_PATH" --router-id "$ROUTER_ID" --expected-source "$ROUTER_WAN" --count 2 --deadline-seconds 12 --result "$METRICS_EXPORT_RESULT_FILE" --ready "$METRICS_EXPORT_READY_FILE" &
receiver_pid=$!
receiver_starttime="$(process_starttime "$receiver_pid")"
for _ in {1..40}; do [ -e "$METRICS_EXPORT_READY_FILE" ] && break; process_is_running "$receiver_pid" || die "test receiver exited before becoming ready"; sleep 0.05; done
[ -e "$METRICS_EXPORT_READY_FILE" ] || die "test receiver did not become ready"
# Prove malformed JSON is rejected without becoming an accepted snapshot.
ip netns exec "$ROUTER_NAMESPACE" python3 - "$METRICS_EXPORT_HOST" "$METRICS_EXPORT_PORT" "$METRICS_EXPORT_PATH" <<'PY'
import http.client, sys
c = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]), timeout=2)
c.request("POST", sys.argv[3], b"{}", {"Content-Type": "application/json"})
r = c.getresponse(); r.read(); assert r.status == 400
PY
HVR_METRICS_EXPORT_INTERVAL_SECONDS=0.5 "$script_dir/enable-metrics-export.sh"
for _ in {1..160}; do process_is_running "$receiver_pid" || break; sleep 0.05; done
wait "$receiver_pid" || die "test receiver did not accept two valid snapshots"
receiver_pid=""
python3 - "$METRICS_EXPORT_RESULT_FILE" "$ROUTER_WAN" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["accepted"] == 2 and result["rejected"] >= 1
assert all(item["source"] == sys.argv[2] for item in result["requests"])
assert result["requests"][0]["timestamp"] < result["requests"][1]["timestamp"]
print(json.dumps({"accepted": result["accepted"], "rejected": result["rejected"], "source": sys.argv[2], "timestamps": [item["timestamp"] for item in result["requests"]]}, sort_keys=True))
PY
"$script_dir/disable-metrics-export.sh"
echo "R11 acceptance passed: real namespace HTTP pushes were validated; R1-R10 state remains intact."
