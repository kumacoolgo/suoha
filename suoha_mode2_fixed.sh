#!/usr/bin/env bash
# suoha mode=2 stable installer
# Xray + Cloudflare Tunnel service mode
# Tested syntax: bash -n
# Usage: bash suoha_mode2_fixed.sh

set -Eeuo pipefail

APP_DIR="/opt/suoha"
XRAY_BIN="$APP_DIR/xray"
CLOUDFLARED_BIN="$APP_DIR/cloudflared"
XRAY_CONFIG="$APP_DIR/xray-config.json"
CF_CONFIG="$APP_DIR/cloudflared-config.yaml"
ENV_FILE="$APP_DIR/suoha.env"
LINK_FILE="$APP_DIR/v2ray.txt"
MANAGER="$APP_DIR/suoha.sh"
MANAGER_LINK="/usr/bin/suoha"

SYSTEMD_XRAY="/etc/systemd/system/suoha-xray.service"
SYSTEMD_CF="/etc/systemd/system/suoha-cloudflared.service"
OPENRC_XRAY="/etc/init.d/suoha-xray"
OPENRC_CF="/etc/init.d/suoha-cloudflared"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

say() { echo -e "$*"; }
ok() { say "${GREEN}$*${NC}"; }
warn() { say "${YELLOW}$*${NC}"; }
die() { say "${RED}错误：$*${NC}" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    die "请使用 root 运行：sudo -i 后再执行脚本"
  fi
}

os_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

is_alpine() {
  [ "$(os_id)" = "alpine" ]
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

install_deps() {
  local id
  id="$(os_id)"

  case "$id" in
    debian|ubuntu)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip ca-certificates
      ;;
    centos|rhel|rocky|almalinux)
      if command -v dnf >/dev/null 2>&1; then
        dnf -y install curl unzip ca-certificates
      else
        yum -y install curl unzip ca-certificates
      fi
      ;;
    fedora)
      dnf -y install curl unzip ca-certificates
      ;;
    alpine)
      apk add --no-cache bash curl unzip ca-certificates openrc
      ;;
    *)
      warn "未识别系统 $id，默认尝试 apt-get 安装依赖"
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip ca-certificates
      ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl 安装失败"
  command -v unzip >/dev/null 2>&1 || die "unzip 安装失败"
}

detect_arch_urls() {
  local arch
  arch="$(uname -m)"

  case "$arch" in
    x86_64|x64|amd64)
      XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
      CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
      ;;
    i386|i686)
      XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip"
      CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
      ;;
    arm64|aarch64|armv8)
      XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
      CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
      ;;
    armv7l)
      XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip"
      CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
      ;;
    *)
      die "当前架构 $arch 没有适配"
      ;;
  esac
}

download_bins() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  detect_arch_urls

  mkdir -p "$APP_DIR"
  say "下载 Xray..."
  curl -fL --retry 3 --connect-timeout 20 "$XRAY_URL" -o "$tmp/xray.zip"
  unzip -q "$tmp/xray.zip" -d "$tmp/xray"

  say "下载 cloudflared..."
  curl -fL --retry 3 --connect-timeout 20 "$CLOUDFLARED_URL" -o "$tmp/cloudflared"

  install -m 0755 "$tmp/xray/xray" "$XRAY_BIN"
  install -m 0755 "$tmp/cloudflared" "$CLOUDFLARED_BIN"

  "$XRAY_BIN" version >/dev/null 2>&1 || die "Xray 二进制不可用"
  "$CLOUDFLARED_BIN" --version >/dev/null 2>&1 || die "cloudflared 二进制不可用"
}

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    die "无法生成 UUID，请安装 uuidgen 或确认 /proc 可用"
  fi
}

urlencode_fragment() {
  # 只处理常见字符，足够用于链接备注
  sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/&/%26/g' -e 's/,/%2C/g'
}

b64_one_line() {
  base64 | tr -d '\n'
}

choose_protocol() {
  read -r -p "请选择 Xray 协议：1.vmess  2.vless  [默认 2]: " PROTOCOL
  PROTOCOL="${PROTOCOL:-2}"
  if [ "$PROTOCOL" != "1" ] && [ "$PROTOCOL" != "2" ]; then
    die "协议只能输入 1 或 2"
  fi
}

choose_ip_version() {
  read -r -p "请选择 Cloudflare 连接 IP 版本：4 或 6 [默认 4]: " EDGE_IP_VERSION
  EDGE_IP_VERSION="${EDGE_IP_VERSION:-4}"
  if [ "$EDGE_IP_VERSION" != "4" ] && [ "$EDGE_IP_VERSION" != "6" ]; then
    die "IP 版本只能输入 4 或 6"
  fi
}

choose_domain() {
  say ""
  say "请输入你已经托管到 Cloudflare 的完整二级域名，例如：xray.example.com"
  read -r -p "域名: " DOMAIN
  DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"
  [ -n "$DOMAIN" ] || die "域名不能为空"
  echo "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' || die "域名格式不正确：$DOMAIN"
}

choose_client_addr() {
  say ""
  say "客户端连接地址 add 建议默认用你的域名。"
  say "如果你以后要用 Cloudflare 优选 IP，可以在客户端里手动把地址改成优选 IP，Host/SNI 保持 $DOMAIN。"
  read -r -p "客户端连接地址 [默认 $DOMAIN]: " CLIENT_ADDR
  CLIENT_ADDR="${CLIENT_ADDR:-$DOMAIN}"
}

make_xray_config() {
  XRAY_UUID="$(new_uuid)"
  WS_ID="$(echo "$XRAY_UUID" | awk -F- '{print $1}')"
  WS_PATH="/$WS_ID"
  XRAY_PORT="$((RANDOM + 10000))"

  if [ "$PROTOCOL" = "1" ]; then
    cat >"$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
  else
    cat >"$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "$XRAY_UUID"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
  fi

  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || die "Xray 配置测试失败：$XRAY_CONFIG"
}

cloudflared_login_if_needed() {
  mkdir -p /root/.cloudflared

  if [ ! -f /root/.cloudflared/cert.pem ]; then
    say ""
    warn "接下来会显示 Cloudflare 授权链接。复制链接到浏览器打开，登录后选择你的域名授权。"
    warn "授权完成后回到终端，脚本会继续往下走。"
    "$CLOUDFLARED_BIN" tunnel login
  else
    ok "检测到 /root/.cloudflared/cert.pem，跳过 Cloudflare 登录"
  fi

  [ -f /root/.cloudflared/cert.pem ] || die "没有找到 /root/.cloudflared/cert.pem，Cloudflare 登录可能失败"
}

create_cloudflare_tunnel() {
  local safe_label create_out json_file
  safe_label="$(echo "$DOMAIN" | awk -F. '{print $1}' | tr -cd 'a-zA-Z0-9-')"
  [ -n "$safe_label" ] || safe_label="suoha"
  TUNNEL_NAME="suoha-${safe_label}-$(date +%s)"

  say "创建 Cloudflare Tunnel：$TUNNEL_NAME"
  set +e
  create_out="$("$CLOUDFLARED_BIN" tunnel create "$TUNNEL_NAME" 2>&1)"
  local rc=$?
  set -e
  echo "$create_out"

  if [ "$rc" != "0" ]; then
    die "cloudflared tunnel create 失败"
  fi

  TUNNEL_UUID="$(echo "$create_out" | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n1 || true)"

  if [ -z "${TUNNEL_UUID:-}" ]; then
    json_file="$(ls -t /root/.cloudflared/*.json 2>/dev/null | head -n1 || true)"
    [ -n "$json_file" ] || die "无法找到 tunnel credentials json"
    TUNNEL_UUID="$(basename "$json_file" .json)"
  fi

  [ -f "/root/.cloudflared/$TUNNEL_UUID.json" ] || die "credentials 文件不存在：/root/.cloudflared/$TUNNEL_UUID.json"

  say "绑定 DNS：$DOMAIN -> $TUNNEL_NAME"
  "$CLOUDFLARED_BIN" tunnel route dns --overwrite-dns "$TUNNEL_UUID" "$DOMAIN"
}

make_cloudflared_config() {
  cat >"$CF_CONFIG" <<EOF
tunnel: $TUNNEL_UUID
credentials-file: /root/.cloudflared/$TUNNEL_UUID.json

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$XRAY_PORT
  - service: http_status:404
EOF

  "$CLOUDFLARED_BIN" tunnel ingress validate "$CF_CONFIG" >/dev/null 2>&1 || die "cloudflared 配置校验失败：$CF_CONFIG"
}

make_env_file() {
  cat >"$ENV_FILE" <<EOF
PROTOCOL="$PROTOCOL"
EDGE_IP_VERSION="$EDGE_IP_VERSION"
DOMAIN="$DOMAIN"
CLIENT_ADDR="$CLIENT_ADDR"
XRAY_UUID="$XRAY_UUID"
WS_PATH="$WS_PATH"
XRAY_PORT="$XRAY_PORT"
TUNNEL_NAME="$TUNNEL_NAME"
TUNNEL_UUID="$TUNNEL_UUID"
EOF
  chmod 600 "$ENV_FILE"
}

make_links() {
  local tag tag_enc ws_path_enc vmess_json
  tag="suoha-${DOMAIN}"
  tag_enc="$(printf '%s' "$tag" | urlencode_fragment)"
  ws_path_enc="%2F$(echo "$WS_PATH" | sed 's#^/##')"

  {
    if [ "$PROTOCOL" = "1" ]; then
      echo "vmess 链接已经生成。"
      echo "说明：add 当前为 $CLIENT_ADDR；如需 Cloudflare 优选 IP，只改客户端里的 add/address，Host/SNI 保持 $DOMAIN。"
      echo

      vmess_json='{"v":"2","ps":"'"${tag}_tls"'","add":"'"$CLIENT_ADDR"'","port":"443","id":"'"$XRAY_UUID"'","aid":"0","scy":"auto","net":"ws","type":"none","host":"'"$DOMAIN"'","path":"'"$WS_PATH"'","tls":"tls","sni":"'"$DOMAIN"'"}'
      echo "vmess://$(printf '%s' "$vmess_json" | b64_one_line)"
      echo
      echo "TLS 端口 443 可改为：2053 2083 2087 2096 8443"
      echo

      vmess_json='{"v":"2","ps":"'"$tag"'","add":"'"$CLIENT_ADDR"'","port":"80","id":"'"$XRAY_UUID"'","aid":"0","scy":"auto","net":"ws","type":"none","host":"'"$DOMAIN"'","path":"'"$WS_PATH"'","tls":""}'
      echo "vmess://$(printf '%s' "$vmess_json" | b64_one_line)"
      echo
      echo "非 TLS 端口 80 可改为：8080 8880 2052 2082 2086 2095"
    else
      echo "vless 链接已经生成。"
      echo "说明：address 当前为 $CLIENT_ADDR；如需 Cloudflare 优选 IP，只改客户端里的 address，Host/SNI 保持 $DOMAIN。"
      echo
      echo "vless://${XRAY_UUID}@${CLIENT_ADDR}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${ws_path_enc}#${tag_enc}_tls"
      echo
      echo "TLS 端口 443 可改为：2053 2083 2087 2096 8443"
      echo
      echo "vless://${XRAY_UUID}@${CLIENT_ADDR}:80?encryption=none&security=none&type=ws&host=${DOMAIN}&path=${ws_path_enc}#${tag_enc}"
      echo
      echo "非 TLS 端口 80 可改为：8080 8880 2052 2082 2086 2095"
    fi

    echo
    echo "如果 80/8080/8880/2052/2082/2086/2095 无法使用，请检查 Cloudflare SSL/TLS -> 边缘证书 -> 始终使用 HTTPS 是否关闭。"
    echo
    echo "本机信息："
    echo "DOMAIN=$DOMAIN"
    echo "UUID=$XRAY_UUID"
    echo "WS_PATH=$WS_PATH"
    echo "LOCAL_PORT=$XRAY_PORT"
    echo "TUNNEL_NAME=$TUNNEL_NAME"
    echo "TUNNEL_UUID=$TUNNEL_UUID"
  } >"$LINK_FILE"

  chmod 600 "$LINK_FILE"
}

stop_old_local_services() {
  if is_alpine; then
    rc-service suoha-cloudflared stop >/dev/null 2>&1 || true
    rc-service suoha-xray stop >/dev/null 2>&1 || true
    rc-update del suoha-cloudflared default >/dev/null 2>&1 || true
    rc-update del suoha-xray default >/dev/null 2>&1 || true
    rm -f "$OPENRC_CF" "$OPENRC_XRAY"
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop suoha-cloudflared.service >/dev/null 2>&1 || true
      systemctl stop suoha-xray.service >/dev/null 2>&1 || true
      systemctl disable suoha-cloudflared.service >/dev/null 2>&1 || true
      systemctl disable suoha-xray.service >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_CF" "$SYSTEMD_XRAY"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
}

install_services_systemd() {
  has_systemd || die "当前系统没有运行 systemd。服务模式需要 systemd，或请用 Alpine/OpenRC。"

  cat >"$SYSTEMD_XRAY" <<EOF
[Unit]
Description=Suoha Xray
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat >"$SYSTEMD_CF" <<EOF
[Unit]
Description=Suoha Cloudflare Tunnel
After=network-online.target suoha-xray.service
Wants=network-online.target
Requires=suoha-xray.service

[Service]
Type=simple
ExecStart=$CLOUDFLARED_BIN --edge-ip-version $EDGE_IP_VERSION --protocol http2 tunnel --config $CF_CONFIG run
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now suoha-xray.service
  systemctl enable --now suoha-cloudflared.service
}

install_services_openrc() {
  command -v rc-update >/dev/null 2>&1 || die "没有 rc-update，OpenRC 不可用"
  command -v rc-service >/dev/null 2>&1 || die "没有 rc-service，OpenRC 不可用"

  # 某些极简 Alpine 容器/小鸡里 OpenRC 已安装但当前会话没有初始化，补一下运行目录。
  mkdir -p /run/openrc
  touch /run/openrc/softlevel

  cat >"$OPENRC_XRAY" <<EOF
#!/sbin/openrc-run
name="suoha-xray"
description="Suoha Xray"
command="$XRAY_BIN"
command_args="run -config $XRAY_CONFIG"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
  need net
}
EOF

  cat >"$OPENRC_CF" <<EOF
#!/sbin/openrc-run
name="suoha-cloudflared"
description="Suoha Cloudflare Tunnel"
command="$CLOUDFLARED_BIN"
command_args="--edge-ip-version $EDGE_IP_VERSION --protocol http2 tunnel --config $CF_CONFIG run"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
  need net
  after suoha-xray
}
EOF

  chmod +x "$OPENRC_XRAY" "$OPENRC_CF"
  rc-update add suoha-xray default
  rc-update add suoha-cloudflared default
  rc-service suoha-xray restart
  rc-service suoha-cloudflared restart
}

make_manager() {
  cat >"$MANAGER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/suoha"
ENV_FILE="$APP_DIR/suoha.env"
LINK_FILE="$APP_DIR/v2ray.txt"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
else
  OS_ID="unknown"
fi

is_alpine() { [ "$OS_ID" = "alpine" ]; }

status_services() {
  if is_alpine; then
    rc-service suoha-xray status || true
    rc-service suoha-cloudflared status || true
  else
    systemctl --no-pager status suoha-xray.service suoha-cloudflared.service || true
  fi
}

start_services() {
  if is_alpine; then
    rc-service suoha-xray start
    rc-service suoha-cloudflared start
  else
    systemctl start suoha-xray.service
    systemctl start suoha-cloudflared.service
  fi
}

stop_services() {
  if is_alpine; then
    rc-service suoha-cloudflared stop || true
    rc-service suoha-xray stop || true
  else
    systemctl stop suoha-cloudflared.service || true
    systemctl stop suoha-xray.service || true
  fi
}

restart_services() {
  stop_services
  start_services
}

uninstall_local() {
  stop_services

  if is_alpine; then
    rc-update del suoha-cloudflared default >/dev/null 2>&1 || true
    rc-update del suoha-xray default >/dev/null 2>&1 || true
    rm -f /etc/init.d/suoha-cloudflared /etc/init.d/suoha-xray
  else
    systemctl disable suoha-cloudflared.service >/dev/null 2>&1 || true
    systemctl disable suoha-xray.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/suoha-cloudflared.service /etc/systemd/system/suoha-xray.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -rf "$APP_DIR" /usr/bin/suoha
  echo "本机服务已卸载。"
  echo "Cloudflare 后台的 Tunnel/DNS 不会自动删除。需要彻底删除请到 Cloudflare Zero Trust / DNS 手动清理。"

  read -r -p "是否同时删除 /root/.cloudflared 授权文件？[y/N]: " ans
  case "$ans" in
    y|Y|yes|YES)
      rm -rf /root/.cloudflared
      echo "已删除 /root/.cloudflared"
      ;;
  esac
}

while true; do
  echo
  echo "====== Suoha 服务管理 ======"
  echo "1. 查看状态"
  echo "2. 启动服务"
  echo "3. 停止服务"
  echo "4. 重启服务"
  echo "5. 查看当前链接"
  echo "6. 查看配置"
  echo "7. 卸载本机服务"
  echo "0. 退出"
  read -r -p "请选择 [默认 1]: " menu
  menu="${menu:-1}"

  case "$menu" in
    1) status_services ;;
    2) start_services ;;
    3) stop_services ;;
    4) restart_services ;;
    5) cat "$LINK_FILE" ;;
    6)
      if [ -f "$ENV_FILE" ]; then
        cat "$ENV_FILE"
      else
        echo "没有找到 $ENV_FILE"
      fi
      ;;
    7) uninstall_local; exit 0 ;;
    0) exit 0 ;;
    *) echo "输入错误" ;;
  esac
done
EOF

  chmod +x "$MANAGER"
  ln -sf "$MANAGER" "$MANAGER_LINK"
}

print_result() {
  say ""
  ok "安装完成。"
  say ""
  say "管理命令："
  say "  suoha"
  say ""
  say "查看链接："
  say "  cat $LINK_FILE"
  say ""
  say "当前生成的链接如下："
  say "----------------------------------------"
  cat "$LINK_FILE"
  say "----------------------------------------"
}

install_mode2() {
  need_root
  install_deps

  if [ -e "$APP_DIR" ] || [ -e "$MANAGER_LINK" ]; then
    warn "检测到旧的 suoha 本机服务文件，将只清理本机服务，不删除 /root/.cloudflared 授权。"
    stop_old_local_services
    rm -rf "$APP_DIR" "$MANAGER_LINK"
  fi

  choose_protocol
  choose_ip_version

  # 先下载 cloudflared，再登录 Cloudflare。这样流程更接近原脚本：先弹登录链接，授权后再填写要绑定的域名。
  download_bins
  cloudflared_login_if_needed

  choose_domain
  choose_client_addr
  make_xray_config
  create_cloudflare_tunnel
  make_cloudflared_config
  make_env_file
  make_links
  make_manager

  if is_alpine; then
    install_services_openrc
  else
    install_services_systemd
  fi

  print_result
}

uninstall_direct() {
  need_root
  if [ -x "$MANAGER" ]; then
    "$MANAGER"
  else
    stop_old_local_services
    rm -rf "$APP_DIR" "$MANAGER_LINK"
    ok "本机服务文件已清理"
  fi
}

main_menu() {
  clear || true
  echo "  _____       __     __          "
  echo " |  __ \\      \\ \\   / /          "
  echo " | |__) |_ _ __\\ \\_/ /   _ _ __  "
  echo " |  ___/ _\` / __\\   / | | | '_ \\ "
  echo " | |  | (_| \\__ \\| || |_| | | | |"
  echo " |_|   \\__,_|___/|_| \\__,_|_| |_|"
  echo
  echo "Suoha 服务模式稳定版：Xray + Cloudflare Tunnel"
  echo
  echo "1. 安装服务模式，等同原脚本 mode=2，推荐"
  echo "2. 管理已安装服务"
  echo "3. 卸载/清理本机服务"
  echo "0. 退出"
  echo
  read -r -p "请选择 [默认 1]: " mode
  mode="${mode:-1}"

  case "$mode" in
    1) install_mode2 ;;
    2)
      if [ -x "$MANAGER" ]; then
        "$MANAGER"
      else
        die "尚未安装服务，请先选择 1"
      fi
      ;;
    3) uninstall_direct ;;
    0) exit 0 ;;
    *) die "输入错误" ;;
  esac
}

main_menu
