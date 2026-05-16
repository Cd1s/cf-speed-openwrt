# cf-speed-openwrt

OpenWrt / ImmortalWrt 上的轻量 Cloudflare BKK 优选方案。

## 功能

- 每天定时从候选 IP 中筛出 20 个可用的 `BKK` Cloudflare IP
- 用 `dnsmasq addnhosts` 为已学习的 Cloudflare 域名返回优选 IP
- 监听 LAN 上的 DNS 查询，自动学习新域名
- 仅在内容实际变化时才重建 hosts 并重启 `dnsmasq`
- 按域名加锁，避免并发学习时互相吞任务

## 文件

- `cf-bkk-refresh.sh`：每日测速刷新优选 IP
- `cf-rebuild-managed.sh`：根据 `domains.txt` + `selected_ips.txt` 重建 dnsmasq hosts
- `cf-domain-learn.sh`：验证域名是否经 Cloudflare，加入学习列表
- `cf-domain-watch.lua`：监听 DNS 查询并异步触发学习
- `cf-maintenance.sh`：裁剪日志、去重域名、清理临时文件
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
5. 确保 dnsmasq 加载：

```sh
uci add_list dhcp.@dnsmasq[0].addnhosts='/etc/dnsmasq.d/cf-bkk-managed.hosts'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

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

`cf-domain-learn.sh` 默认用本机 DNS：

```sh
ROUTER_DNS=${ROUTER_DNS:-127.0.0.1}
```

如需指定其他 DNS，可在运行前导出环境变量：

```sh
export ROUTER_DNS=192.168.1.1
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
