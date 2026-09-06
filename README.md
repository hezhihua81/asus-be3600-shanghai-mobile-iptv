# ASUS TUF-BE3600 A1 上海移动 IPTV 单线复用

在 ASUS TUF Gaming BE3600 A1 原厂固件上，为上海移动魔百盒保留 LAN4 普通家庭网络的同时，透传 IPTV VLAN，实现一根网线提供 A/B 两个逻辑网络，并在重启后恢复运行时配置。

> 这是特定环境中已验证的运行时恢复方案，不是从零开始的一键安装器。必须先手工验证 IPTV 已正常播放，再执行 `install`。

## 已验证环境

| 项目 | 实测值 |
| --- | --- |
| 路由器 | ASUS TUF Gaming BE3600 A1 |
| 固件 | ASUS 原厂固件（3.0.0.6.102 系列） |
| 运营商 | 上海移动 |
| Internet | PPPoE，VLAN 1101（`vlan1101@eth0`） |
| IPTV | VLAN 1103 |
| 机顶盒端口 | LAN4 |
| 家庭 LAN | 192.168.50.0/24，网关 192.168.50.1 |

不要假定这些值适用于其他地区、运营商、固件版本或硬件 revision。

## 原理

LAN4 被设为 Hybrid Port，而非普通 LAN 口或专用 IPTV Access Port：

~~~text
LAN4
├── VLAN1：Untagged，PVID 1
│   └── 家庭 LAN / 192.168.50.x / DHCP Option125（A 面）
└── VLAN1103：Tagged
    └── 上海移动 IPTV DHCP / 47.x.x.x（B 面）
~~~

BE3600 的 LAN 侧使用 RTL8367S。实测中 LAN4 对应该交换机 internal port 1（mask `0x02`）；VLAN1103 的成员掩码为 `0x10002`、untag 掩码为 `0x0`，LAN4 保持 PVID 1，并允许 Tagged Frame。

脚本建立只承载 VLAN1103 的二层桥：

~~~text
br0.1103 <-> br-iptv1103 <-> eth0.1103
~~~

它不会直接桥接 `br0` 和 IPTV WAN，因而家庭 DHCP 与运营商 IPTV DHCP 不会落入同一广播域。普通 LAN 的 dnsmasq 会附加已在该环境验证的 DHCP Option125 payload。

## 风险与前置条件

- 脚本会操作 RTL8367S、创建/删除 VLAN 子接口与 bridge，并在需要时重启主 dnsmasq；操作前请有可用的 SSH 恢复手段。
- 它会严格检查机型、固件/kernel、WAN/LAN/IPTV NVRAM profile、`/dev/rtkswitch`、rtl8367s 模块、LAN 地址、WAN VLAN1101 拓扑，以及已有 VLAN 状态。任何不匹配都会拒绝自动写入。
- Option125 仅为当前上海移动环境实测值。其他线路应从自己的光猫或抓包中确认；抓包中的 `7d 28` 是 DHCP option code/长度，不属于应写入 dnsmasq 的 payload。
- 应先确认魔百盒主动发送 Tagged VLAN1103、手工建桥后可以播放，再安装本脚本。不要把 LAN4 的 PVID 改为 1103。
- `/tmp/etc/dnsmasq.conf` 是原厂固件生成 Option125 配置时的基线文件，可能被重新生成；它**不是**最终 DHCP 是否已加载 Option125 的验证目标。
- 本项目不下载文件、不写 NVRAM、不刷写驱动或 flash，也不清空防火墙规则。

## 先手工验证

在当前实测端口映射下，LAN4 的 VLAN1103 放行步骤：

~~~sh
rtkswitch 36 1103
rtkswitch 390 0x00000002
rtkswitch 397 0x01
~~~

建立专用二层桥：

~~~sh
ip link add link eth0 name eth0.1103 type vlan id 1103
brctl addbr br-iptv1103
brctl addif br-iptv1103 eth0.1103
brctl addif br-iptv1103 br0.1103
ip link set dev eth0.1103 up
ip link set dev br0.1103 up
ip link set dev br-iptv1103 up
~~~

并确保家庭 LAN DHCP 向魔百盒提供所需的 Option125。只有 Internet、魔百盒 A 面/B 面和实际频道播放都已验证正常时，才能继续。

## 安装运行时脚本

将本仓库中的 `iptv.sh` 上传到路由器，例如 `/tmp/iptv.sh`，然后执行只读探测：

~~~sh
sh /tmp/iptv.sh boot-probe
~~~

`boot-probe` 检查 USB、原厂应用启动器和已有 hook，不会安装开机 hook 或修改系统配置。

在 IPTV 已手工验证正常播放时安装：

~~~sh
sh /tmp/iptv.sh install
~~~

它会复制自身到 `/jffs/be3600-iptv/iptv.sh`、写入平台/profile pin 并保留 dnsmasq 基线；安装过程不会重启网络服务，也不会自行安装开机触发器。

~~~sh
# 启用自动维护并立即启动 watcher
sh /jffs/be3600-iptv/iptv.sh start

# 查看 pin、watcher、bridge、DHCP 与最近日志
sh /jffs/be3600-iptv/iptv.sh status

# 单次检查/恢复，不启动循环 watcher
sh /jffs/be3600-iptv/iptv.sh once

# 停止 watcher，且禁用后续外部开机触发
sh /jffs/be3600-iptv/iptv.sh stop

# 删除自定义 VLAN/bridge，恢复普通 LAN4，并请求 ASUS dnsmasq 重启
sh /jffs/be3600-iptv/iptv.sh rollback
~~~

`status` 不会验证实际频道播放，也不会验证开机触发是否成功；最终应通过一次不手工干预的完整重启与实际播放来验收。

## 推荐开机自启动：独立 Asusware `iptv` 包

原厂 ASUSWRT 不应假定支持 Merlin 的 `/jffs/scripts/services-start`。本方案使用 ASUS USB Application（Asusware）已经注册的应用启动框架，但**不修改** Download Master 的 `S50downloadmaster`。

先在 WebUI 安装并启用一次 Download Master，以安装并保留 Asusware/USB Application 环境。然后把仓库中的 [`asusware/S99iptv`](asusware/S99iptv) 和 [`asusware/iptv.control`](asusware/iptv.control) 上传到路由器（以下假定上传到了 `/tmp`），并部署：

~~~sh
cp -p /tmp/S99iptv /opt/etc/init.d/S99iptv
cp -p /tmp/iptv.control /opt/lib/ipkg/info/iptv.control
chmod 755 /opt/etc/init.d/S99iptv
grep '^Enabled:' /opt/lib/ipkg/info/iptv.control
~~~

最后一行必须输出 `Enabled: yes`。`S99iptv` 在收到 `start`、`restart` 或 `firewall-start` 时后台执行 `/jffs/be3600-iptv/iptv.sh autostart`；收到 `stop` 时停止 watcher。`autostart` 仅在 `/jffs/be3600-iptv/enabled` 存在时才启动 watcher，执行过 `stop` 后该标记会被删除。重新启用：

~~~sh
sh /jffs/be3600-iptv/iptv.sh start
~~~

在确认独立 `iptv` 包能运行后，Download Master 只需保留为 Asusware 环境的安装来源，不必保持启用。可将它设为禁用：

~~~sh
sed -i 's/^Enabled: .*/Enabled: no/' /opt/lib/ipkg/info/downloadmaster.control
grep '^Enabled:' /opt/lib/ipkg/info/downloadmaster.control
~~~

冷启动实测中，该字段会保持 `Enabled: no`，不会有 `dm2_*`、`amuled`、`transmission`、`nzbget` 或 `snarf` 进程；IPTV 仍由 `S99iptv` 自动启动。复核：

~~~sh
ps w | grep -E '[d]m2_|[a]muled|[t]ransmission|[n]zbget|[s]narf'
~~~

无输出即符合该实测结果。**暂不要禁用 `asuslighttpd`**：它目前继续保留，避免在未验证其与 Asusware 启动框架的关系前扩大变更范围。

### 旧 `S50downloadmaster` wrapper（历史方案）

旧版文档建议备份并替换 `/opt/etc/init.d/S50downloadmaster`。该方案现在仅保留为历史记录，**不再推荐，也不应与 `S99iptv` 同时使用**。如果此前安装过 wrapper，先恢复原 Download Master 脚本，再部署独立 `S99iptv`：

~~~sh
cd /opt/etc/init.d || exit 1
test -f .S50downloadmaster.asus-original && \
  cp -p .S50downloadmaster.asus-original S50downloadmaster
chmod 755 S50downloadmaster
~~~

## 冷启动验收与 DHCP 验证

完成上述部署并执行 `start` 后，进行一次完整冷启动，不手工重建 VLAN/bridge，也不手工运行 `autostart`。`S99iptv` 在同一次启动中可能同时收到 `start` 和 `firewall-start`；这是原厂应用框架的时序现象。`iptv.sh` 的 watcher 有单实例锁，第二次调用会安全退出，不会启动第二个 watcher 或并发写入网络配置。

建议检查：

~~~sh
cat /tmp/be3600-iptv-boot.log
sh /jffs/be3600-iptv/iptv.sh status
~~~

不要用 `grep /tmp/etc/dnsmasq.conf` 作为最终 Option125 验收，因为该文件不是当前正在运行的 dnsmasq 必然使用的配置。应从 pid file 取得**当前主 dnsmasq**的命令行，再解析实际 `--conf-file`：

~~~sh
PID=$(cat /var/run/dnsmasq.pid)

CONF=$(tr '\0' '\n' < "/proc/$PID/cmdline" |
       sed -n 's/^--conf-file=//p' |
       tail -n 1)

echo "PID=$PID"
echo "CONF=$CONF"
grep -n 'dhcp-option-force=125' "$CONF"
~~~

本环境的冷启动实测结果是：主 dnsmasq 的 PID 为 `8824`，实际配置为 `/tmp/be3600-iptv-state/dnsmasq.conf`，其中存在完整的 Option125 行。

启动初期也可能出现：

~~~text
[uptime 70] RETRY: dnsmasq PID changed during preparation; deferred to next cycle
~~~

这不是故障：ASUS 原厂服务正好替换了 dnsmasq，脚本的 PID-change guard 因而放弃本轮，以免操作已经变化的进程。watcher 会在下一轮重试；实测后续在 uptime 133 自动记录 `Restored Option125; restarted only the primary dnsmasq`，随后 `Health check OK`。不要为消除这条信息而移除或弱化保护逻辑。

## 回滚独立自启动项

先回滚 IPTV 运行时配置，再移除独立 Asusware 条目：

~~~sh
sh /jffs/be3600-iptv/iptv.sh rollback
rm -f /opt/etc/init.d/S99iptv /opt/lib/ipkg/info/iptv.control
~~~

确认网络恢复后，再自行决定是否删除 `/jffs/be3600-iptv/`。如果先前使用过旧 wrapper，请确认已按上文恢复原 `S50downloadmaster` 脚本。

## 文件

- `iptv.sh`：v1.0.1 运行时恢复脚本。
- `asusware/S99iptv`：独立 Asusware 启动入口。
- `asusware/iptv.control`：使 `S99iptv` 被 Asusware 识别为已启用的包元数据。
- `README.md`：当前环境、原理、手工验证、独立自启动、冷启动验收与回滚说明。

本项目采用 [GNU GPL v3.0-only](LICENSE) 许可证。脚本会修改路由器运行时网络配置，请自行评估风险；作者不提供任何担保。
