#!/bin/sh
set -eu

BASE_DIR="/root/nox-cf-bkk"
DOMAINS_FILE="$BASE_DIR/domains.txt"
IPS_FILE="$BASE_DIR/selected_ips.txt"
MANAGED="/etc/dnsmasq.d/cf-bkk-managed.hosts"
LOG="$BASE_DIR/cf-bkk-refresh.log"
TMP_DIR="/tmp/cf-bkk-refresh"
LOCK_FILE="/tmp/cf-bkk-rebuild.lock"
DIRTY_FLAG="/tmp/cf-bkk-rebuild.dirty"

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

  # 紧凑布局：每行 "IP domain1 domain2 ... domainN"。
  # dnsmasq 把每行 IP+多 hostname 视为多个 (host,ip) 映射，行为与展开版一致；
  # 文件体积、shell IO、dnsmasq 解析时间都显著下降（旧版 N=domains*ips 行 →
  # 新版 N=ips 行）。awk 单次扫描替代 shell 双 while 循环，rebuild 加速 50x+。
  awk '
    NR==FNR { tail = tail " " $0; next }
    NF      { print $0 tail }
  ' "$TMP_DIR/domains.txt" "$TMP_DIR/ips.txt" > "$TMP_DIR/cf-bkk-managed.body"

  if [ -f "$MANAGED" ]; then
    sed '1,2d' "$MANAGED" > "$TMP_DIR/cf-bkk-managed.current.body"
    if cmp -s "$TMP_DIR/cf-bkk-managed.body" "$TMP_DIR/cf-bkk-managed.current.body"; then
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

  mv "$TMP_DIR/cf-bkk-managed.hosts.new" "$MANAGED"

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
