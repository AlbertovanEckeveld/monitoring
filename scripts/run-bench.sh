#!/usr/bin/env bash
# Draai een benchmark-commando met annotatie in Grafana en resultaten in de Pushgateway.
# Draait op de load-generator = de monitoring-VM (Linux, GNU date). Vereist: curl, jq.
#
# Gebruik:
#   run-bench.sh <system> <testnaam> [--rep N] [--warmup SEC] [--fio-json <bestand>] -- <commando...>
#
#   --rep N        herhalingsnummer (standaard 1). Elke herhaling blijft apart bewaard; het
#                  vergelijkingsdashboard toont mediaan, min en max over de herhalingen (§7.8).
#   --warmup SEC   eerste SEC seconden niet meetellen in de serversamenvatting (standaard 60;
#                  0 als de run korter is dan warmup + 30 s)
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
#   PROMETHEUS_URL   standaard http://localhost:9090 (voor de serversamenvatting)
#   RESULTS_DIR      standaard ./results
#   (GRAFANA_* en PUSHGATEWAY_URL worden uit ../bench.env gelezen als die bestaat)

set -euo pipefail

# bench.env (gemaakt door setup-monitoring-vm.sh) automatisch inlezen, als die er is
BENCH_ENV="$(cd "$(dirname "$0")/.." && pwd)/bench.env"
if [[ -f "$BENCH_ENV" ]]; then set -a; . "$BENCH_ENV"; set +a; fi

usage() { sed -n '2,33p' "$0"; exit 1; }
[[ $# -ge 3 ]] || usage

SYSTEM="$1"; NAME="$2"; shift 2
FIO_JSON="" REP=1 WARMUP=60
while [[ $# -gt 0 && "$1" != "--" ]]; do
  case "$1" in
    --fio-json) FIO_JSON="$2"; shift 2 ;;
    --rep)      REP="$2"; shift 2 ;;
    --warmup)   WARMUP="$2"; shift 2 ;;
    *) echo "Onbekende optie: $1" >&2; usage ;;
  esac
done
[[ "${1:-}" == "--" ]] || usage
shift

[[ "$SYSTEM" =~ ^(ceph|seaweedfs)$ ]] || { echo "system moet ceph of seaweedfs zijn" >&2; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]    || { echo "testnaam: alleen letters, cijfers, . _ -" >&2; exit 1; }
[[ "$REP" =~ ^[0-9]+$ && "$WARMUP" =~ ^[0-9]+$ ]] || { echo "--rep en --warmup moeten getallen zijn" >&2; exit 1; }
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
: "${GRAFANA_URL:?}" "${GRAFANA_TOKEN:?}" "${PUSHGATEWAY_URL:?}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
mkdir -p "$RESULTS_DIR"

STAMP="$(date +%Y%m%dT%H%M%S)"
LOG="$RESULTS_DIR/${STAMP}_${SYSTEM}_${NAME}_r${REP}.log"
SUMMARY="${LOG%.log}_server.json"

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
  echo "# system=$SYSTEM test=$NAME rep=$REP start=$(date -Is) host=$(hostname)"
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

# --- Serversamenvatting: gemiddelden over het meetvenster, uit Prometheus ---
# Gebruikt de recording rules uit prometheus/rules/compare.yml. Verhoudingen worden
# berekend als verhouding van gemiddelden (niet als gemiddelde van verhoudingen).
END_S=$(( END_MS / 1000 )) DUR_S=$(( (END_MS - START_MS) / 1000 ))
(( DUR_S < WARMUP + 30 )) && WARMUP=0
WIN=$(( DUR_S - WARMUP ))
SRV_METRICS=""
if (( WIN >= 10 )); then
  sleep 10   # laatste scrape en rule-evaluatie afwachten
  avg() { echo "avg_over_time(${1}[${WIN}s] @ ${END_S})"; }
  S="system=\"$SYSTEM\"" L="system=\"loadgen\""
  # metric{labels}|PromQL
  QUERIES=$(cat <<EOF
bench_srv_requests_per_second|$(avg "system:s3_requests:rate30s{$S}")
bench_srv_errors_per_second|$(avg "system:s3_errors:rate30s{$S}")
bench_srv_requests_by_op_per_second{op="GET"}|$(avg "system:s3_requests_by_op:rate30s{$S,op=\"GET\"}")
bench_srv_requests_by_op_per_second{op="PUT"}|$(avg "system:s3_requests_by_op:rate30s{$S,op=\"PUT\"}")
bench_srv_requests_by_op_per_second{op="DELETE"}|$(avg "system:s3_requests_by_op:rate30s{$S,op=\"DELETE\"}")
bench_srv_requests_by_op_per_second{op="LIST"}|$(avg "system:s3_requests_by_op:rate30s{$S,op=\"LIST\"}")
bench_srv_latency_avg_seconds{op="GET"}|$(avg "system:s3_latency_avg_seconds{$S,op=\"GET\"}")
bench_srv_latency_avg_seconds{op="PUT"}|$(avg "system:s3_latency_avg_seconds{$S,op=\"PUT\"}")
bench_srv_latency_avg_seconds{op="DELETE"}|$(avg "system:s3_latency_avg_seconds{$S,op=\"DELETE\"}")
bench_srv_latency_avg_seconds{op="LIST"}|$(avg "system:s3_latency_avg_seconds{$S,op=\"LIST\"}")
bench_srv_s3_bytes_per_second{direction="in"}|$(avg "system:s3_bytes:rate30s{$S,direction=\"in\"}")
bench_srv_s3_bytes_per_second{direction="out"}|$(avg "system:s3_bytes:rate30s{$S,direction=\"out\"}")
bench_srv_cpu_cores_used|$(avg "system:node_cpu_cores_used:sum{$S}")
bench_srv_cpu_utilisation|$(avg "system:node_cpu_utilisation:avg{$S}")
bench_srv_cpu_iowait|$(avg "system:node_cpu_iowait:avg{$S}")
bench_srv_memory_used_bytes|$(avg "system:node_memory_used_bytes:sum{$S}")
bench_srv_disk_write_bytes_per_second|$(avg "system:node_disk_written_bytes:rate30s{$S}")
bench_srv_disk_read_bytes_per_second|$(avg "system:node_disk_read_bytes:rate30s{$S}")
bench_srv_disk_io_utilisation_max|max_over_time(system:node_disk_io_utilisation:max{$S}[${WIN}s] @ ${END_S})
bench_srv_network_tx_bytes_per_second|$(avg "system:node_network_transmit_bytes:rate30s{$S}")
bench_srv_cpu_cores_per_1k_rps|$(avg "system:node_cpu_cores_used:sum{$S}") / ($(avg "system:s3_requests:rate30s{$S}") > 1) * 1000
bench_srv_memory_gib_per_1k_rps|$(avg "system:node_memory_used_bytes:sum{$S}") / 2^30 / ($(avg "system:s3_requests:rate30s{$S}") > 1) * 1000
bench_srv_write_amplification|$(avg "system:node_disk_written_bytes:rate30s{$S}") / on(system) ($(avg "system:s3_bytes:rate30s{$S,direction=\"in\"}") > 1e5)
bench_srv_error_ratio|$(avg "system:s3_errors:rate30s{$S}") / ($(avg "system:s3_requests:rate30s{$S}") > 0)
bench_loadgen_cpu_utilisation|$(avg "system:node_cpu_utilisation:avg{$L}")
bench_loadgen_cpu_utilisation_max|max_over_time(system:node_cpu_utilisation:avg{$L}[${WIN}s] @ ${END_S})
bench_loadgen_network_bytes_per_second|$(avg "system:node_network_transmit_bytes:rate30s{$L}") + on() $(avg "system:node_network_receive_bytes:rate30s{$L}")
EOF
)
  declare -A SEEN=()
  echo "{" > "$SUMMARY.tmp"; FIRST=1
  while IFS='|' read -r metric expr; do
    val=$(curl -fsS --max-time 10 "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$expr" \
          | jq -r '.data.result[0].value[1] // empty' 2>/dev/null) || val=""
    [[ -z "$val" || "$val" == "NaN" ]] && continue
    base="${metric%%\{*}"
    [[ -n "${SEEN[$base]:-}" ]] || { SRV_METRICS+="# TYPE $base gauge"$'\n'; SEEN[$base]=1; }
    SRV_METRICS+="$metric $val"$'\n'
    (( FIRST )) || echo "," >> "$SUMMARY.tmp"; FIRST=0
    printf '  %s: %s' "$(jq -Rn --arg m "$metric" '$m')" "$val" >> "$SUMMARY.tmp"
  done <<<"$QUERIES"
  printf '\n}\n' >> "$SUMMARY.tmp" && mv "$SUMMARY.tmp" "$SUMMARY"
  echo ">> serversamenvatting (venster ${WIN}s, warmup ${WARMUP}s): $SUMMARY"
  LG=$(jq -r '."bench_loadgen_cpu_utilisation_max" // 0' "$SUMMARY")
  if awk -v v="$LG" 'BEGIN{exit !(v > 0.9)}'; then
    echo "WAARSCHUWING: loadgen-CPU piekte op $(awk -v v="$LG" 'BEGIN{printf "%.0f", v*100}')%: deze run meet mogelijk de loadgenerator (§7.8)" >&2
  fi
else
  echo "WAARSCHUWING: run te kort (${DUR_S}s) voor een serversamenvatting" >&2
fi

# --- Resultaten naar Pushgateway ---
SRV_METRICS="${SRV_METRICS%$'\n'}"
BODY="$(cat <<EOF
# TYPE bench_run_duration_seconds gauge
bench_run_duration_seconds $(( (END_MS - START_MS) / 1000 ))
# TYPE bench_run_success gauge
bench_run_success $OK
# TYPE bench_run_end_timestamp_seconds gauge
bench_run_end_timestamp_seconds $(( END_MS / 1000 ))
# TYPE bench_run_start_timestamp_seconds gauge
bench_run_start_timestamp_seconds $(( START_MS / 1000 ))
# TYPE bench_run_warmup_seconds gauge
bench_run_warmup_seconds $WARMUP
${SRV_METRICS}
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
  "$PUSHGATEWAY_URL/metrics/job/bench/system/$SYSTEM/test/$NAME/rep/$REP" \
  || echo "WAARSCHUWING: push naar Pushgateway mislukt" >&2

echo ">> klaar: rc=$RC, duur=$(( (END_MS - START_MS) / 1000 ))s"
exit "$RC"
