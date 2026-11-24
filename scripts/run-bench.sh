#!/usr/bin/env bash
# Draai een benchmark-commando met annotatie in Grafana en resultaten in de Pushgateway.
# Draait op de load-generator = de monitoring-VM (Linux, GNU date). Vereist: curl, jq.
#
# Gebruik:
#   run-bench.sh <system> <testnaam> [--fio-json <bestand>] -- <commando...>
#
# Voorbeelden:
#   run-bench.sh ceph put-1MiB-c32 -- \
#     warp put --host=rgw1:8080 --access-key=$AK --secret-key=$SK \
#       --obj.size=1MiB --concurrent=32 --duration=5m --benchdata=results/ceph_put-1MiB-c32
#
#   run-bench.sh seaweedfs fio-randwrite-4k --fio-json results/swfs_fio-randwrite-4k.json -- \
#     fio --name=rw --directory=/mnt/swfs --rw=randwrite --bs=4k --size=4G --numjobs=8 \
#       --iodepth=32 --ioengine=libaio --direct=1 --runtime=300 --time_based \
#       --group_reporting --output-format=json --output=results/swfs_fio-randwrite-4k.json
#   (--fio-json staat vóór de '--' en wijst naar hetzelfde bestand als fio's --output)
#
# Omgevingsvariabelen:
#   GRAFANA_URL      bv. http://localhost:3000
#   GRAFANA_TOKEN    service-account-token met rol Editor (Grafana > Administration > Service accounts)
#   PUSHGATEWAY_URL  bv. http://localhost:9091
#   RESULTS_DIR      standaard ./results
#   (GRAFANA_* en PUSHGATEWAY_URL worden uit ../bench.env gelezen als die bestaat)

set -euo pipefail

# bench.env (gemaakt door setup-monitoring-vm.sh) automatisch inlezen, als die er is
BENCH_ENV="$(cd "$(dirname "$0")/.." && pwd)/bench.env"
if [[ -f "$BENCH_ENV" ]]; then set -a; . "$BENCH_ENV"; set +a; fi

usage() { sed -n '2,26p' "$0"; exit 1; }
[[ $# -ge 3 ]] || usage

SYSTEM="$1"; NAME="$2"; shift 2
FIO_JSON=""
while [[ $# -gt 0 && "$1" != "--" ]]; do
  case "$1" in
    --fio-json) FIO_JSON="$2"; shift 2 ;;
    *) echo "Onbekende optie: $1" >&2; usage ;;
  esac
done
[[ "${1:-}" == "--" ]] || usage
shift

[[ "$SYSTEM" =~ ^(ceph|seaweedfs)$ ]] || { echo "system moet ceph of seaweedfs zijn" >&2; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]    || { echo "testnaam: alleen letters, cijfers, . _ -" >&2; exit 1; }
: "${GRAFANA_URL:?}" "${GRAFANA_TOKEN:?}" "${PUSHGATEWAY_URL:?}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
mkdir -p "$RESULTS_DIR"

STAMP="$(date +%Y%m%dT%H%M%S)"
LOG="$RESULTS_DIR/${STAMP}_${SYSTEM}_${NAME}.log"

grafana() {
  curl -fsS -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" "$@"
}

# --- Start-annotatie ---
START_MS="$(date +%s%3N)"
ANN_ID="$(jq -n --argjson t "$START_MS" --arg s "$SYSTEM" --arg n "$NAME" --arg c "$*" \
  '{time:$t, tags:["benchmark",$s,$n], text:("<b>\($s): \($n)</b><br><code>\($c)</code>")}' \
  | grafana -X POST "$GRAFANA_URL/api/annotations" --data-binary @- | jq -r '.id')" || ANN_ID=""
[[ -n "$ANN_ID" ]] || echo "WAARSCHUWING: Grafana-annotatie mislukt, benchmark gaat door" >&2

# Metadata vastleggen voor reproduceerbaarheid
{
  echo "# system=$SYSTEM test=$NAME start=$(date -Is) host=$(hostname)"
  echo "# command: $*"
} > "$LOG"

# --- Benchmark ---
echo ">> [$SYSTEM] $NAME  (log: $LOG)"
set +e
"$@" 2>&1 | tee -a "$LOG"
RC="${PIPESTATUS[0]}"
set -e
END_MS="$(date +%s%3N)"
OK=$([[ "$RC" -eq 0 ]] && echo 1 || echo 0)

# --- Annotatie afsluiten (region van start tot eind) ---
if [[ -n "$ANN_ID" ]]; then
  jq -n --argjson t "$START_MS" --argjson te "$END_MS" --arg s "$SYSTEM" --arg n "$NAME" --arg rc "$RC" \
    '{time:$t, timeEnd:$te, tags:["benchmark",$s,$n,("rc="+$rc)]}' \
    | grafana -X PATCH "$GRAFANA_URL/api/annotations/$ANN_ID" --data-binary @- >/dev/null \
    || echo "WAARSCHUWING: annotatie afsluiten mislukt" >&2
fi

# --- Resultaten naar Pushgateway ---
BODY="$(cat <<EOF
# TYPE bench_run_duration_seconds gauge
bench_run_duration_seconds $(( (END_MS - START_MS) / 1000 ))
# TYPE bench_run_success gauge
bench_run_success $OK
# TYPE bench_run_end_timestamp_seconds gauge
bench_run_end_timestamp_seconds $(( END_MS / 1000 ))
EOF
)"

if [[ -n "$FIO_JSON" ]]; then
  if [[ -s "$FIO_JSON" ]]; then
    # Verwacht --group_reporting, zodat jobs[0] het totaal is.
    FIO_METRICS="$(jq -r '
      .jobs[0] as $j
      | ["read","write"][] as $op
      | select(($j[$op].io_bytes // 0) > 0)
      | "bench_fio_bw_bytes{op=\"\($op)\"} \($j[$op].bw_bytes)",
        "bench_fio_iops{op=\"\($op)\"} \($j[$op].iops)",
        ( [["0.5","50.000000"],["0.99","99.000000"],["0.999","99.900000"]][] as $q
          | "bench_fio_clat_seconds{op=\"\($op)\",quantile=\"\($q[0])\"} \((($j[$op].clat_ns.percentile[$q[1]]) // 0) / 1e9)" )
    ' "$FIO_JSON")"
    BODY="$BODY
# TYPE bench_fio_bw_bytes gauge
# TYPE bench_fio_iops gauge
# TYPE bench_fio_clat_seconds gauge
$FIO_METRICS"
  else
    echo "WAARSCHUWING: fio-JSON $FIO_JSON ontbreekt of is leeg" >&2
  fi
fi

printf '%s\n' "$BODY" | curl -fsS -X PUT --data-binary @- \
  "$PUSHGATEWAY_URL/metrics/job/bench/system/$SYSTEM/test/$NAME" \
  || echo "WAARSCHUWING: push naar Pushgateway mislukt" >&2

echo ">> klaar: rc=$RC, duur=$(( (END_MS - START_MS) / 1000 ))s"
exit "$RC"
