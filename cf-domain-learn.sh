#!/bin/sh
set -eu

BASE_DIR="/root/nox-cf-bkk"
DOMAINS_FILE="$BASE_DIR/domains.txt"
CIDRS_FILE="$BASE_DIR/cloudflare-ipv4.txt"
IPS_FILE="$BASE_DIR/selected_ips.txt"
LOG="$BASE_DIR/cf-domain-learn.log"
LOCKDIR=""
ROUTER_DNS="${ROUTER_DNS:-127.0.0.1}"
REBUILD="$BASE_DIR/cf-rebuild-managed.sh"
REFRESH="$BASE_DIR/cf-bkk-refresh.sh"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

cleanup() {
  [ -n "${LOCKDIR:-}" ] && rmdir "$LOCKDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

normalize_domain() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/\.$//'
}

normalize_lock_key() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '_'
}

valid_public_domain() {
  case "$1" in
    ''|localhost|*.lan|*.local|*.arpa) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

ip_in_cidr() {
  ip="$1"
  cidr="$2"
  awk -v ip="$ip" -v cidr="$cidr" '
    function ip2int(s, a) {
      split(s, a, ".")
      return (((a[1] * 256) + a[2]) * 256 + a[3]) * 256 + a[4]
    }
    BEGIN {
      split(cidr, c, "/")
      prefix = c[2] + 0
      hostbits = 32 - prefix
      div = 1
      for (i = 0; i < hostbits; i++) div *= 2
      if (int(ip2int(ip) / div) == int(ip2int(c[1]) / div)) print 1
      else print 0
    }
  '
}

is_cloudflare_ip() {
  ip="$1"
  while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    case "$cidr" in \#*) continue ;; esac
    [ "$(ip_in_cidr "$ip" "$cidr")" = "1" ] && return 0
  done < "$CIDRS_FILE"
  return 1
}

resolve_a_records() {
  nslookup "$1" "$ROUTER_DNS" 2>/dev/null |
    awk '/^Name:[[:space:]]/{seen=1; next} seen && /^Address: /{print $2}' |
    sed 's/:53$//' |
    grep -E '^[0-9]+(\.[0-9]+){3}$' |
    awk '!seen[$0]++'
}

trace_confirms_cf() {
  curl -ksS --connect-timeout 3 --max-time 6 "https://$1/cdn-cgi/trace" 2>/dev/null | grep -q '^colo='
}

domain="$(normalize_domain "${1:-}")"
valid_public_domain "$domain" || exit 0
lock_key="$(normalize_lock_key "$domain")"
LOCKDIR="/tmp/cf-domain-learn.$lock_key.lock"
mkdir "$LOCKDIR" 2>/dev/null || exit 0

[ -s "$CIDRS_FILE" ] || exit 0
[ -f "$DOMAINS_FILE" ] || : > "$DOMAINS_FILE"

grep -Fqx "$domain" "$DOMAINS_FILE" 2>/dev/null && exit 0

found_cf=0
for ip in $(resolve_a_records "$domain" || true); do
  if is_cloudflare_ip "$ip"; then
    found_cf=1
    break
  fi
done
[ "$found_cf" -eq 1 ] || exit 0

trace_confirms_cf "$domain" || exit 0

echo "$domain" >> "$DOMAINS_FILE"
log "learned cloudflare domain: $domain"

if [ -s "$IPS_FILE" ]; then
  "$REBUILD" >/dev/null 2>&1 || true
else
  "$REFRESH" >/dev/null 2>&1 || true
fi
