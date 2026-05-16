local BASE_DIR = "/root/nox-cf-bkk"
local LEARNER = BASE_DIR .. "/cf-domain-learn.sh"
local DOMAINS_FILE = BASE_DIR .. "/domains.txt"
local SEEN_FILE = "/tmp/cf-bkk-seen.tsv"
local THROTTLE_SECONDS = 21600
local KEEP_SECONDS = 259200
local COMPACT_INTERVAL = 200

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function ensure_file(path)
  if not file_exists(path) then
    local f = assert(io.open(path, "w"))
    f:close()
  end
end

local function normalize_domain(s)
  s = (s or ""):lower():gsub("%.$", "")
  return s
end

local function normalize_key(s)
  s = normalize_domain(s):gsub("[^a-z0-9%._%-]", "_")
  return s
end

local function valid_public_domain(s)
  if s == "" or not s:find("%.") then return false end
  if s == "localhost" then return false end
  if s:match("%.lan$") or s:match("%.local$") or s:match("%.arpa$") then return false end
  return true
end

local learned = {}
local seen = {}
local last_compact_at = 0
local event_count = 0

local function load_domains()
  learned = {}
  local f = io.open(DOMAINS_FILE, "r")
  if not f then return end
  for line in f:lines() do
    local d = normalize_domain((line:gsub("^%s+", ""):gsub("%s+$", "")))
    if d ~= "" and not d:match("^#") then
      learned[d] = true
    end
  end
  f:close()
end

local function load_seen()
  seen = {}
  local now = os.time()
  local cutoff = now - KEEP_SECONDS
  local f = io.open(SEEN_FILE, "r")
  if not f then return end
  for line in f:lines() do
    local key, ts = line:match("^([^\t]+)\t(%d+)$")
    ts = tonumber(ts)
    if key and ts and ts >= cutoff then
      seen[key] = ts
    end
  end
  f:close()
end

local function compact_seen()
  local now = os.time()
  if now - last_compact_at < 60 and event_count < COMPACT_INTERVAL then
    return
  end
  local cutoff = now - KEEP_SECONDS
  local tmp = SEEN_FILE .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  for key, ts in pairs(seen) do
    if ts >= cutoff then
      f:write(key, "\t", tostring(ts), "\n")
    else
      seen[key] = nil
    end
  end
  f:close()
  os.rename(tmp, SEEN_FILE)
  last_compact_at = now
  event_count = 0
end

local function mark_seen(key, now)
  seen[key] = now
  local f = assert(io.open(SEEN_FILE, "a"))
  f:write(key, "\t", tostring(now), "\n")
  f:close()
  event_count = event_count + 1
  compact_seen()
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function spawn_learner(domain)
  os.execute(LEARNER .. " " .. shell_quote(domain) .. " >/dev/null 2>&1 &")
end

ensure_file(DOMAINS_FILE)
ensure_file(SEEN_FILE)
load_domains()
load_seen()

-- -U (immediate mode) 关闭 libpcap 的 4KB 内部缓冲：DNS 包小 (~70B)，无 -U 时
-- 低流量场景需要积累 ~60 个包才 flush，学习器可能延迟数分钟才被触发。
-- -l 是 stdout 行缓冲，与 -U (包级 flush) 配合才能让单个 DNS 查询立刻可见。
local cmd = "tcpdump -Uni br-lan -l 'udp dst port 53' 2>/dev/null"
local pipe = assert(io.popen(cmd, "r"))

for line in pipe:lines() do
  local domain = line:match("%sA%?%s+([^%s]+)%.%s+%(") or line:match("%sAAAA%?%s+([^%s]+)%.%s+%(")
  domain = normalize_domain(domain)
  if valid_public_domain(domain) then
    if not learned[domain] then
      local key = normalize_key(domain)
      local now = os.time()
      local last = seen[key] or 0
      if now - last >= THROTTLE_SECONDS then
        -- 乐观标记，避免 learner 异步跑完前对同一域名重复 spawn；
        -- 即使 learner 最终拒绝该域名，seen 节流（默认 6h）会兜底，
        -- 6h 后过期，由 throttle 重新放行尝试。
        learned[domain] = true
        mark_seen(key, now)
        spawn_learner(domain)
      end
    end
  end
end

pipe:close()
