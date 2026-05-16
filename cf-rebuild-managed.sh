#!/bin/sh
set -eu

BASE_DIR="/root/nox-cf-bkk"
DOMAINS_FILE="$BASE_DIR/domains.txt"
IPS_FILE="$BASE_DIR/selected_ips.txt"
MANAGED="/etc/dnsmasq.d/cf-bkk-managed.hosts"
LOG="$BASE_DIR/cf-bkk-refresh.log"
TMP_DIR="/tmp/cf-bkk-refresh"

mkdir -p "$BASE_DIR" /etc/dnsmasq.d "$TMP_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2
}

if [ ! -s "$DOMAINS_FILE" ]; then
  log "domains file missing or empty: $DOMAINS_FILE"
  exit 1
fi

if [ ! -s "$IPS_FILE" ]; then
  log "selected IP file missing or empty: $IPS_FILE"
  exit 1
fi

awk 'NF && $1 !~ /^#/ {print tolower($1)}' "$DOMAINS_FILE" | awk '!seen[$0]++' > "$TMP_DIR/domains.txt"
awk 'NF && $1 !~ /^#/ {print $1}' "$IPS_FILE" | awk '!seen[$0]++' > "$TMP_DIR/ips.txt"

{
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      printf '%s %s\n' "$ip" "$domain"
    done < "$TMP_DIR/domains.txt"
  done < "$TMP_DIR/ips.txt"
} > "$TMP_DIR/cf-bkk-managed.body"

if [ -f "$MANAGED" ]; then
  sed '1,2d' "$MANAGED" > "$TMP_DIR/cf-bkk-managed.current.body"
  if cmp -s "$TMP_DIR/cf-bkk-managed.body" "$TMP_DIR/cf-bkk-managed.current.body"; then
    rm -f "$TMP_DIR/cf-bkk-managed.body" "$TMP_DIR/cf-bkk-managed.current.body"
    log "managed hosts unchanged"
    exit 0
  fi
fi

{
  echo "# Managed by Nox CF BKK rebuild"
  echo "# Updated: $(date '+%F %T %Z')"
  cat "$TMP_DIR/cf-bkk-managed.body"
} > "$TMP_DIR/cf-bkk-managed.hosts.new"

[ -f "$MANAGED" ] && cp "$MANAGED" "$MANAGED.bak"
mv "$TMP_DIR/cf-bkk-managed.hosts.new" "$MANAGED"

if /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
  domains_count="$(wc -l < "$TMP_DIR/domains.txt" | tr -d ' ')"
  ips_count="$(wc -l < "$TMP_DIR/ips.txt" | tr -d ' ')"
  log "rebuilt $MANAGED for $domains_count domains x $ips_count BKK IPs"
else
  log "dnsmasq restart failed after rebuild"
  exit 1
fi
