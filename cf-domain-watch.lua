#!/usr/bin/lua
-- cf-domain-watch.lua —— OpenWrt 上的 CF 域名嗅探 + 学习一体进程
--
--   默认模式 (无参数):
--     procd 启动；嗅探 br-lan 的 LAN DNS 查询，对未学过的域名按
--     6h 节流 + 24h 滑动窗口去重，异步派生自身 --learn 子进程做学习。
--
--   --learn <domain>:
--     一次性学习子进程。本模式由 watcher 自旋启动，也可命令行手工调用。
--     CIDR 双确认 (cloudflare-ipv4.txt + /cdn-cgi/trace)，通过后追加
--     domains.txt 并触发 rebuild 或 refresh。
--
-- 该文件统一了原 cf-domain-watch.sh (旧 shell 嗅探器) 和 cf-domain-learn.sh
-- (shell 学习器) 的全部功能。

local BASE_DIR     = "/root/nox-cf-bkk"
local SCRIPT_PATH  = (arg and arg[0]) or (BASE_DIR .. "/cf-domain-watch.lua")
local LUA_BIN      = os.getenv("LUA_BIN") or "/usr/bin/lua"
local DOMAINS_FILE = BASE_DIR .. "/domains.txt"
local CIDRS_FILE   = BASE_DIR .. "/cloudflare-ipv4.txt"
local IPS_FILE     = BASE_DIR .. "/selected_ips.txt"
local LEARN_LOG    = BASE_DIR .. "/cf-domain-learn.log"
local REBUILD      = BASE_DIR .. "/cf-rebuild-managed.sh"
local REFRESH      = BASE_DIR .. "/cf-bkk-refresh.sh"
local SEEN_FILE    = "/tmp/cf-bkk-seen.tsv"
local ROUTER_DNS   = os.getenv("ROUTER_DNS") or "127.0.0.1"

local THROTTLE_SECONDS  = 21600    -- 6h: 同域名两次学习尝试的最短间隔
local KEEP_SECONDS      = 86400    -- 24h: seen TSV 保留窗口，仍覆盖 6h 节流
local COMPACT_INTERVAL  = 200      -- 累计多少次 mark_seen 后整理 seen 文件

-- ================ 通用工具 ================

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function file_nonempty(path)
  local f = io.open(path, "r")
  if not f then return false end
  local b = f:read(1)
  f:close()
  return b ~= nil
end

local function ensure_file(path)
  if not file_exists(path) then
    local f = assert(io.open(path, "w")); f:close()
  end
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 抹平 Lua 5.1 (返回 exit code) 与 5.3+ (返回 bool, kind, code) 的差异
local function ex(cmd)
  local r = os.execute(cmd)
  if r == nil then return false end
  if type(r) == "boolean" then return r end
  return r == 0
end

local function normalize_domain(s)
  s = (s or ""):lower():gsub("%.$", "")
  return s
end

local function normalize_key(s)
  return normalize_domain(s):gsub("[^a-z0-9%._%-]", "_")
end

local function valid_public_domain(s)
  if s == "" or not s:find("%.") then return false end
  if s == "localhost" then return false end
  if s:match("%.lan$") or s:match("%.local$") or s:match("%.arpa$") then return false end
  return true
end

-- ================ learner 子模块 ================

local function ip_to_int(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end

local function load_cidrs()
  -- 预解析一次：每个 CIDR 缓存 {net_n, div}，比较时只算 floor(ip/div)
  local cidrs = {}
  local f = io.open(CIDRS_FILE, "r")
  if not f then return cidrs end
  for line in f:lines() do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      local net, prefix = line:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
      if net then
        local hostbits = 32 - tonumber(prefix)
        cidrs[#cidrs + 1] = { net_n = ip_to_int(net), div = 2 ^ hostbits }
      end
    end
  end
  f:close()
  return cidrs
end

local function is_cloudflare_ip(ip, cidrs)
  local ip_n = ip_to_int(ip)
  if not ip_n then return false end
  for _, c in ipairs(cidrs) do
    if math.floor(ip_n / c.div) == math.floor(c.net_n / c.div) then
      return true
    end
  end
  return false
end

local function resolve_a_records(domain)
  local cmd = "nslookup " .. shell_quote(domain) .. " " .. shell_quote(ROUTER_DNS) .. " 2>/dev/null"
  local pipe = io.popen(cmd, "r")
  if not pipe then return {} end
  local ips, seen, in_answer = {}, {}, false
  for line in pipe:lines() do
    if line:match("^Name:%s") then
      in_answer = true
    elseif in_answer then
      local addr = line:match("^Address%s*%d*:%s+([%d%.:]+)")
      if addr then
        local clean = addr:gsub(":53$", "")
        if clean:match("^%d+%.%d+%.%d+%.%d+$") and not seen[clean] then
          ips[#ips + 1] = clean
          seen[clean] = true
        end
      end
    end
  end
  pipe:close()
  return ips
end

local function trace_confirms_cf(domain)
  local cmd = "curl -ksS --connect-timeout 3 --max-time 6 "
              .. shell_quote("https://" .. domain .. "/cdn-cgi/trace")
              .. " 2>/dev/null"
  local pipe = io.popen(cmd, "r")
  if not pipe then return false end
  for line in pipe:lines() do
    if line:match("^colo=") then pipe:close(); return true end
  end
  pipe:close()
  return false
end

local function log_learn(msg)
  local f = io.open(LEARN_LOG, "a")
  if not f then return end
  f:write(string.format("[%s] %s\n", os.date("%F %T"), msg))
  f:close()
end

local function domain_known(domain)
  local f = io.open(DOMAINS_FILE, "r")
  if not f then return false end
  for line in f:lines() do
    local d = normalize_domain((line:gsub("^%s+", ""):gsub("%s+$", "")))
    if d == domain then f:close(); return true end
  end
  f:close()
  return false
end

local function append_domain(domain)
  -- io.open(path,"a") 使用 O_APPEND，对 <PIPE_BUF 写入是原子的（不同
  -- learner 子进程并发追加不会撕裂）
  local f = assert(io.open(DOMAINS_FILE, "a"))
  f:write(domain, "\n")
  f:close()
end

local function trigger_rebuild_or_refresh()
  -- selected_ips.txt 存在 → rebuild；缺失 → refresh (refresh 内部 exec rebuild)
  local script = file_nonempty(IPS_FILE) and REBUILD or REFRESH
  ex(script .. " >/dev/null 2>&1 &")
end

local function run_learner(domain)
  domain = normalize_domain(domain)
  if not valid_public_domain(domain) then return end

  -- per-domain 文件锁：避免同时启动两个 learner 学习同一域名
  local lock = "/tmp/cf-domain-learn." .. normalize_key(domain) .. ".lock"
  if not ex("mkdir " .. shell_quote(lock) .. " 2>/dev/null") then return end

  -- 用 pcall 包住主体，任何错误都确保走到 rmdir 释放锁
  pcall(function()
    if not file_exists(CIDRS_FILE) then return end
    ensure_file(DOMAINS_FILE)
    if domain_known(domain) then return end

    local cidrs = load_cidrs()
    if #cidrs == 0 then return end

    local found_cf = false
    for _, ip in ipairs(resolve_a_records(domain)) do
      if is_cloudflare_ip(ip, cidrs) then
        found_cf = true; break
      end
    end
    if not found_cf then return end

    if not trace_confirms_cf(domain) then return end

    append_domain(domain)
    log_learn("learned cloudflare domain: " .. domain)
    trigger_rebuild_or_refresh()
  end)

  ex("rmdir " .. shell_quote(lock) .. " 2>/dev/null")
end

-- ================ watcher 主循环 ================

local function run_watcher()
  local learned, pending, seen = {}, {}, {}
  local last_compact_at, event_count = 0, 0

  local function load_domains()
    learned = {}
    local f = io.open(DOMAINS_FILE, "r")
    if not f then return end
    for line in f:lines() do
      local d = normalize_domain((line:gsub("^%s+", ""):gsub("%s+$", "")))
      if d ~= "" and not d:match("^#") then learned[d] = true end
    end
    f:close()
  end

  local function load_seen()
    seen = {}
    local cutoff = os.time() - KEEP_SECONDS
    local f = io.open(SEEN_FILE, "r")
    if not f then return end
    for line in f:lines() do
      local key, ts = line:match("^([^\t]+)\t(%d+)$")
      ts = tonumber(ts)
      if key and ts and ts >= cutoff then seen[key] = ts end
    end
    f:close()
  end

  local function compact_seen()
    local now = os.time()
    if now - last_compact_at < 60 and event_count < COMPACT_INTERVAL then return end
    local cutoff = now - KEEP_SECONDS
    local tmp = SEEN_FILE .. ".tmp"
    local f = assert(io.open(tmp, "w"))
    for k, ts in pairs(seen) do
      if ts >= cutoff then f:write(k, "\t", tostring(ts), "\n")
      else seen[k] = nil end
    end
    f:close()
    os.rename(tmp, SEEN_FILE)
    last_compact_at = now
    event_count = 0
  end

  local function mark_seen(key, now)
    local had_key = seen[key] ~= nil
    seen[key] = now
    if not had_key then
      local f = assert(io.open(SEEN_FILE, "a"))
      f:write(key, "\t", tostring(now), "\n")
      f:close()
      event_count = event_count + 1
    end
    compact_seen()
  end

  local function spawn_learner(domain)
    -- 自旋启动同一脚本的 --learn 模式；watcher 主循环不阻塞，立即返回
    ex(shell_quote(LUA_BIN) .. " " .. shell_quote(SCRIPT_PATH)
       .. " --learn " .. shell_quote(domain)
       .. " >/dev/null 2>&1 &")
  end

  ensure_file(DOMAINS_FILE)
  ensure_file(SEEN_FILE)
  load_domains()
  load_seen()

  -- -U: 立即模式（关闭 libpcap 的 4KB 包缓冲，DNS 包小、稀流量会被延迟）
  -- -l: stdout 行缓冲（必须配 -U 才能真正"包到即出"）
  local cmd = "tcpdump -Uni br-lan -l 'udp dst port 53' 2>/dev/null"
  local pipe = assert(io.popen(cmd, "r"))

  for line in pipe:lines() do
    local domain = line:match("%sA%?%s+([^%s]+)%.%s+%(") or line:match("%sAAAA%?%s+([^%s]+)%.%s+%(")
    domain = normalize_domain(domain)
    if valid_public_domain(domain) then
      local key = normalize_key(domain)
      local now = os.time()
      local last = seen[key] or 0
      if pending[domain] and now - pending[domain] >= THROTTLE_SECONDS then
        load_domains()
        pending[domain] = nil
      end
      if not learned[domain] and now - last >= THROTTLE_SECONDS then
        -- 乐观标记：避免 learner 子进程跑完前对同一域名重复 spawn；
        -- 即便 learner 最终拒绝该域名，下一次查询会在 seen 节流 6h 后重放
        learned[domain] = true
        pending[domain] = now
        mark_seen(key, now)
        spawn_learner(domain)
      end
    end
  end

  pipe:close()
end

-- ================ 入口 ================

if arg[1] == "--learn" then
  run_learner(arg[2] or "")
else
  run_watcher()
end
