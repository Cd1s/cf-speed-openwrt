#!/bin/sh
set -eu

BASE_DIR="/root/nox-cf-bkk"
DOMAINS_FILE="$BASE_DIR/domains.txt"
IPS_FILE="$BASE_DIR/selected_ips.txt"
MANAGED="/etc/dnsmasq.d/cf-bkk-managed.hosts"
LOG="$BASE_DIR/cf-bkk-refresh.log"
TMP_DIR="/tmp/cf-bkk-rebuild"
LOCK_FILE="/tmp/cf-bkk-rebuild.lock"
DIRTY_FLAG="/tmp/cf-bkk-rebuild.dirty"
HOSTS_PER_LINE=15
HOSTS_LINE_MAX=900

mkdir -p "$BASE_DIR" /etc/dnsmasq.d "$TMP_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2
}

cleanup_tmp() {
  rm -f "$TMP_DIR/cf-bkk-managed.body" \
        "$TMP_DIR/cf-bkk-managed.current.body" \
        "$TMP_DIR/cf-bkk-managed.hosts.new" \
        "$TMP_DIR/domains.txt" \
        "$TMP_DIR/ips.txt" 2>/dev/null || true
}

# 单实例锁 + dirty 标志（trigger-coalesce）：
#  - 并发触发时只有 1 个进程进入主体，其他写 dirty 后退出
#  - 主体跑完看到 dirty 时原地再跑一轮（吸收并发触发期间发生的更新）
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  : > "$DIRTY_FLAG"
  log "rebuild already running, marked dirty"
  exit 0
fi

# 必须在拿到锁之后再注册 cleanup_tmp：marked-dirty 分支退出时绝不能去删
# 锁持有者正在使用的 tmp 文件（race 实测可复现）
trap cleanup_tmp EXIT

if [ ! -s "$DOMAINS_FILE" ]; then
  log "domains file missing or empty: $DOMAINS_FILE"
  exit 1
fi

if [ ! -s "$IPS_FILE" ]; then
  log "selected IP file missing or empty: $IPS_FILE"
  exit 1
fi

# trigger-coalesce 主循环：进入主体前清 dirty；主体跑完看到 dirty 就再跑一轮。
# 用 while-loop 而不是 exec "$0" 重启，避免 re-exec 与 trap EXIT 的 race。
while :; do
  rm -f "$DIRTY_FLAG"

  awk 'NF && $1 !~ /^#/ {print tolower($1)}' "$DOMAINS_FILE" | awk '!seen[$0]++' > "$TMP_DIR/domains.txt"
  awk 'NF && $1 !~ /^#/ {print $1}' "$IPS_FILE" | awk '!seen[$0]++' > "$TMP_DIR/ips.txt"

  if [ ! -s "$TMP_DIR/domains.txt" ]; then
    log "domains file has no usable domains: $DOMAINS_FILE"
    exit 1
  fi

  if [ ! -s "$TMP_DIR/ips.txt" ]; then
    log "selected IP file has no usable IPs: $IPS_FILE"
    exit 1
  fi

  # 分块紧凑布局：每行 "IP domain1 ... domainN"。
  # dnsmasq 把每行 IP+多 hostname 视为多个 (host,ip) 映射，行为与展开版一致；
  # 同时限制 hostname 数和字符长度，避免行尾域名不被 dnsmasq 采用。
  awk '
    NR == FNR {
      domains[++dc] = $0
      next
    }
    NF {
      ip = $0
      line = ip
      count = 0
      for (i = 1; i <= dc; i++) {
        add = " " domains[i]
        if (count > 0 && (count >= maxhosts || length(line) + length(add) > maxlen)) {
          print line
          line = ip
          count = 0
        }
        line = line add
        count++
      }
      if (count > 0) {
        print line
      }
    }
  ' maxhosts="$HOSTS_PER_LINE" maxlen="$HOSTS_LINE_MAX" "$TMP_DIR/domains.txt" "$TMP_DIR/ips.txt" > "$TMP_DIR/cf-bkk-managed.body"

  if [ -f "$MANAGED" ]; then
    sed '1,2d' "$MANAGED" > "$TMP_DIR/cf-bkk-managed.current.body"
    if cmp -s "$TMP_DIR/cf-bkk-managed.body" "$TMP_DIR/cf-bkk-managed.current.body"; then
      if [ -f "$DIRTY_FLAG" ]; then
        log "managed hosts unchanged but dirty flag set, running follow-up"
        continue
      fi
      log "managed hosts unchanged"
      # 已是最新状态：消化 dirty 也不需要再跑（数据没有变化）
      rm -f "$DIRTY_FLAG"
      exit 0
    fi
  fi

  {
    echo "# Managed by Nox CF BKK rebuild"
    echo "# Updated: $(date '+%F %T %Z')"
    cat "$TMP_DIR/cf-bkk-managed.body"
  } > "$TMP_DIR/cf-bkk-managed.hosts.new"

  # OpenWrt may run dnsmasq inside ujail with this file bind-mounted; replacing
  # the inode with mv can leave dnsmasq reloading an old view. Overwrite in place.
  cat "$TMP_DIR/cf-bkk-managed.hosts.new" > "$MANAGED"
  rm -f "$TMP_DIR/cf-bkk-managed.hosts.new"

  # reload (SIGHUP) 重读 addn-hosts、清 cache，不重启进程
  if /etc/init.d/dnsmasq reload >/dev/null 2>&1; then
    domains_count="$(wc -l < "$TMP_DIR/domains.txt" | tr -d ' ')"
    ips_count="$(wc -l < "$TMP_DIR/ips.txt" | tr -d ' ')"
    bytes="$(wc -c < "$MANAGED" | tr -d ' ')"
    log "rebuilt $MANAGED for $domains_count domains x $ips_count BKK IPs ($bytes B)"
  else
    log "dnsmasq reload failed after rebuild"
    exit 1
  fi

  # 主体跑完后检查 dirty：期间被并发触发过 → 再跑一轮
  if [ -f "$DIRTY_FLAG" ]; then
    log "dirty flag set during rebuild, running follow-up"
    continue
  fi
  break
done
