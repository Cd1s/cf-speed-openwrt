#!/bin/sh
set -eu

BASE_DIR="/root/nox-cf-bkk"
SEEN_DIR="/tmp/cf-bkk-seen"
SEEN_FILE="/tmp/cf-bkk-seen.tsv"
TMP_DIR="/tmp/cf-bkk-refresh"
REFRESH_LOG="$BASE_DIR/cf-bkk-refresh.log"
LEARN_LOG="$BASE_DIR/cf-domain-learn.log"
DOMAINS_FILE="$BASE_DIR/domains.txt"
KEEP_LINES=400

mkdir -p "$BASE_DIR" "$TMP_DIR"

trim_log() {
  file="$1"
  [ -f "$file" ] || return 0
  tail -n "$KEEP_LINES" "$file" > "$file.tmp" 2>/dev/null || true
  [ -f "$file.tmp" ] && mv "$file.tmp" "$file"
}

# 兼容旧版本：清掉按文件散存的 seen 目录
rm -rf "$SEEN_DIR" 2>/dev/null || true

# 裁剪 seen TSV，只保留 3 天内的最后一次记录
if [ -f "$SEEN_FILE" ]; then
  now="$(date +%s)"
  cutoff=$((now - 259200))
  awk -F '\t' -v cutoff="$cutoff" 'NF >= 2 && $2 + 0 >= cutoff { seen[$1]=$2 } END { for (k in seen) printf "%s\t%s\n", k, seen[k] }' "$SEEN_FILE" > "$SEEN_FILE.tmp" 2>/dev/null || true
  [ -f "$SEEN_FILE.tmp" ] && mv "$SEEN_FILE.tmp" "$SEEN_FILE"
fi

# 清理刷新过程临时文件
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true

# 去重已学习域名，并清掉 CRLF 行尾（用户手工编辑可能引入 \r）
if [ -f "$DOMAINS_FILE" ]; then
  tr -d '\r' < "$DOMAINS_FILE" \
    | awk 'NF && $1 !~ /^#/ {print tolower($1)}' \
    | awk '!seen[$0]++' > "$DOMAINS_FILE.tmp"
  mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
fi

trim_log "$REFRESH_LOG"
trim_log "$LEARN_LOG"
rm -f /tmp/dnsmasq.log /tmp/dnsmasq-queries.log /tmp/cf-watch-test.log /tmp/cf-learn-debug.out /tmp/cf-bkk-watch.fifo /tmp/cf-bkk-rebuild.dirty 2>/dev/null || true

printf '[%s] cleanup done: %s base, %s seen\n' "$(date '+%F %T')" \
  "$(du -sh "$BASE_DIR" 2>/dev/null | awk '{print $1}')" \
  "$( [ -f "$SEEN_FILE" ] && du -sh "$SEEN_FILE" 2>/dev/null | awk '{print $1}' || echo 0 )"
