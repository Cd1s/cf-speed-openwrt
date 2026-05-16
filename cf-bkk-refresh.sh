#!/bin/sh
set -eu

BASE_DIR="/root/nox-cf-bkk"
CANDIDATES="$BASE_DIR/candidates.txt"
DOMAINS_FILE="$BASE_DIR/domains.txt"
IPS_FILE="$BASE_DIR/selected_ips.txt"
LOG="$BASE_DIR/cf-bkk-refresh.log"
TMP_DIR="/tmp/cf-bkk-refresh"
LOCK_FILE="/tmp/cf-bkk-refresh.lock"
TARGET_COUNT=20
MIN_COUNT=5
MIN_SPEED=102400          # 字节/秒；低于此速的 IP 即便着陆 BKK 也不选
PARALLEL=8                 # 并发测速线程数
TRACE_PATH="/cdn-cgi/trace"
DOWN_PATH="/__down?bytes=1000000"
HOST_HEADER="Host: speed.cloudflare.com"
REBUILD="$BASE_DIR/cf-rebuild-managed.sh"

mkdir -p "$BASE_DIR" "$TMP_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2
}

shuffle_file() {
  # 过滤空行和 # 注释
  awk 'BEGIN{srand()} NF && $1 !~ /^#/ {print rand(), $1}' "$1" | sort -k1,1n | cut -d' ' -f2-
}

# 测一个 IP；输出 "ip speed ttfb conn total" 到 stdout
test_one_ip() {
  ip="$1"
  trace="$(curl -fsS --connect-timeout 2 --max-time 4 -H "$HOST_HEADER" "http://$ip$TRACE_PATH" 2>/dev/null || true)"
  colo="$(printf '%s\n' "$trace" | sed -n 's/^colo=//p' | head -n1)"
  [ "$colo" = "BKK" ] || return 0

  metrics="$(curl -fsS --connect-timeout 2 --max-time 8 -H "$HOST_HEADER" -o /dev/null \
             -w '%{http_code} %{time_connect} %{time_starttransfer} %{time_total} %{speed_download}\n' \
             "http://$ip$DOWN_PATH" 2>/dev/null || true)"
  set -- $metrics
  code="${1:-0}"
  conn="${2:-9}"
  ttfb="${3:-9}"
  total="${4:-9}"
  speed="${5:-0}"
  [ "$code" = "200" ] || return 0

  # 速度门槛（速度 < MIN_SPEED 的 IP 即便着陆 BKK 也不选）
  awk -v s="$speed" -v m="$MIN_SPEED" 'BEGIN{exit !(s+0 >= m+0)}' || return 0

  # POSIX: <PIPE_BUF (512) 的 write() 是原子的，并发 >> 不会撕裂
  printf '%s %s %s %s %s\n' "$ip" "$speed" "$ttfb" "$conn" "$total"
}

# 单实例锁：cron 与 learner 都可能触发
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "refresh already running, skip"
  exit 0
fi

rm -f "$TMP_DIR"/*

if [ ! -s "$CANDIDATES" ]; then
  log "candidate file missing: $CANDIDATES"
  exit 1
fi

shuffle_file "$CANDIDATES" > "$TMP_DIR/candidates.shuffled"
: > "$TMP_DIR/results.txt"

# 并发测速：每批 PARALLEL 个，写入结果到同一文件（行级原子）
N=0
while IFS= read -r ip; do
  [ -n "$ip" ] || continue
  case "$ip" in
    *.*.*.*) ;;
    *) continue ;;
  esac
  ( test_one_ip "$ip" >> "$TMP_DIR/results.txt" ) &
  N=$((N+1))
  if [ "$N" -ge "$PARALLEL" ]; then
    wait
    N=0
  fi
done < "$TMP_DIR/candidates.shuffled"
wait

if [ ! -s "$TMP_DIR/results.txt" ]; then
  log "no BKK candidates survived testing; keeping existing file"
  exit 1
fi

sort -k2,2nr -k3,3n -k4,4n "$TMP_DIR/results.txt" | head -n "$TARGET_COUNT" > "$TMP_DIR/top-ranked.txt"
count="$(wc -l < "$TMP_DIR/top-ranked.txt" | tr -d ' ')"
if [ "$count" -lt "$MIN_COUNT" ]; then
  log "only $count usable BKK IPs (<$MIN_COUNT); keeping existing file"
  exit 1
fi

awk '{print $1}' "$TMP_DIR/top-ranked.txt" > "$IPS_FILE"
log "selected $count BKK IPs"
exec "$REBUILD"
