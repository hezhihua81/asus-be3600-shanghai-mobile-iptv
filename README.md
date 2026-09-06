# ASUS TUF-BE3600 A1 上海移动 IPTV 单线复用

在 ASUS TUF Gaming BE3600 A1 原厂固件上，为上海移动魔百盒保留 LAN4 普通家庭网络的同时，透传 IPTV VLAN，实现一根网线提供 A/B 两个逻辑网络，并在重启后恢复运行时配置。

> 这是特定环境中已验证的运行时恢复方案，不是从零开始的一键安装器。必须先手工验证 IPTV 已正常播放，再执行 install。

## 已验证环境

| 项目 | 实测值 |
| --- | --- |
| 路由器 | ASUS TUF Gaming BE3600 A1 |
| 固件 | ASUS 原厂固件（3.0.0.6.102 系列） |
| 运营商 | 上海移动 |
| Internet | PPPoE，VLAN 1101（vlan1101@eth0） |
| IPTV | VLAN 1103 |
| 机顶盒端口 | LAN4 |
| 家庭 LAN | 192.168.50.0/24，网关 192.168.50.1 |

不要假定这些值适用于其他地区、运营商、固件版本或硬件 revision。

## 原理

LAN4 被设为 Hybrid Port，而非普通 LAN 口或专用 IPTV Access Port：

~~~
LAN4
├── VLAN1：Untagged，PVID 1
│   └── 家庭 LAN / 192.168.50.x / DHCP Option125（A 面）
└── VLAN1103：Tagged
    └── 上海移动 IPTV DHCP / 47.x.x.x（B 面）
~~~

BE3600 的 LAN 侧使用 RTL8367S。实测中 LAN4 对应该交换机 internal port 1（mask 0x02）；VLAN1103 的成员掩码为 0x10002、untag 掩码为 0x0，LAN4 保持 PVID 1，并允许 Tagged Frame。

脚本建立只承载 VLAN1103 的二层桥：

~~~
br0.1103 <-> br-iptv1103 <-> eth0.1103
~~~

它不会直接桥接 br0 和 IPTV WAN，因而家庭 DHCP 与运营商 IPTV DHCP 不会落入同一广播域。普通 LAN 的 dnsmasq 会附加已在该环境验证的 DHCP Option125 payload。

## 风险与前置条件

- 脚本会操作 RTL8367S、创建/删除 VLAN 子接口与 bridge，并在需要时重启主 dnsmasq；操作前请有可用的 SSH 恢复手段。
- 它会严格检查机型、固件/kernel、WAN/LAN/IPTV NVRAM profile、/dev/rtkswitch、rtl8367s 模块、LAN 地址、WAN VLAN1101 拓扑，以及已有 VLAN 状态。任何不匹配都会拒绝自动写入。
- Option125 仅为当前上海移动环境实测值。其他线路应从自己的光猫或抓包中确认；抓包中的 7d 28 是 DHCP option code/长度，不属于应写入 dnsmasq 的 payload。
- 应先确认魔百盒主动发送 Tagged VLAN1103、手工建桥后可以播放，再安装本脚本。不要把 LAN4 的 PVID 改为 1103。
- /tmp/etc/dnsmasq.conf 是原厂固件的运行时文件，可能被重新生成；脚本为此设计了检测、语法测试、冷却时间和恢复逻辑。
- 本项目不下载文件、不写 NVRAM、不刷写驱动或 flash，也不清空防火墙规则。

## 先手工验证

在当前实测端口映射下，LAN4 的 VLAN1103 放行步骤：

~~~
rtkswitch 36 1103
rtkswitch 390 0x00000002
rtkswitch 397 0x01
~~~

建立专用二层桥：

~~~
ip link add link eth0 name eth0.1103 type vlan id 1103
brctl addbr br-iptv1103
brctl addif br-iptv1103 eth0.1103
brctl addif br-iptv1103 br0.1103
ip link set dev eth0.1103 up
ip link set dev br0.1103 up
ip link set dev br-iptv1103 up
~~~

并确保家庭 LAN DHCP 向魔百盒提供所需的 Option125。只有 Internet、魔百盒 A 面/B 面和实际频道播放都已验证正常时，才能继续。

## 安装与日常命令

将本仓库中的 iptv.sh 上传到路由器，例如 /tmp/iptv.sh，然后执行只读探测：

~~~
sh /tmp/iptv.sh boot-probe
~~~

boot-probe 检查 USB、原厂应用启动器和已有 hook，不会安装开机 hook 或修改系统配置。

在 IPTV 已手工验证正常播放时安装：

~~~
sh /tmp/iptv.sh install
~~~

它会复制自身到 /jffs/be3600-iptv/iptv.sh、写入平台/profile pin 并保留 dnsmasq 基线；安装过程不会重启网络服务，也不会安装开机触发器。

~~~
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

status 不会验证实际频道播放，也不会验证开机触发是否成功；最终应通过一次不手工干预的完整重启与实际播放来验收。

## 原厂固件的 Download Master 开机触发

原厂 ASUSWRT 不应假定支持 Merlin 的 /jffs/scripts/services-start。本方案利用 ASUS USB Application / Download Master 已注册的启动框架。

先插入已被 ASUS 识别的 USB 存储设备，在 WebUI 安装并启用一次 Download Master；确认 /opt/etc/init.d/S50downloadmaster 已存在。先备份原脚本：

~~~
cd /opt/etc/init.d || exit 1
cp -p S50downloadmaster .S50downloadmaster.asus-original
~~~

将 S50downloadmaster 替换为下面 wrapper，并赋予可执行权限：

~~~
#!/bin/sh

ORIG="/opt/etc/init.d/.S50downloadmaster.asus-original"
IPTV="/jffs/be3600-iptv/iptv.sh"
LOG="/tmp/be3600-iptv-boot.log"

if [ ! -f "$ORIG" ]; then
    echo "ERROR: original Download Master init script missing: $ORIG" >&2
    exit 1
fi

sh "$ORIG" "$@"
RC=$?

case "$1" in
    start|restart|firewall-start)
        if [ -f "$IPTV" ]; then
            (
                echo "[$(date)] ASUS app hook: $1"
                /bin/sh "$IPTV" autostart
            ) >>"$LOG" 2>&1 &
        fi
        ;;
    stop)
        if [ -f "$IPTV" ]; then
            /bin/sh "$IPTV" stop >>"$LOG" 2>&1
        fi
        ;;
esac

exit "$RC"
~~~

~~~
chmod 755 /opt/etc/init.d/S50downloadmaster
~~~

autostart 仅在 /jffs/be3600-iptv/enabled 存在时启动 watcher；执行过 stop 后，该标记会被删除。重新启用：

~~~
sh /jffs/be3600-iptv/iptv.sh start
~~~

不要新建独立 S99iptv 并假定会执行：原厂 app_init_run.sh 可能只运行 ASUS 注册且启用的应用。Download Master wrapper 是此环境已验证的入口。

## 回滚 Download Master wrapper

先运行脚本回滚，再还原 Download Master 原脚本：

~~~
sh /jffs/be3600-iptv/iptv.sh rollback
cd /opt/etc/init.d || exit 1
cp -p .S50downloadmaster.asus-original S50downloadmaster
chmod 755 S50downloadmaster
~~~

确认网络恢复后，再自行决定是否删除 /jffs/be3600-iptv/。

## 文件

- iptv.sh：用户提供、已验证的 v1.0.0 运行时恢复脚本。
- README.md：当前环境、原理、手工验证、安装、开机触发与回滚说明。

本项目采用 [GNU GPL v3.0-only](LICENSE) 许可证。脚本会修改路由器运行时网络配置，请自行评估风险；作者不提供任何担保。
