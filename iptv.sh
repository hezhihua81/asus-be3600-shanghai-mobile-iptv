#!/bin/sh
# BE3600 A1 / Shanghai Mobile IPTV runtime restoration, v1.0.0
# This is NOT an installer for a boot hook. Use 'boot-probe' first.
# Commands and topology are based on the user's successful 2026-09-06 test.
# Driver SHA256 that was analysed:
# 0441e0f814310f10b1804fecde1668831da2bc827a0dbb10dfe5255856fa0ef2
# No downloads, nvram writes, flash driver changes or firewall flushing.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
umask 077
BASE=/jffs/be3600-iptv
SELF=$BASE/iptv.sh
STATE=/tmp/be3600-iptv-state
SOURCE=/tmp/etc/dnsmasq.conf
PIDFILE=/var/run/dnsmasq.pid
BR=br-iptv1103
LV=br0.1103
WV=eth0.1103
PERIOD=60
SWITCH_PERIOD=300
OPT='dhcp-option-force=125,00:00:00:00:23:02:06:48:47:57:2d:43:54:03:0d:48:47:35:31:34:33:46:20:28:4f:4e:55:29:0a:02:04:4d:0b:02:04:4f:0d:02:04:4e'

have() {
    for hp in /sbin /bin /usr/sbin /usr/bin; do
        [ -x "$hp/$1" ] && return 0
    done
    return 1
}
state_dir() {
    [ ! -L "$STATE" ] || return 1
    mkdir -p "$STATE" && chmod 700 "$STATE"
}
uptime_s() { read us ur < /proc/uptime; printf '%s\n' "${us%%.*}"; }
note() {
    # Script logs are bounded and kept in RAM. rtkswitch also emits kernel logs.
    if [ -f "$STATE/log" ]; then
        nb=$(wc -c < "$STATE/log")
        [ "$nb" -le 65536 ] || { tail -n 100 "$STATE/log" > "$STATE/log.new"; mv "$STATE/log.new" "$STATE/log"; }
    fi
    printf '[uptime %s] %s\n' "$(uptime_s)" "$*" >> "$STATE/log"
}
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
identity() {
    for key in productid odmpid firmver buildno extendno; do
        printf '%s=%s\n' "$key" "$(nvram get "$key")"
    done
    printf 'kernel=%s\n' "$(uname -r)"
}
profile() {
    # Pin the existing working layout. Deliberate mode/port changes are not undone.
    for key in sw_mode wan0_proto switch_wantag switch_stb_x switch_wan0tagid switch_wan1tagid switch_wan2tagid iptv_stb_port lan_ipaddr wans_dualwan wans_lanport; do
        printf '%s=%s\n' "$key" "$(nvram get "$key")"
    done
}
preflight() {
    for tool in nvram rtkswitch ip brctl dnsmasq dmesg grep sed tail tr cat cp mv mkdir chmod rm rmdir mount ls service sleep wc uname find; do
        have "$tool" || { fail "Required tool missing: $tool"; return 1; }
    done
    [ -c /dev/rtkswitch ] || { fail '/dev/rtkswitch not present'; return 1; }
    grep -q '^rtl8367s ' /proc/modules || { fail 'rtl8367s not loaded'; return 1; }
    [ -r "$SOURCE" ] || { fail 'Firmware dnsmasq configuration not ready'; return 1; }
    grep -qx 'interface=br0' "$SOURCE" || { fail 'Unexpected LAN DHCP interface'; return 1; }
    [ "$(nvram get sw_mode)" = 1 ] || { fail 'Not in wireless-router mode'; return 1; }
    [ "$(nvram get lan_ipaddr)" = 192.168.50.1 ] || { fail 'LAN address differs from tested layout'; return 1; }
    wdesc=$(ip -d link show vlan1101 2>/dev/null) || { fail 'vlan1101 not ready'; return 1; }
    case "$wdesc" in
        *'vlan1101@eth0:'*'vlan protocol 802.1Q id 1101 '*) ;;
        *) fail 'WAN is not the tested vlan1101@eth0 layout'; return 1 ;;
    esac
    [ ! -e /sys/class/net/eth0/master ] || { fail 'eth0 unexpectedly has a bridge master'; return 1; }
}
guards() {
    [ -r "$BASE/platform.pin" ] && [ -r "$BASE/profile.pin" ] || { fail 'Run install from the known-working state first'; return 1; }
    [ "$(identity)" = "$(cat "$BASE/platform.pin")" ] || { fail 'Firmware/model/kernel changed; automatic writes suspended'; return 1; }
    [ "$(profile)" = "$(cat "$BASE/profile.pin")" ] || { fail 'WAN/LAN/IPTV settings changed; automatic writes suspended'; return 1; }
    preflight
}
main_pid() {
    mp=$(cat "$PIDFILE" 2>/dev/null) || return 1
    case "$mp" in ''|*[!0-9]*|0|1) return 1;; esac
    [ "$(cat "/proc/$mp/comm" 2>/dev/null)" = dnsmasq ] || return 1
    printf '%s\n' "$mp"
}
process_conf() {
    # Tested stock command is 'dnsmasq --log-async'; manual tests use --conf-file=.
    pc=$(tr '\000' '\n' < "/proc/$1/cmdline" | sed -n 's/^--conf-file=//p' | tail -n 1)
    [ -n "$pc" ] || pc=$SOURCE
    printf '%s\n' "$pc"
}
valid_vlan() {
    vd=$(ip -d link show "$1" 2>/dev/null) || return 1
    case "$vd" in
        *"$1@$2:"*'vlan protocol 802.1Q id 1103 '*) return 0 ;;
    esac
    return 1
}
net_conflict() {
    for pair in "$LV:br0" "$WV:eth0"; do
        vi=${pair%:*}; vp=${pair#*:}
        if [ -d "/sys/class/net/$vi" ]; then
            valid_vlan "$vi" "$vp" || { fail "Unexpected interface: $vi"; return 1; }
            if [ -e "/sys/class/net/$vi/master" ] && [ ! -d "/sys/class/net/$BR/brif/$vi" ]; then
                fail "$vi belongs to another bridge"; return 1
            fi
        fi
    done
    if [ -d "/sys/class/net/$BR" ]; then
        [ -d "/sys/class/net/$BR/bridge" ] || { fail "$BR is not a bridge"; return 1; }
        for be in /sys/class/net/$BR/brif/*; do
            [ -e "$be" ] || continue
            case "${be##*/}" in "$LV"|"$WV") ;; *) fail "$BR has an unexpected member"; return 1;; esac
        done
    fi
}
net_healthy() {
    net_conflict || return 1
    for ni in "$LV" "$WV" "$BR"; do
        [ -r "/sys/class/net/$ni/flags" ] || return 1
        nf=$(cat "/sys/class/net/$ni/flags")
        [ $((nf & 1)) -eq 1 ] || return 1
    done
    [ -d "/sys/class/net/$BR/brif/$LV" ] && [ -d "/sys/class/net/$BR/brif/$WV" ]
}
ensure_network() {
    net_conflict || return 1
    net_changed=0
    for pair in "$LV:br0" "$WV:eth0"; do
        ni=${pair%:*}; np=${pair#*:}
        if [ ! -d "/sys/class/net/$ni" ]; then
            ip link add link "$np" name "$ni" type vlan id 1103 || return 1
            net_changed=1
        fi
    done
    if [ ! -d "/sys/class/net/$BR" ]; then
        brctl addbr "$BR" || return 1
        net_changed=1
    fi
    for ni in "$WV" "$BR"; do
        iv="/proc/sys/net/ipv6/conf/$ni/disable_ipv6"
        if [ -f "$iv" ] && [ "$(cat "$iv")" != 1 ]; then
            echo 1 > "$iv" || return 1
        fi
    done
    for ni in "$WV" "$LV"; do
        if [ ! -d "/sys/class/net/$BR/brif/$ni" ]; then
            brctl addif "$BR" "$ni" || return 1
            net_changed=1
        fi
    done
    for ni in "$WV" "$LV" "$BR"; do
        nf=$(cat "/sys/class/net/$ni/flags") || return 1
        if [ $((nf & 1)) -eq 0 ]; then
            ip link set dev "$ni" up || return 1
            net_changed=1
        fi
    done
    net_healthy || { fail 'Network readback did not match'; return 1; }
    [ "$net_changed" -eq 0 ] || note 'Restored VLAN subinterfaces / dedicated IPTV bridge'
}
switch_read() {
    # These are driver-specific queries; results are printed into dmesg.
    rtkswitch 393 || return 1
    rtkswitch 396 || return 1
    rtkswitch 36 1 || return 1
    rtkswitch 399 || return 1
    rtkswitch 36 1103 || return 1
    rtkswitch 399 || return 1
    sd=$(dmesg | tail -n 160 | tr 'A-Z' 'a-z')
    s1=$(printf '%s\n' "$sd" | grep 'get vlan mbr/untag - vid = 1,' | tail -n 1)
    s1103=$(printf '%s\n' "$sd" | grep 'get vlan mbr/untag - vid = 1103,' | tail -n 1)
    st=$(printf '%s\n' "$sd" | grep 'p1(l1): vf_type is' | tail -n 1)
    printf '%s\n' "$s1" | grep -Eq 'mbrmsk = 0x0*3001f untagmsk = 0x0*3001f' || { fail 'Unexpected VLAN1 membership; no switch write'; return 1; }
    for sp in 1 2 3 4; do
        pv=$(printf '%s\n' "$sd" | grep "p$sp pvid=" | tail -n 1)
        printf '%s\n' "$pv" | grep -q "p$sp pvid=1," || { fail "Unexpected PVID on SDK port $sp"; return 1; }
    done
    case "$st" in *'vf_type is 0') switch_frame=ok;; *'vf_type is 2') switch_frame=missing;; *) fail 'Cannot read port frame type'; return 1;; esac
    if printf '%s\n' "$s1103" | grep -Eq 'mbrmsk = 0x0*10002 untagmsk = 0x0+([[:space:]]|$)'; then
        switch_vlan=ok
    elif printf '%s\n' "$s1103" | grep -Eq 'mbrmsk = 0x0+ untagmsk = 0x0+([[:space:]]|$)'; then
        switch_vlan=missing
    else
        fail 'VLAN1103 has another configuration; refusing to overwrite'; return 1
    fi
}
ensure_switch() {
    switch_read || return 1
    sw_changed=0
    if [ "$switch_vlan" != ok ]; then
        rtkswitch 36 1103 && rtkswitch 390 0x00000002 || return 1
        sw_changed=1
    fi
    if [ "$switch_frame" != ok ]; then
        rtkswitch 397 0x01 || return 1
        sw_changed=1
    fi
    if [ "$sw_changed" -eq 1 ]; then
        switch_read || return 1
        [ "$switch_vlan/$switch_frame" = ok/ok ] || { fail 'Switch write readback failed'; return 1; }
        note 'Restored LAN4 tagged-1103 path; PVID1 retained'
    fi
    uptime_s > "$STATE/switch-checked"
}
make_dns_config() {
    # Rebuild from the CURRENT firmware file; never freeze the whole LAN config.
    # Preserve all other options. Replace only the untagged option-125 form used here.
    sed '/^dhcp-option-force=125,/d' "$SOURCE" > "$1" || return 1
    printf '\n%s\n' "$OPT" >> "$1"
}
dns_healthy() {
    dp=$(main_pid) || return 1
    dc=$(process_conf "$dp")
    [ -r "$dc" ] || return 1
    grep -Fxq "$OPT" "$dc" || return 1
    # An externally started but known-good config can be adopted without restart.
    [ -f "$STATE/dns-base" ] || return 1
    [ "$(cat "$STATE/dns-base")" = "$(cat "$SOURCE")" ] || return 1
    [ "$(cat "$STATE/dns-pid" 2>/dev/null)" = "$dp" ] || return 1
}
ensure_dns() {
    dns_healthy && return 0
    dp=$(main_pid) || { fail 'No primary dnsmasq PID; waiting for stock service'; return 1; }
    dc=$(process_conf "$dp")
    # Initial adoption prevents a needless restart of the currently working test.
    if [ ! -f "$STATE/dns-base" ] && [ -r "$dc" ] && grep -Fxq "$OPT" "$dc"; then
        cp "$SOURCE" "$STATE/dns-base" || return 1
        printf '%s\n' "$dp" > "$STATE/dns-pid"
        note 'Adopted existing dnsmasq with the expected Option125; no restart'
        return 0
    fi
    now=$(uptime_s)
    last=$(cat "$STATE/dns-last-attempt" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0;; esac
    [ "$last" -eq 0 ] || [ $((now-last)) -ge 300 ] || { fail 'DNS restart cooldown active'; return 1; }

    cp "$SOURCE" "$STATE/dns-base.next" || return 1
    make_dns_config "$STATE/dnsmasq.next" || return 1
    dnsmasq --test --conf-file="$STATE/dnsmasq.next" > "$STATE/dns-test.log" 2>&1 || {
        fail 'dnsmasq syntax check failed; current service was NOT stopped'; return 1
    }
    sleep 2
    [ "$(cat "$SOURCE")" = "$(cat "$STATE/dns-base.next")" ] || { fail 'Firmware config still changing; deferred'; return 1; }
    [ "$(main_pid)" = "$dp" ] || { fail 'dnsmasq PID changed during preparation; deferred'; return 1; }
    # Keep a backup before replacing this script's managed configuration.
    [ ! -f "$STATE/dnsmasq.conf" ] || cp "$STATE/dnsmasq.conf" "$STATE/dnsmasq.previous"
    mv "$STATE/dnsmasq.next" "$STATE/dnsmasq.conf" || return 1
    printf '%s\n' "$now" > "$STATE/dns-last-attempt"
    kill -TERM "$dp" || return 1
    n=0
    while [ -d "/proc/$dp" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n+1)); done
    if [ -d "/proc/$dp" ]; then
        fail 'dnsmasq did not exit; no SIGKILL issued'; return 1
    fi
    if main_pid >/dev/null 2>&1; then
        fail 'Stock firmware already restarted dnsmasq; deferred'; return 1
    fi
    if dnsmasq --log-async --conf-file="$STATE/dnsmasq.conf"; then
        sleep 1
        np=$(main_pid)
        if [ -n "$np" ] && [ "$(process_conf "$np")" = "$STATE/dnsmasq.conf" ]; then
            mv "$STATE/dns-base.next" "$STATE/dns-base"
            printf '%s\n' "$np" > "$STATE/dns-pid"
            note 'Restored Option125; restarted only the primary dnsmasq'
            return 0
        fi
    fi
    note 'Managed dnsmasq start failed; requesting ASUS stock-service recovery'
    service restart_dnsmasq
    fail 'DNS test failed; stock service recovery requested, retries rate-limited'
}
lock_once() {
    if mkdir "$STATE/apply.lock" 2>/dev/null; then
        echo $$ > "$STATE/apply.lock/pid"; return 0
    fi
    lp=$(cat "$STATE/apply.lock/pid" 2>/dev/null)
    case "$lp" in ''|*[!0-9]*|0|1) ;; *)
        if kill -0 "$lp" 2>/dev/null; then return 1; fi
        ;;
    esac
    rm -f "$STATE/apply.lock/pid"
    rmdir "$STATE/apply.lock" 2>/dev/null || return 1
    mkdir "$STATE/apply.lock" || return 1
    echo $$ > "$STATE/apply.lock/pid"
}
once() (
    state_dir || exit 1
    lock_once || { echo 'Another apply is active; skipped'; exit 0; }
    trap 'rm -f "$STATE/apply.lock/pid"; rmdir "$STATE/apply.lock" 2>/dev/null' 0
    guards || exit 1
    # Do not write hardware while an incompatible Linux layout is present.
    net_conflict || exit 1
    nh=0; net_healthy && nh=1
    dp=$(main_pid 2>/dev/null)
    lastdp=$(cat "$STATE/dns-pid" 2>/dev/null)
    sc=$(cat "$STATE/switch-checked" 2>/dev/null)
    case "$sc" in ''|*[!0-9]*) sc=0;; esac
    now=$(uptime_s)
    if [ "$nh" -eq 0 ] || [ "$dp" != "$lastdp" ] || [ "$sc" -eq 0 ] || [ $((now-sc)) -ge "$SWITCH_PERIOD" ]; then
        ensure_switch || exit 1
    fi
    ensure_network || exit 1
    ensure_dns || exit 1
    printf 'Runtime configuration healthy at uptime %s. Playback not probed.\n' "$(uptime_s)" > "$STATE/health"
)
watch_pid() {
    wp=$(cat "$STATE/watch.pid" 2>/dev/null) || return 1
    case "$wp" in ''|*[!0-9]*|0|1) return 1;; esac
    kill -0 "$wp" 2>/dev/null || return 1
    wa=$(tr '\000' ' ' < "/proc/$wp/cmdline" 2>/dev/null)
    case "$wa" in *"$SELF watch"*) printf '%s\n' "$wp";; *) return 1;; esac
}
start_watch() {
    state_dir || return 1
    [ -r "$BASE/platform.pin" ] && [ -r "$BASE/profile.pin" ] || return 1
    if watch_pid >/dev/null; then echo 'Watcher already running'; return 0; fi
    # Ignore SSH-session HUP; all standard streams are detached.
    ( trap '' HUP; exec /bin/sh "$SELF" watch ) </dev/null >/dev/null 2>&1 &
    sleep 1
    echo 'Watcher launch requested; run status and inspect /tmp log.'
}
watch() {
    state_dir || exit 1
    if ! mkdir "$STATE/watch.lock" 2>/dev/null; then
        watch_pid >/dev/null && exit 0
        rmdir "$STATE/watch.lock" 2>/dev/null || exit 1
        mkdir "$STATE/watch.lock" || exit 1
    fi
    echo $$ > "$STATE/watch.pid"
    trap 'rm -f "$STATE/watch.pid"; rmdir "$STATE/watch.lock" 2>/dev/null' 0
    trap 'exit 0' TERM INT
    note 'Watcher started (runtime loop; boot-hook verification is separate)'
    while [ -f "$BASE/enabled" ]; do
        if /bin/sh "$SELF" once > "$STATE/last-run.log" 2>&1; then
            [ "$(cat "$STATE/result" 2>/dev/null)" = ok ] || note 'Health check OK'
            echo ok > "$STATE/result"
        else
            err=$(tail -n 2 "$STATE/last-run.log")
            [ "$(cat "$STATE/result" 2>/dev/null)" = "$err" ] || note "$err"
            printf '%s\n' "$err" > "$STATE/result"
        fi
        sleep "$PERIOD" & wait $!
    done
}
stop_watch() {
    rm -f "$BASE/enabled"
    wp=$(watch_pid 2>/dev/null)
    [ -z "$wp" ] || kill -TERM "$wp"
    echo 'Automatic attempts disabled. Current working network is left in place.'
}
install() {
    [ ! -e "$BASE" ] || { fail "$BASE already exists; not overwriting"; return 1; }
    state_dir && preflight && net_healthy && switch_read || return 1
    [ "$switch_vlan/$switch_frame" = ok/ok ] || { fail 'Install only while the tested configuration is working'; return 1; }
    dp=$(main_pid) || return 1
    dc=$(process_conf "$dp")
    [ -r "$dc" ] && grep -Fxq "$OPT" "$dc" || { fail 'Current primary dnsmasq does not have the tested Option125'; return 1; }
    mount | grep ' on /jffs ' >/dev/null || { fail '/jffs is not mounted'; return 1; }
    mkdir "$BASE" && chmod 700 "$BASE" || return 1
    cp "$0" "$SELF" && chmod 700 "$SELF" || return 1
    identity > "$BASE/platform.pin"
    profile > "$BASE/profile.pin"
    cp "$SOURCE" "$STATE/dns-base"
    printf '%s\n' "$dp" > "$STATE/dns-pid"
    uptime_s > "$STATE/switch-checked"
    echo "Installed in $BASE. Nothing restarted; NO boot hook installed."
}
status() {
    state_dir || return 1
    echo '=== Pins / preconditions ==='
    if guards; then echo MATCH; else echo 'SUSPENDED / NOT READY'; fi
    echo '=== Watcher ==='
    if wp=$(watch_pid); then echo "Running PID $wp"; else echo NOT_RUNNING; fi
    [ ! -f "$BASE/enabled" ] || echo 'Enabled for an EXTERNAL boot trigger'
    echo '=== Network ==='
    if net_healthy; then echo 'VLAN bridge layout OK'; else echo 'VLAN bridge not healthy'; fi
    brctl show "$BR" 2>/dev/null
    echo '=== DHCP ==='
    if dns_healthy; then echo 'Expected Option125 configuration loaded'; else echo 'DHCP state needs attention'; fi
    echo '=== Last attempt ==='
    cat "$STATE/health" "$STATE/last-run.log" 2>/dev/null
    echo '=== Recent script log ==='
    tail -n 12 "$STATE/log" 2>/dev/null
    echo 'STATUS DOES NOT VERIFY IPTV PLAYBACK OR BOOT AUTOSTART.'
}
boot_probe() {
    echo '=== USB / ASUS application capability (read-only) ==='
    for key in apps_install_folder apps_mounted_path apps_dev; do
        printf '%s=%s\n' "$key" "$(nvram get "$key")"
    done
    echo '--- USB mounts ---'
    mount | grep '/tmp/mnt/' || :
    echo '--- Stock application launcher ---'
    for bf in /usr/sbin/app_init_run.sh /usr/sbin/app_get_field.sh /usr/sbin/app_base_link.sh; do
        ls -l "$bf" 2>/dev/null || :
    done
    echo '--- Existing user hook / application scripts (names only) ---'
    ls -l /jffs/scripts/usb-mount-script /jffs/scripts/services-start 2>/dev/null || :
    ls -l /opt/etc/init.d 2>/dev/null || :
    echo 'No boot variables, USB files or security services were modified.'
}
rollback() (
    state_dir || exit 1
    stop_watch
    n=0
    until lock_once; do n=$((n+1)); [ "$n" -lt 20 ] || exit 1; sleep 2; done
    trap 'rm -f "$STATE/apply.lock/pid"; rmdir "$STATE/apply.lock" 2>/dev/null' 0
    guards && net_conflict && switch_read || exit 1
    if [ -d "/sys/class/net/$BR" ]; then
        ip link set dev "$BR" down || exit 1
        for ri in "$LV" "$WV"; do
            [ ! -d "/sys/class/net/$BR/brif/$ri" ] || brctl delif "$BR" "$ri" || exit 1
        done
        brctl delbr "$BR" || exit 1
    fi
    for ri in "$LV" "$WV"; do
        [ ! -d "/sys/class/net/$ri" ] || ip link delete dev "$ri" || exit 1
    done
    rtkswitch 397 0x21 && rtkswitch 36 1103 && rtkswitch 3901 0 || exit 1
    service restart_dnsmasq
    note 'Rollback requested: dedicated IPTV path removed, ASUS dnsmasq restarted'
    echo 'Rolled back to normal LAN4; IPTV custom path disabled.'
)

case "${1:-help}" in
    install) install ;;
    start) state_dir && guards && { : > "$BASE/enabled"; start_watch; } ;;
    autostart) [ -f "$BASE/enabled" ] && start_watch ;;
    watch) watch ;;
    once) once ;;
    stop) state_dir && stop_watch ;;
    status) status ;;
    boot-probe) boot_probe ;;
    rollback) rollback ;;
    *) echo "Usage: sh $0 install|start|once|status|stop|rollback|boot-probe|autostart" ;;
esac
