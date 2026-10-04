#!/usr/bin/env bash
# Trojan + Hysteria2 personal installer. Original implementation, 2026-10-05.
# References: github.com/mack-a/v2ray-agent and sing-box.sagernet.org
# No network tuning, extra protocols, control panel or subscription website.
set +x
set +v
set -Eeuo pipefail
umask 077

APP=/etc/dual-proxy
BIN=/opt/dual-proxy
STATE=/var/lib/dual-proxy
UNIT_DIR=/etc/systemd/system
SERVICE=dual-proxy.service
RENEW_SERVICE=dual-proxy-renew.service
RENEW_TIMER=dual-proxy-renew.timer
MARKER='dual-proxy-installer:v1'
UNIT_MARKER='# Managed by dual-proxy-installer:v1'
INSTALL_VERSION=1.14.2
ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory
LOCK_FILE=/run/lock/dual-proxy-installer.lock
CERTBOT_BIN=/usr/bin/certbot
SYSTEMCTL_BIN=/usr/bin/systemctl
TMP=''
ACTION=install
COMMITTED=0
ACTIVATING=0
UPDATE_SWAPPED=0
WAS_ACTIVE=0
DOMAIN=''
ACCOUNT=''
PASSWORD=''
TROJAN_PORT=443
HY2_PORT=443

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
用法：sudo bash install-dual-proxy.sh [参数]
  无参数 / --install  交互安装 Trojan + Hysteria2
  --update            更新到 sing-box 官方最新稳定版，保留全部配置
  --uninstall         删除本脚本安装的服务、程序、配置及专用证书数据
  --help              显示说明

支持 Ubuntu 22.04+、Debian 12+，systemd，amd64 / arm64。
准备好直指本机的域名；TCP 80 必须可供证书验证使用。
在云防火墙/现有系统防火墙中放行 TCP 80、Trojan TCP 端口、HY2 UDP 端口。
密码交互输入，不接受命令行密码，也不输出带密码的分享链接。
HELP
}

owned() { [[ -f "$STATE/.owner" ]] && [[ $(<"$STATE/.owner") == "$MARKER" ]]; }
assert_paths() {
    local p
    for p in "$APP" "$BIN" "$STATE"; do
        [[ ! -L "$p" ]] || die "专用目录是符号链接，已停止：$p"
        [[ $(realpath -m -- "$p") == "$p" ]] || die "专用目录经过符号链接，已停止：$p"
    done
}
assert_units_owned() {
    local name path
    for name in "$SERVICE" "$RENEW_SERVICE" "$RENEW_TIMER"; do
        path="$UNIT_DIR/$name"
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -f "$path" && ! -L "$path" ]] || die "服务文件不是普通文件：$path"
            grep -Fqx -- "$UNIT_MARKER" "$path" || die "遇到不属于本脚本的服务文件：$path"
        fi
    done
}
require_owned() {
    assert_paths
    owned || die '未找到本脚本的安装标记；不会操作其他安装。'
    assert_units_owned
}
check_host() {
    [[ $EUID -eq 0 ]] || die '请使用 root 或 sudo bash 运行。'
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '需要使用 systemd 的 Linux。'
    [[ -r /etc/os-release ]] || die '无法识别系统。'
    # shellcheck disable=SC1091
    . /etc/os-release
    case ${ID:-}:${VERSION_ID:-} in
        ubuntu:*) dpkg --compare-versions "$VERSION_ID" ge 22.04 || die '需要 Ubuntu 22.04 或更新版本。' ;;
        debian:*) dpkg --compare-versions "$VERSION_ID" ge 12 || die '需要 Debian 12 或更新版本。' ;;
        *) die '本脚本仅支持 Ubuntu 22.04+ / Debian 12+。' ;;
    esac
    case $(uname -m) in
        x86_64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die '只支持 amd64 / arm64。' ;;
    esac
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    unset PASSWORD CONFIRM
    if [[ $UPDATE_SWAPPED == 1 && $COMMITTED != 1 ]]; then
        if [[ -s "$BIN/sing-box.previous" ]]; then
            if mv -f -- "$BIN/sing-box.previous" "$BIN/sing-box"; then
                if [[ $WAS_ACTIVE == 1 ]] && ! { systemctl restart "$SERVICE" >/dev/null 2>&1 && wait_running; }; then
                    say '旧程序文件已恢复，但服务未重新就绪，请检查该服务日志。' >&2
                else
                    say '更新未完成，已恢复旧程序及更新前的运行状态。' >&2
                fi
            else
                say "自动回滚失败，旧程序仍保存在 $BIN/sing-box.previous。" >&2
            fi
        fi
    elif [[ $ACTION == install && $ACTIVATING == 1 && $COMMITTED != 1 ]]; then
        systemctl disable --now "$RENEW_TIMER" "$SERVICE" >/dev/null 2>&1
        systemctl stop "$RENEW_SERVICE" >/dev/null 2>&1
        say '安装未完成，已停止本次服务。专用证书数据保留，可重新运行安装。' >&2
    fi
    if [[ -n "$TMP" && -d "$TMP" ]]; then
        case "$TMP" in /var/tmp/dual-proxy.*) rm -rf --one-file-system -- "$TMP" ;; esac
    fi
    exit "$status"
}
make_tmp() { TMP=$(mktemp -d /var/tmp/dual-proxy.XXXXXXXX); }

prompt_inputs() {
    [[ -r /dev/tty && -w /dev/tty ]] || die '需要交互终端；请下载脚本后用 sudo bash 运行。'
    exec 3<>/dev/tty
    printf '绑定到本机的域名：' >&3
    IFS= read -r DOMAIN <&3 || die '输入已取消。'
    DOMAIN=${DOMAIN,,}
    [[ ${#DOMAIN} -le 253 && "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$ ]] || die '请输入完整域名，不含协议、端口、路径或通配符。'
    printf '账号名/用户标签：' >&3
    IFS= read -r ACCOUNT <&3 || die '输入已取消。'
    [[ -n "$ACCOUNT" && ${#ACCOUNT} -le 64 && ! "$ACCOUNT" =~ [[:cntrl:]] ]] || die '账号名需为 1–64 个字符，不能包含控制字符。'
    printf '两协议共用的密码（不回显）：' >&3
    IFS= read -rs PASSWORD <&3 || die '输入已取消。'
    printf '\n再次输入密码：' >&3
    IFS= read -rs CONFIRM <&3 || die '输入已取消。'
    printf '\n' >&3
    [[ -n "$PASSWORD" && ${#PASSWORD} -le 1024 && ! "$PASSWORD" =~ [[:cntrl:]] ]] || die '密码不能为空或包含控制字符，最多 1024 个字符。'
    [[ "$PASSWORD" == "$CONFIRM" ]] || die '两次密码不一致。'
    unset CONFIRM
    local input
    printf 'Trojan TCP 端口 [443]：' >&3
    IFS= read -r input <&3 || die '输入已取消。'
    TROJAN_PORT=$(parse_port "${input:-443}") || die 'TCP 端口必须是 1–65535。'
    [[ $TROJAN_PORT != 80 ]] || die 'TCP 80 需留给证书验证，请选择其他 Trojan 端口。'
    printf 'Hysteria2 UDP 端口 [%s]：' "$TROJAN_PORT" >&3
    IFS= read -r input <&3 || die '输入已取消。'
    HY2_PORT=$(parse_port "${input:-$TROJAN_PORT}") || die 'UDP 端口必须是 1–65535。'
    exec 3>&-
}
parse_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    local n=$((10#$1))
    ((n >= 1 && n <= 65535)) || return 1
    printf '%s' "$n"
}
install_dependencies() {
    say '安装必要依赖：curl、Python、Certbot、OpenSSL 等。'
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends --no-upgrade \
        ca-certificates curl python3 certbot openssl tar iproute2 util-linux >/dev/null
}
check_ports() {
    [[ -z $(ss -H -ltn "sport = :80") ]] || die 'TCP 80 已被占用；请先安排证书验证端口，不会停止已有网站。'
    [[ -z $(ss -H -ltn "sport = :$TROJAN_PORT") ]] || die "TCP $TROJAN_PORT 已被占用，不会停止已有服务。"
    [[ -z $(ss -H -lun "sport = :$HY2_PORT") ]] || die "UDP $HY2_PORT 已被占用，不会停止已有服务。"
}
check_dns() {
    python3 - "$DOMAIN" <<'PY'
import socket,sys
try:
    addresses=sorted({x[4][0] for x in socket.getaddrinfo(sys.argv[1],80,type=socket.SOCK_STREAM)})
except OSError:
    sys.exit('错误：域名无法解析，请先完成 DNS 绑定。')
if not addresses:sys.exit('错误：域名没有可用地址。')
print('DNS 解析：'+', '.join(addresses))
print('后续 ACME 验证会检查公网可达性；A/AAAA 都应正确指向本机。')
PY
}

release_metadata() {
    local version=$1
    if [[ "$version" == "$INSTALL_VERSION" ]]; then
        VERSION=$INSTALL_VERSION
        URL="https://github.com/SagerNet/sing-box/releases/download/v$VERSION/sing-box-$VERSION-linux-$ARCH.tar.gz"
        case "$ARCH" in
            amd64) DIGEST=a684484d7477d1437282ee411f4d131d0340aaad60a7868841ebd5d87dd8a0c6 ;;
            arm64) DIGEST=b43a1fb1bda131c6653576741ce527eb2bdeab7c9308ca90ee8b972abb7e4a7f ;;
        esac
    else
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 45 \
            -H 'Accept: application/vnd.github+json' https://api.github.com/repos/SagerNet/sing-box/releases/latest > "$TMP/release.json" || die '无法获取官方稳定版信息，现有安装保持不变。'
        python3 - "$TMP/release.json" "$ARCH" > "$TMP/release-fields" <<'PY'
import json,re,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text());tag=d.get('tag_name','')
if d.get('prerelease') or d.get('draft') or not re.fullmatch(r'v\d+\.\d+\.\d+',tag):sys.exit('官方版本格式异常。')
version=tag[1:];name=f'sing-box-{version}-linux-{sys.argv[2]}.tar.gz'
a=next((x for x in d.get('assets',[]) if x.get('name')==name),None)
if not a:sys.exit('官方发布没有所需架构。')
url=f'https://github.com/SagerNet/sing-box/releases/download/{tag}/{name}'
if a.get('browser_download_url')!=url:sys.exit('下载地址不是预期官方地址。')
digest=a.get('digest') or ''
if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest):sys.exit('官方文件缺少SHA256，停止更新。')
print(version);print(url);print(digest.split(':',1)[1])
PY
        mapfile -t fields < "$TMP/release-fields"
        [[ ${#fields[@]} == 3 ]] || die '官方版本元数据不完整。'
        VERSION=${fields[0]}; URL=${fields[1]}; DIGEST=${fields[2]}
    fi
}
download_core() {
    say "下载并校验 sing-box $VERSION（$ARCH）。"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 180 \
        --retry 2 -o "$TMP/core.tar.gz" "$URL" || die '核心下载失败。'
    printf '%s  %s\n' "$DIGEST" "$TMP/core.tar.gz" | sha256sum --check --strict >/dev/null || die 'SHA256 校验失败，文件不会执行。'
    python3 - "$TMP/core.tar.gz" "$TMP/sing-box" "$VERSION" "$ARCH" <<'PY'
import os,sys,tarfile
with tarfile.open(sys.argv[1],'r:gz') as archive:
    member=archive.getmember(f'sing-box-{sys.argv[3]}-linux-{sys.argv[4]}/sing-box')
    if not member.isfile() or member.size>250*1024*1024:sys.exit('异常核心文件。')
    source=archive.extractfile(member)
    with open(sys.argv[2],'wb') as target:
        while block:=source.read(1024*1024):target.write(block)
os.chmod(sys.argv[2],0o755)
PY
    [[ $("$TMP/sing-box" version | head -n 1) == "sing-box version $VERSION" ]] || die '核心版本与官方元数据不一致。'
}
certbot_cmd() {
    "$CERTBOT_BIN" "$@" --config-dir "$STATE/acme" --work-dir "$STATE/acme-work" --logs-dir "$STATE/acme-logs"
}
issue_certificate() {
    say "申请或复用 Let's Encrypt 证书（HTTP-01 / TCP 80）。"
    if ! certbot_cmd certonly --standalone --preferred-challenges http --non-interactive --agree-tos \
        --register-unsafely-without-email --server "$ACME_SERVER" --key-type ecdsa --elliptic-curve secp256r1 \
        --cert-name proxy --keep-until-expiring -d "$DOMAIN" > "$TMP/certbot-output" 2>&1; then
        die "证书申请失败。请检查 A/AAAA、TCP 80 公网可达性及端口占用。诊断日志：$STATE/acme-logs"
    fi
    CERT="$STATE/acme/live/proxy/fullchain.pem"
    KEY="$STATE/acme/live/proxy/privkey.pem"
    openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || die '证书域名不匹配。'
    openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null 2>&1 || die '证书剩余有效期不足。'
    openssl verify -purpose sslserver -verify_hostname "$DOMAIN" -untrusted "$CERT" "$CERT" >/dev/null 2>&1 || die '证书链验证失败。'
    openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER > "$TMP/cert.pub" 2>/dev/null
    openssl pkey -in "$KEY" -pubout -outform DER > "$TMP/key.pub" 2>/dev/null
    cmp -s "$TMP/cert.pub" "$TMP/key.pub" || die '证书与私钥不匹配。'
}
write_config() {
    # Password travels via a pipe, never argv, an exported environment or eval.
    printf '%s\0' "$DOMAIN" "$ACCOUNT" "$PASSWORD" "$TROJAN_PORT" "$HY2_PORT" "$CERT" "$KEY" | \
        python3 -c '
import json,socket,sys
from pathlib import Path
d,u,p,tp,hp,cert,key=sys.stdin.buffer.read().decode("utf-8").split("\0")[:-1]
listen="0.0.0.0"
try:
 s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0);s.bind(("::",0));s.close();listen="::"
except OSError:pass
tls={"enabled":True,"server_name":d,"certificate_path":cert,"key_path":key}
user={"name":u,"password":p}
c={"log":{"level":"warn","timestamp":True},"inbounds":[
 {"type":"trojan","tag":"trojan-in","listen":listen,"listen_port":int(tp),"users":[user],"tls":tls},
 {"type":"hysteria2","tag":"hy2-in","listen":listen,"listen_port":int(hp),"users":[user],"tls":dict(tls,alpn=["h3"]),"ignore_client_bandwidth":True}
],"route":{"rules":[{"action":"sniff","timeout":"1s"}]}}
Path(sys.argv[1]).write_text(json.dumps(c,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
' "$TMP/config.json"
    unset PASSWORD
    "$TMP/sing-box" check -c "$TMP/config.json" >/dev/null 2>&1 || die '生成配置未通过核心校验，未启动服务。'
}
write_units() {
    cat > "$TMP/$SERVICE" <<EOF
$UNIT_MARKER
[Unit]
Description=Personal Trojan and Hysteria2 proxy
Wants=network-online.target
After=network-online.target nss-lookup.target
[Service]
Type=simple
User=root
WorkingDirectory=$APP
ExecStartPre=$BIN/sing-box check -c $APP/config.json
ExecStart=$BIN/sing-box run -c $APP/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
[Install]
WantedBy=multi-user.target
EOF
    cat > "$TMP/$RENEW_SERVICE" <<EOF
$UNIT_MARKER
[Unit]
Description=Renew personal proxy certificate
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
UMask=0077
TimeoutStartSec=10min
ExecStart=$CERTBOT_BIN renew --quiet --config-dir $STATE/acme --work-dir $STATE/acme-work --logs-dir $STATE/acme-logs --deploy-hook $BIN/reload-certificate
EOF
    cat > "$TMP/$RENEW_TIMER" <<EOF
$UNIT_MARKER
[Unit]
Description=Periodic personal proxy certificate check
[Timer]
OnCalendar=*-*-* 04,16:00:00
RandomizedDelaySec=45min
Persistent=true
Unit=$RENEW_SERVICE
[Install]
WantedBy=timers.target
EOF
    cat > "$TMP/reload-certificate" <<EOF
#!/bin/sh
$UNIT_MARKER
set -eu
if $SYSTEMCTL_BIN is-active --quiet $SERVICE; then
    $BIN/sing-box check -c $APP/config.json >/dev/null 2>&1
    $SYSTEMCTL_BIN reload $SERVICE
fi
EOF
}
wait_running() {
    local i pid tcp udp
    for ((i=0; i<20; i++)); do
        if systemctl is-active --quiet "$SERVICE"; then
            pid=$(systemctl show "$SERVICE" -p MainPID --value)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
                tcp=$(ss -H -ltnp "sport = :$TROJAN_PORT")
                udp=$(ss -H -lunp "sport = :$HY2_PORT")
                if [[ "$tcp" == *"pid=$pid,"* && "$udp" == *"pid=$pid,"* ]]; then return 0; fi
            fi
        fi
        sleep 1
    done
    return 1
}
save_state() {
    python3 - "$STATE/install.json" "$DOMAIN" "$ACCOUNT" "$TROJAN_PORT" "$HY2_PORT" "$VERSION" <<'PY'
import datetime,json,os,sys
from pathlib import Path
p=Path(sys.argv[1]);d={"domain":sys.argv[2],"account_label":sys.argv[3],"trojan_port":int(sys.argv[4]),"hysteria2_port":int(sys.argv[5]),"core_version":sys.argv[6],"updated_utc":datetime.datetime.now(datetime.timezone.utc).isoformat()}
t=p.with_suffix('.new');t.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');t.chmod(0o600);os.replace(t,p)
PY
}
load_state() {
    [[ -s "$STATE/install.json" && -s "$APP/config.json" && -x "$BIN/sing-box" ]] || die '安装尚未完成，请先重新运行安装。'
    python3 - "$STATE/install.json" > "$TMP/state-fields" <<'PY'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text());print(d['domain']);print(d['account_label']);print(d['trojan_port']);print(d['hysteria2_port'])
PY
    mapfile -t fields < "$TMP/state-fields"
    [[ ${#fields[@]} == 4 ]] || die '安装记录异常。'
    DOMAIN=${fields[0]};ACCOUNT=${fields[1]};TROJAN_PORT=${fields[2]};HY2_PORT=${fields[3]}
}

do_install() {
    assert_paths
    if owned; then
        assert_units_owned
        [[ ! -f "$STATE/install.json" ]] || die '已经安装。使用 --update 升级；如需重新安装，先执行 --uninstall。'
    else
        local p
        for p in "$APP" "$BIN" "$STATE" "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$RENEW_SERVICE" "$UNIT_DIR/$RENEW_TIMER"; do
            [[ ! -e "$p" && ! -L "$p" ]] || die "目标路径已存在但不属于本脚本：$p"
        done
    fi
    prompt_inputs
    install_dependencies
    check_ports
    check_dns
    install -d -m 0700 "$APP" "$BIN" "$STATE" "$STATE/acme" "$STATE/acme-work" "$STATE/acme-logs"
    printf '%s\n' "$MARKER" > "$STATE/.owner"
    release_metadata "$INSTALL_VERSION"
    download_core
    issue_certificate
    write_config
    write_units
    install -m 0755 "$TMP/sing-box" "$BIN/.next"
    mv -f -- "$BIN/.next" "$BIN/sing-box"
    install -m 0600 "$TMP/config.json" "$APP/.config.new"
    mv -f -- "$APP/.config.new" "$APP/config.json"
    install -m 0755 "$TMP/reload-certificate" "$BIN/reload-certificate"
    local name
    for name in "$SERVICE" "$RENEW_SERVICE" "$RENEW_TIMER"; do install -m 0644 "$TMP/$name" "$UNIT_DIR/$name"; done
    systemd-analyze verify "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$RENEW_SERVICE" "$UNIT_DIR/$RENEW_TIMER" >/dev/null 2>&1 || die 'systemd 服务文件校验失败。'
    systemctl daemon-reload
    ACTIVATING=1
    systemctl enable --now "$SERVICE" "$RENEW_TIMER" >/dev/null
    wait_running || die "服务或监听未正常启动。可查看 journalctl -u $SERVICE。"
    save_state
    COMMITTED=1
    say "安装完成：Trojan TCP $TROJAN_PORT；Hysteria2 UDP $HY2_PORT。"
    say "服务器地址与 TLS/SNI：$DOMAIN"
    say '客户端使用刚才输入的密码；账号名是用户标签，HY2 ALPN 为 h3。'
    say "核心版本：$VERSION；自动续期已启用；未更改 BBR、队列或防火墙。"
    say "状态：systemctl status $SERVICE --no-pager"
}
do_update() {
    require_owned
    load_state
    release_metadata latest
    local current
    current=$("$BIN/sing-box" version | head -n 1)
    if [[ "$current" == "sing-box version $VERSION" ]]; then say "已经是最新稳定版 $VERSION。"; COMMITTED=1; return; fi
    local current_version=${current#sing-box version }
    if [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && dpkg --compare-versions "$current_version" gt "$VERSION"; then
        say "当前版本 $current_version 高于官方最新稳定版 $VERSION，不进行自动降级。"
        COMMITTED=1
        return
    fi
    download_core
    "$TMP/sing-box" check -c "$APP/config.json" >/dev/null 2>&1 || die '新版本不兼容当前配置，旧版本未被替换。'
    if systemctl is-active --quiet "$SERVICE"; then WAS_ACTIVE=1; fi
    cp -p -- "$BIN/sing-box" "$BIN/sing-box.previous"
    install -m 0755 "$TMP/sing-box" "$BIN/.next"
    UPDATE_SWAPPED=1
    mv -f -- "$BIN/.next" "$BIN/sing-box"
    if [[ $WAS_ACTIVE == 1 ]]; then
        systemctl restart "$SERVICE" || die '新版本启动失败，正在恢复旧版本。'
        wait_running || die '新版本监听未正常就绪，正在恢复旧版本。'
    fi
    save_state
    COMMITTED=1
    say "已更新为 sing-box $VERSION，域名、账号密码及端口均保留。"
    [[ $WAS_ACTIVE == 1 ]] || say '服务更新前已停止，更新后仍保持停止。'
}
do_uninstall() {
    if [[ ! -e "$APP" && ! -e "$BIN" && ! -e "$STATE" && ! -e "$UNIT_DIR/$SERVICE" && ! -e "$UNIT_DIR/$RENEW_SERVICE" && ! -e "$UNIT_DIR/$RENEW_TIMER" ]]; then
        say '未发现本脚本的安装，无需删除。'; COMMITTED=1; return
    fi
    require_owned
    say "清理范围：$APP、$BIN、$STATE，以及本脚本的三个 systemd 单元。"
    local name
    for name in "$RENEW_TIMER" "$RENEW_SERVICE" "$SERVICE"; do
        if [[ -f "$UNIT_DIR/$name" ]]; then
            systemctl stop "$name"
            systemctl disable "$name" >/dev/null 2>&1 || true
        fi
    done
    assert_paths
    rm -f -- "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$RENEW_SERVICE" "$UNIT_DIR/$RENEW_TIMER"
    rm -rf --one-file-system -- "$APP" "$BIN" "$STATE"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" "$RENEW_SERVICE" "$RENEW_TIMER" >/dev/null 2>&1 || true
    COMMITTED=1
    say '已删除本脚本的代理服务、配置、账号数据和专用证书数据。'
    say '系统共享软件包、其他代理/证书、SSH、防火墙和网络优化均保留。'
}
main() {
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    case ${1:---install} in
        --install) ACTION=install ;;
        --update) ACTION=update ;;
        --uninstall) ACTION=uninstall ;;
        --help|-h) usage; return ;;
        *) usage >&2; exit 2 ;;
    esac
    check_host
    exec 9>"$LOCK_FILE"
    flock -n 9 || die '已有安装/更新/删除进程在运行。'
    make_tmp
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "$ACTION" in install) do_install ;; update) do_update ;; uninstall) do_uninstall ;; esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
