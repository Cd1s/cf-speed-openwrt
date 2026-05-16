# cf-speed-openwrt

OpenWrt / ImmortalWrt 上的轻量 Cloudflare BKK 优选方案。

## 功能

- 每天定时从候选 IP 中筛出 20 个可用的 `BKK` Cloudflare IP（**并发测速**，~1 分钟完成 40+ 个 IP）
- 用 `dnsmasq addnhosts` 为已学习的 Cloudflare 域名返回优选 IP
- 监听 LAN 上的 DNS 查询，自动学习新域名（`tcpdump -U` 立即模式，无包缓冲延迟）
- 仅在内容实际变化时才重建 hosts，并通过 `dnsmasq reload`（SIGHUP）热加载，不中断 LAN DNS
- 按域名加锁，避免并发学习时互相吞任务
- rebuild / refresh 通过 `flock` 单实例化，避免并发覆盖与重复热加载
- rebuild 采用 **trigger-coalesce**：高频学习期被 skip 的更新会被合并到下一轮，**不丢失**
- managed hosts 文件使用**紧凑布局**（每 IP 一行多 hostname），文件体积、dnsmasq 解析时间显著下降

## 文件

- `cf-bkk-refresh.sh`：每日并发测速刷新优选 IP（PARALLEL=8）
- `cf-rebuild-managed.sh`：根据 `domains.txt` + `selected_ips.txt` 紧凑布局重建 dnsmasq hosts（trigger-coalesce + flock）
- `cf-domain-watch.lua`：单文件双模式
  - 默认（procd 启动）：嗅探 LAN DNS 查询，节流去重，自旋启动 `--learn` 子进程
  - `--learn <domain>`：一次性学习子进程，CIDR + `/cdn-cgi/trace` 双确认，命中后追加 domains.txt 并触发 rebuild/refresh
- `cf-maintenance.sh`：裁剪日志、去重域名、规范化 CRLF、清理临时文件
- `nox-cf-learner.init`：procd 服务脚本
- `cloudflare-ipv4.txt.example`：Cloudflare IPv4 网段示例
- `candidates.txt.example`：候选 IP 列表示例

## 目录约定

默认部署目录：

```sh
/root/nox-cf-bkk
```

运行时文件：

- `/root/nox-cf-bkk/domains.txt`
- `/root/nox-cf-bkk/selected_ips.txt`
- `/root/nox-cf-bkk/cf-bkk-refresh.log`
- `/root/nox-cf-bkk/cf-domain-learn.log`
- `/etc/dnsmasq.d/cf-bkk-managed.hosts`

## 安装

1. 安装依赖：`curl`、`dnsmasq-full`（或支持 `addnhosts` 的 dnsmasq）、`tcpdump`、`lua`
2. 创建目录：

```sh
mkdir -p /root/nox-cf-bkk /etc/dnsmasq.d
```

3. 上传脚本到 `/root/nox-cf-bkk/`
4. 准备：
   - `candidates.txt`
   - `cloudflare-ipv4.txt`
   - 空的 `domains.txt`（可选，脚本会自动创建）
5. 确保 dnsmasq 加载 managed hosts 文件：

```sh
uci add_list dhcp.@dnsmasq[0].addnhosts='/etc/dnsmasq.d/cf-bkk-managed.hosts'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

> ⚠️ **不要省略这一步**。OpenWrt / ImmortalWrt 默认把 `/etc/dnsmasq.d/` 作为
> `conf-dir` 加载（解析为 dnsmasq 配置语法），而 hosts 文件 `<ip> <domain>`
> 不是合法的 dnsmasq 配置语法 —— 没有 `addnhosts` 声明的话，文件不仅不会生效，
> 还可能导致 dnsmasq 启动失败。可以在另一个目录（如 `/etc/cf-bkk/`）
> 放置 hosts 文件以规避，但需要相应改 `cf-rebuild-managed.sh` 里的 `MANAGED` 路径。

6. 安装 watcher 服务：

```sh
cp nox-cf-learner.init /etc/init.d/nox-cf-learner
chmod +x /etc/init.d/nox-cf-learner
/etc/init.d/nox-cf-learner enable
/etc/init.d/nox-cf-learner start
```

7. 添加 cron：

```cron
0 8 * * * /root/nox-cf-bkk/cf-bkk-refresh.sh >/dev/null 2>&1
17 3 * * * /root/nox-cf-bkk/cf-maintenance.sh >/dev/null 2>&1
```

## 配置

### learner DNS 目标

`cf-domain-watch.lua --learn` 默认通过本机 dnsmasq 做正向解析：

```lua
ROUTER_DNS = os.getenv("ROUTER_DNS") or "127.0.0.1"
```

如需指定其他 DNS，可在 procd 服务里加环境变量，或手工调用时 export：

```sh
export ROUTER_DNS=192.168.1.1
lua /root/nox-cf-bkk/cf-domain-watch.lua --learn example.com
```

### 手动学习单个域名

```sh
lua /root/nox-cf-bkk/cf-domain-watch.lua --learn example.com
```

## 脱敏说明

仓库不包含：

- 私有域名列表
- 实际学习得到的 `domains.txt`
- 实际测速结果 / 日志
- 设备或家庭局域网凭据

示例文件只提供格式，不提供你的真实数据。

## 备注

当前实现默认以 `BKK` 为目标 colo。若要适配其他地区，可修改 `cf-bkk-refresh.sh` 中的 colo 判定逻辑。
