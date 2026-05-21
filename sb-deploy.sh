#!/usr/bin/env bash
# ==============================================================
# Sing-box 一键安全部署脚本 M1
# 需求文档：v4.2-final
# 协议：VLESS + Reality + xtls-rprx-vision
# 支持系统：Ubuntu 22.04 / 24.04、Debian 12（amd64 / arm64）
# ==============================================================

set -euo pipefail
IFS=$'\n\t'

# ────────── 脚本版本 ──────────
readonly SCRIPT_VERSION="1.0.0"
# 已测试兼容版本（M1 锁定，不追 latest）
readonly SB_PINNED_VERSION="1.10.6"

# ────────── 目录 & 路径常量 ──────────
readonly INSTALL_DIR="/etc/sb-deploy"
readonly LOG_DIR="/var/log/sb-deploy"
readonly BIN_PATH="/usr/local/bin/sing-box"
readonly SERVICE_FILE="/etc/systemd/system/sing-box.service"

readonly CONFIG_DIR="${INSTALL_DIR}/config"
readonly CRED_DIR="${INSTALL_DIR}/credentials"
readonly STATE_DIR="${INSTALL_DIR}/state"
readonly BACKUP_DIR="${INSTALL_DIR}/backup"
readonly TMP_DIR="${INSTALL_DIR}/tmp"

readonly SERVER_JSON="${CONFIG_DIR}/server.json"
readonly CLIENT_SB_JSON="${CONFIG_DIR}/client-sing-box.json"
readonly CLASH_YAML="${CONFIG_DIR}/clash-mihomo.yaml"
readonly SURGE_CONF="${CONFIG_DIR}/surge.conf"
readonly SR_TXT="${CONFIG_DIR}/shadowrocket.txt"
readonly SUB_TXT="${CONFIG_DIR}/subscription.txt"

readonly VLESS_CRED="${CRED_DIR}/vless.json"
readonly REALITY_CRED="${CRED_DIR}/reality.json"

readonly INSTALL_STATE="${STATE_DIR}/install-state.json"
readonly FW_STATE="${STATE_DIR}/firewall-rules.json"

readonly INSTALL_LOG="${LOG_DIR}/install.log"
readonly ERROR_LOG="${LOG_DIR}/error.log"
readonly AUDIT_LOG="${LOG_DIR}/audit.log"

# ────────── 退出码 ──────────
readonly E_OK=0
readonly E_ROOT=10
readonly E_OS=11
readonly E_ARCH=12
readonly E_SYSTEMD=13
readonly E_DOWNLOAD=20
readonly E_VERIFY=21
readonly E_PORT=30
readonly E_FIREWALL=31
readonly E_CONFIG=40
readonly E_SERVICE=41
readonly E_CLIENT=50
readonly E_UNINSTALL=60

# ────────── 颜色（非 TTY 时静默）──────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ────────── 运行时状态变量 ──────────
SERVER_IP=""
LISTEN_ADDR="::"
LISTEN_PORT=443
SNI=""
UUID_VAL=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
IPV4_ADDR=""
IPV6_ADDR=""
SB_ARCH=""

# ==============================================================
# §0  日志基础设施
# ==============================================================

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  {
  echo -e "${GREEN}[✓]${NC} $*"
  echo "[$(_ts)] INFO  $*" >> "${INSTALL_LOG}" 2>/dev/null || true
}
log_warn()  {
  echo -e "${YELLOW}[!]${NC} $*"
  echo "[$(_ts)] WARN  $*" >> "${INSTALL_LOG}" 2>/dev/null || true
}
log_error() {
  echo -e "${RED}[✗]${NC} $*" >&2
  echo "[$(_ts)] ERROR $*" >> "${ERROR_LOG}" 2>/dev/null || true
}
log_step()  {
  echo -e "\n${BOLD}${BLUE}━━ $* ━━${NC}"
  echo "[$(_ts)] STEP  $*" >> "${INSTALL_LOG}" 2>/dev/null || true
}
log_audit() {
  echo "[$(_ts)] AUDIT $*" >> "${AUDIT_LOG}" 2>/dev/null || true
}

# 脱敏：UUID 前4后4可见
_redact_uuid() {
  local uuid="$1"
  echo "${uuid:0:4}****-****-****-****-****${uuid: -4}"
}

# 日志目录初始化（必须最早调用）
_init_logs() {
  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  chmod 700 "${LOG_DIR}" 2>/dev/null || true
  touch "${INSTALL_LOG}" "${ERROR_LOG}" "${AUDIT_LOG}" 2>/dev/null || true
}

# ==============================================================
# §1  系统前置检查
# ==============================================================

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗]${NC} 当前脚本需要 root 权限。请切换 root 用户或使用 sudo 后重新执行。"
    exit ${E_ROOT}
  fi
}

check_os() {
  log_step "检测操作系统"

  if [[ ! -f /etc/os-release ]]; then
    log_error "无法识别操作系统（缺少 /etc/os-release）"
    exit ${E_OS}
  fi

  # shellcheck source=/dev/null
  source /etc/os-release
  local distro="${ID:-unknown}"
  local ver="${VERSION_ID:-unknown}"

  log_info "发行版：${NAME:-unknown} ${VERSION_ID:-}"

  case "${distro}" in
    ubuntu)
      case "${ver}" in
        22.04|24.04) ;;
        *)
          log_error "不支持的 Ubuntu 版本：${ver}。仅支持 22.04、24.04。"
          exit ${E_OS}
          ;;
      esac
      ;;
    debian)
      case "${ver}" in
        12) ;;
        *)
          log_error "不支持的 Debian 版本：${ver}。仅支持 Debian 12。"
          exit ${E_OS}
          ;;
      esac
      ;;
    *)
      log_error "不支持的操作系统：${distro}。本脚本仅支持 Ubuntu 22.04/24.04 和 Debian 12。"
      exit ${E_OS}
      ;;
  esac

  log_info "操作系统检查通过"
}

check_arch() {
  log_step "检测 CPU 架构"

  local arch
  arch=$(uname -m)
  case "${arch}" in
    x86_64)  SB_ARCH="amd64" ;;
    aarch64) SB_ARCH="arm64" ;;
    *)
      log_error "不支持的 CPU 架构：${arch}。仅支持 x86_64 (amd64) 和 aarch64 (arm64)。"
      exit ${E_ARCH}
      ;;
  esac

  log_info "CPU 架构：${arch}（将下载 ${SB_ARCH} 版本）"
}

check_systemd() {
  log_step "检测 systemd"

  if ! command -v systemctl &>/dev/null; then
    log_error "未检测到 systemd，本脚本仅支持 systemd 系统"
    exit ${E_SYSTEMD}
  fi

  log_info "systemd 检查通过"
}

# ==============================================================
# §2  依赖管理
# ==============================================================

check_and_install_deps() {
  log_step "检测并安装依赖"

  local missing=()
  for cmd in curl tar gzip openssl; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "缺少以下依赖：${missing[*]}，正在安装..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || {
      log_error "依赖安装失败：${missing[*]}"
      exit 1
    }
    log_info "依赖安装完成"
  fi

  # qrencode（可选，缺失时安装，失败时降级）
  if ! command -v qrencode &>/dev/null; then
    log_warn "qrencode 未安装，正在安装（用于生成终端二维码）..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode 2>/dev/null && \
      log_info "qrencode 安装完成" || \
      log_warn "qrencode 安装失败，将跳过二维码输出"
  fi

  log_info "依赖检查通过"
}

# ==============================================================
# §2.5  BBR 拥塞控制优化
# ==============================================================

optimize_bbr() {
  log_step "优化 BBR 拥塞控制"

  if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    log_info "检测到系统已启用 BBR 拥塞控制算法"
    return 0
  fi

  echo -e "${YELLOW}检测到系统未启用 BBR。开启 BBR 可极大提升 5G/移动网络在丢包情况下的连接速度 and 稳定性。${NC}"
  echo -ne "是否自动开启系统的内置 BBR 加速？(建议开启) [Y/n]："
  read -r enable_bbr
  enable_bbr="${enable_bbr:-y}"

  if [[ "${enable_bbr}" =~ ^[Yy]$ ]]; then
    log_info "正在写入配置开启 BBR..."
    if ! grep -q "net.core.default_qdisc" /etc/sysctl.conf; then
      echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
      echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1 || true

    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
      log_info "BBR 加速开启成功！"
    else
      log_warn "开启 BBR 加速失败，请检查系统内核是否支持内置 BBR"
    fi
  else
    log_info "已跳过 BBR 优化"
  fi
}

# ==============================================================
# §3  网络检测
# ==============================================================

detect_ip() {
  log_step "检测公网 IP"

  IPV4_ADDR=$(curl -4 -s --max-time 8 "https://api4.ipify.org" 2>/dev/null || \
              curl -4 -s --max-time 8 "https://ipv4.icanhazip.com" 2>/dev/null || \
              echo "")

  IPV6_ADDR=$(curl -6 -s --max-time 8 "https://api6.ipify.org" 2>/dev/null || \
              curl -6 -s --max-time 8 "https://ipv6.icanhazip.com" 2>/dev/null || \
              echo "")

  if [[ -n "${IPV4_ADDR}" ]]; then
    log_info "公网 IPv4：${IPV4_ADDR}"
  else
    log_warn "未检测到公网 IPv4"
  fi

  if [[ -n "${IPV6_ADDR}" ]]; then
    log_info "公网 IPv6：${IPV6_ADDR}"
  else
    log_warn "未检测到公网 IPv6"
  fi

  if [[ -z "${IPV4_ADDR}" && -z "${IPV6_ADDR}" ]]; then
    log_error "无法检测到任何公网 IP，请检查网络连接后重试"
    exit 1
  fi

  # 确定主 SERVER_IP（VLESS 链接使用）与监听地址
  if [[ -n "${IPV4_ADDR}" ]]; then
    SERVER_IP="${IPV4_ADDR}"
    LISTEN_ADDR="::"      # 双栈或仅 IPv4 均使用 :: 监听（兼容双栈）
    if [[ -z "${IPV6_ADDR}" ]]; then
      # 检测系统是否实际支持 IPv6 监听
      if ! ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        LISTEN_ADDR="0.0.0.0"
        log_info "IPv6 不可用，降级为 0.0.0.0 监听"
      fi
    fi
  else
    # 纯 IPv6 VPS
    SERVER_IP="${IPV6_ADDR}"
    LISTEN_ADDR="::"
    log_info "纯 IPv6 VPS，SERVER_IP 使用 IPv6"
  fi

  log_info "监听地址：${LISTEN_ADDR}"
}

# 检测端口（返回时 LISTEN_PORT 已确定）
check_port() {
  log_step "检测端口可用性"

  local req_port="${1:-443}"

  if _is_port_in_use "${req_port}"; then
    echo ""
    echo -e "${YELLOW}端口 ${req_port} 已被以下进程占用：${NC}"
    ss -tlnp 2>/dev/null | grep ":${req_port}[[:space:]]" || true
    echo ""

    local fallback_ports=(8443 2053 2083)
    echo "推荐备用端口（可用状态）："
    for p in "${fallback_ports[@]}"; do
      if _is_port_in_use "${p}"; then
        echo -e "  ${RED}${p}${NC}  ← 已被占用"
      else
        echo -e "  ${GREEN}${p}${NC}  ← 可用"
      fi
    done
    echo ""

    local new_port=""
    while true; do
      echo -ne "请输入要使用的端口（直接回车使用推荐备用端口 8443）："
      read -r new_port
      new_port="${new_port:-8443}"

      if ! [[ "${new_port}" =~ ^[0-9]+$ ]] || \
         [[ "${new_port}" -lt 1 ]] || [[ "${new_port}" -gt 65535 ]]; then
        echo -e "${YELLOW}无效端口号，请重新输入${NC}"
        continue
      fi

      if _is_port_in_use "${new_port}"; then
        echo -e "${YELLOW}端口 ${new_port} 也被占用，请选择其他端口${NC}"
        continue
      fi

      break
    done

    LISTEN_PORT="${new_port}"
    log_info "将使用备用端口：${LISTEN_PORT}"
  else
    LISTEN_PORT="${req_port}"
    log_info "端口 ${LISTEN_PORT} 可用"
  fi
}

_is_port_in_use() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]" || \
  netstat -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]" || \
  false
}

prompt_cloud_sg_notice() {
  echo ""
  echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│  【提示】云厂商安全组 / 云防火墙                              │${NC}"
  echo -e "${YELLOW}└──────────────────────────────────────────────────────────────┘${NC}"
  echo -e "若你的 VPS 厂商提供云防火墙 / 安全组（如 Oracle、AWS、GCP、"
  echo -e "阿里云、腾讯云等），需自行登录其控制台放行 TCP ${LISTEN_PORT}。"
  echo -e "脚本只能修改 VPS 系统内部防火墙，无法修改云厂商安全组。"
  echo -e "部分厂商默认已放行全部端口，是否需要操作以实际能否连通为准。"
  echo ""
}

# ==============================================================
# §4  SNI 配置与验证
# ==============================================================

_validate_sni() {
  local sni="$1"

  # 不允许空值
  if [[ -z "${sni}" ]]; then
    log_error "SNI 不能为空"
    return 1
  fi

  # 不允许 IP（IPv4 / IPv6）
  if [[ "${sni}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log_error "SNI 不允许填写 IPv4 地址，请填写域名"
    return 1
  fi
  if [[ "${sni}" =~ .*:.* ]]; then
    log_error "SNI 不允许填写 IPv6 地址，请填写域名"
    return 1
  fi

  # 基本域名格式
  if ! [[ "${sni}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    log_error "SNI 格式无效：${sni}"
    return 1
  fi

  # TLS 1.3 可达性检测（§9.3）
  log_info "正在检测 ${sni} 的 TLS 1.3 可达性..."
  if command -v openssl &>/dev/null; then
    local result
    result=$(echo Q | timeout 10 openssl s_client \
      -connect "${sni}:443" \
      -tls1_3 \
      -servername "${sni}" \
      2>/dev/null) || true

    if echo "${result}" | grep -qiE "TLSv1\.3|Protocol\s*:\s*TLSv1\.3"; then
      log_info "${sni} TLS 1.3 握手成功"
    else
      log_error "${sni} 无法完成 TLS 1.3 握手（openssl 检测失败），请更换 SNI"
      return 1
    fi
  else
    log_warn "openssl 不可用，跳过 TLS 1.3 检测（建议手动确认该域名支持 TLS 1.3）"
  fi

  return 0
}

prompt_sni() {
  log_step "配置 Reality SNI"

  echo -e "\n${CYAN}Reality SNI 是 sing-box 用于伪装流量的目标 HTTPS 站点域名。${NC}"
  echo -e "要求：真实可访问的 HTTPS 站点，支持 TLS 1.3，境外大厂为佳。"
  echo -e "推荐：${BOLD}www.apple.com${NC}（默认）、www.microsoft.com、www.cloudflare.com"
  echo ""

  local default_sni="www.apple.com"

  while true; do
    echo -ne "请输入 Reality SNI（直接回车使用默认值 ${BOLD}${default_sni}${NC}）："
    read -r input_sni
    local candidate="${input_sni:-${default_sni}}"

    if _validate_sni "${candidate}"; then
      SNI="${candidate}"
      log_info "SNI 已确定：${SNI}"
      break
    fi

    echo -e "${YELLOW}请重新输入 SNI${NC}"
  done
}

# ==============================================================
# §5  sing-box 下载与安装
# ==============================================================

_get_latest_stable_version() {
  # 从 GitHub Releases API 获取最新非预发布版本
  local latest
  latest=$(curl -s --max-time 15 \
    "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null | \
    grep '"tag_name"' | \
    grep -v '"tag_name": "v.*-\(alpha\|beta\|rc\)' | \
    head -1 | \
    sed 's/.*"v\([^"]*\)".*/\1/') 2>/dev/null || true

  echo "${latest:-${SB_PINNED_VERSION}}"
}

download_singbox() {
  log_step "下载 sing-box"

  local version="${SB_PINNED_VERSION}"
  local filename="sing-box-${version}-linux-${SB_ARCH}"
  local tarball="${filename}.tar.gz"
  local base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"
  local download_url="${base_url}/${tarball}"
  local checksum_url="${base_url}/${tarball}.sha256sum"

  local tmp_tar="${TMP_DIR}/${tarball}"
  local tmp_sum="${TMP_DIR}/${tarball}.sha256sum"

  log_info "版本：v${version}，架构：${SB_ARCH}"
  log_info "下载地址：${download_url}"

  # 下载主文件（失败即退出，不替换旧文件）
  if ! curl -fL --max-time 180 --retry 3 --retry-delay 5 \
       --progress-bar -o "${tmp_tar}" "${download_url}"; then
    log_error "下载失败：${download_url}"
    rm -f "${tmp_tar}"
    exit ${E_DOWNLOAD}
  fi

  # 下载并校验 sha256
  if curl -fL --max-time 30 --retry 2 -s -o "${tmp_sum}" "${checksum_url}" 2>/dev/null; then
    log_info "正在校验文件完整性（sha256）..."
    local expected actual
    expected=$(grep "[[:space:]]${tarball}\$" "${tmp_sum}" 2>/dev/null | awk '{print $1}')
    actual=$(sha256sum "${tmp_tar}" | awk '{print $1}')

    if [[ -z "${expected}" ]]; then
      log_warn "未能从校验文件中提取预期哈希，跳过校验"
    elif [[ "${expected}" != "${actual}" ]]; then
      log_error "文件校验失败（预期：${expected}，实际：${actual}）"
      rm -f "${tmp_tar}" "${tmp_sum}"
      exit ${E_VERIFY}
    else
      log_info "sha256 校验通过"
    fi
  else
    log_warn "无法下载校验文件，跳过 sha256 校验（建议手动核对哈希）"
  fi

  # 备份旧二进制（如已存在）
  if [[ -f "${BIN_PATH}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    cp "${BIN_PATH}" "${BACKUP_DIR}/sing-box.bak"
    log_audit "旧二进制已备份：${BIN_PATH} -> ${BACKUP_DIR}/sing-box.bak"
  fi

  # 解压
  log_info "正在解压安装..."
  tar -xzf "${tmp_tar}" -C "${TMP_DIR}" 2>/dev/null

  # 安装
  install -m 755 "${TMP_DIR}/${filename}/sing-box" "${BIN_PATH}"

  # 验证
  local installed_ver
  installed_ver=$("${BIN_PATH}" version 2>/dev/null | head -1 || echo "unknown")
  log_info "已安装：${installed_ver}"
  log_audit "sing-box v${version}（${SB_ARCH}）安装到 ${BIN_PATH}"

  # 清理临时文件
  rm -rf "${TMP_DIR:?}/${filename}" "${tmp_tar}" "${tmp_sum}"
}

# ==============================================================
# §6  凭据生成与管理
# ==============================================================

generate_credentials() {
  log_step "生成凭据"

  # UUID：优先用 sing-box 官方命令，回退系统随机源
  if command -v "${BIN_PATH}" &>/dev/null; then
    UUID_VAL=$("${BIN_PATH}" generate uuid 2>/dev/null) || \
      UUID_VAL=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
                 python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
  else
    UUID_VAL=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
               python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null)
  fi

  if [[ -z "${UUID_VAL}" ]]; then
    log_error "UUID 生成失败"
    exit ${E_CONFIG}
  fi

  # Reality key pair：使用 sing-box 官方命令
  local kp_output
  kp_output=$("${BIN_PATH}" generate reality-keypair 2>/dev/null)
  PRIVATE_KEY=$(echo "${kp_output}" | awk '/PrivateKey:/{print $2}')
  PUBLIC_KEY=$(echo "${kp_output}" | awk '/PublicKey:/{print $2}')

  if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
    log_error "Reality key pair 生成失败"
    exit ${E_CONFIG}
  fi

  # short_id：8 位安全随机十六进制
  SHORT_ID=$(openssl rand -hex 4)

  # 日志中只记录脱敏值，不记录完整凭据
  log_info "UUID 生成完成：$(_redact_uuid "${UUID_VAL}")"
  log_info "Reality key pair 生成完成：[REDACTED]"
  log_info "short_id 生成完成：[REDACTED]"
  log_audit "凭据生成完成，UUID 前缀：${UUID_VAL:0:4}****"
}

save_credentials() {
  mkdir -p "${CRED_DIR}"
  chmod 700 "${CRED_DIR}"

  cat > "${VLESS_CRED}" <<EOF
{
  "uuid": "${UUID_VAL}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  cat > "${REALITY_CRED}" <<EOF
{
  "private_key": "${PRIVATE_KEY}",
  "public_key": "${PUBLIC_KEY}",
  "short_id": "${SHORT_ID}",
  "sni": "${SNI}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  chmod 600 "${VLESS_CRED}" "${REALITY_CRED}"
  log_info "凭据已安全保存到 ${CRED_DIR}"
}

load_credentials() {
  if [[ ! -f "${VLESS_CRED}" || ! -f "${REALITY_CRED}" ]]; then
    log_error "凭据文件不存在，请重新安装"
    exit 1
  fi

  # 优先使用 jq，回退到 sed
  if command -v jq &>/dev/null; then
    UUID_VAL=$(jq -r '.uuid'        "${VLESS_CRED}")
    PRIVATE_KEY=$(jq -r '.private_key' "${REALITY_CRED}")
    PUBLIC_KEY=$(jq -r '.public_key'   "${REALITY_CRED}")
    SHORT_ID=$(jq -r '.short_id'     "${REALITY_CRED}")
    SNI=$(jq -r '.sni'           "${REALITY_CRED}")
  else
    UUID_VAL=$(sed -n 's/.*"uuid":[[:space:]]*"\([^"]*\)".*/\1/p' "${VLESS_CRED}")
    PRIVATE_KEY=$(sed -n 's/.*"private_key":[[:space:]]*"\([^"]*\)".*/\1/p' "${REALITY_CRED}")
    PUBLIC_KEY=$(sed -n 's/.*"public_key":[[:space:]]*"\([^"]*\)".*/\1/p'   "${REALITY_CRED}")
    SHORT_ID=$(sed -n 's/.*"short_id":[[:space:]]*"\([^"]*\)".*/\1/p'   "${REALITY_CRED}")
    SNI=$(sed -n 's/.*"sni":[[:space:]]*"\([^"]*\)".*/\1/p'         "${REALITY_CRED}")
  fi

  # 从 server.json 读取端口
  if [[ -f "${SERVER_JSON}" ]]; then
    if command -v jq &>/dev/null; then
      LISTEN_PORT=$(jq -r '.inbounds[0].listen_port' "${SERVER_JSON}")
    else
      LISTEN_PORT=$(grep '"listen_port"' "${SERVER_JSON}" | grep -oP '[0-9]+' | head -1)
    fi
  fi

  # 重新检测公网 IP
  IPV4_ADDR=$(curl -4 -s --max-time 8 "https://api4.ipify.org" 2>/dev/null || echo "")
  IPV6_ADDR=$(curl -6 -s --max-time 8 "https://api6.ipify.org" 2>/dev/null || echo "")
  SERVER_IP="${IPV4_ADDR:-${IPV6_ADDR}}"
}

# ==============================================================
# §7  服务端配置生成
# ==============================================================

generate_server_config() {
  log_step "生成服务端配置"

  # 备份现有配置
  if [[ -f "${SERVER_JSON}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    cp "${SERVER_JSON}" "${BACKUP_DIR}/server.json.bak"
    log_audit "服务端配置已备份：${BACKUP_DIR}/server.json.bak"
  fi

  cat > "${SERVER_JSON}" <<EOF
{
  "log": {
    "level": "warn",
    "output": "/var/log/sb-deploy/singbox.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${LISTEN_PORT},
      "users": [
        {
          "uuid": "${UUID_VAL}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF

  chmod 600 "${SERVER_JSON}"
  log_info "服务端配置已写入：${SERVER_JSON}"

  # 配置校验（失败则回滚）
  log_info "执行 sing-box check..."
  if ! "${BIN_PATH}" check -c "${SERVER_JSON}" 2>/dev/null; then
    log_error "sing-box 配置检查失败"
    if [[ -f "${BACKUP_DIR}/server.json.bak" ]]; then
      cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
      log_warn "已回滚到备份配置"
    fi
    exit ${E_CONFIG}
  fi

  log_info "配置校验通过"
}

# ==============================================================
# §8  客户端配置生成
# ==============================================================

# 生成 VLESS 分享链接（IPv6 需加方括号）
_build_vless_link() {
  local addr="${SERVER_IP}"
  # IPv6 地址在 URI 中需加方括号
  if [[ "${addr}" =~ .*:.* ]]; then
    addr="[${addr}]"
  fi
  local tag="SB-${addr}:${LISTEN_PORT}"
  echo "vless://${UUID_VAL}@${addr}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${tag}"
}

generate_client_configs() {
  log_step "生成客户端配置"

  local vless_link
  vless_link=$(_build_vless_link)

  local node_name="SB-Reality-${SERVER_IP}"
  local addr_raw="${SERVER_IP}"

  # Shadowrocket & 订阅文件
  echo "${vless_link}" > "${SR_TXT}"
  echo "${vless_link}" > "${SUB_TXT}"
  chmod 600 "${SR_TXT}" "${SUB_TXT}"

  # ── sing-box 客户端 JSON ──────────────────────────────────
  cat > "${CLIENT_SB_JSON}" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "${addr_raw}",
      "server_port": ${LISTEN_PORT},
      "uuid": "${UUID_VAL}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "final": "vless-out"
  }
}
EOF

  # ── Clash / Mihomo YAML ──────────────────────────────────
  cat > "${CLASH_YAML}" <<EOF
# Clash/Mihomo 配置 - 由 sb-deploy M1 生成
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')

mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: "${node_name}"
    type: vless
    server: ${addr_raw}
    port: ${LISTEN_PORT}
    uuid: ${UUID_VAL}
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - "${node_name}"
      - DIRECT

rules:
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - GEOIP,private,DIRECT
  - MATCH,Proxy
EOF

  # ── Surge 配置 ───────────────────────────────────────────
  cat > "${SURGE_CONF}" <<EOF
# Surge 配置 - 由 sb-deploy M1 生成
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
# 注意：Surge 对 VLESS-Reality 的支持因版本而异，
#       若导入失败请使用 Shadowrocket（小火箭）或 Mihomo。

[General]
loglevel = notify
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, localhost, *.local

[Proxy]
${node_name} = vless, ${addr_raw}, ${LISTEN_PORT}, username=${UUID_VAL}, tls=true, tls13=true, sni=${SNI}, reality=true, reality-public-key=${PUBLIC_KEY}, reality-short-id=${SHORT_ID}, flow=xtls-rprx-vision, skip-cert-verify=false

[Proxy Group]
Proxies = select, ${node_name}, DIRECT

[Rule]
IP-CIDR,10.0.0.0/8,DIRECT
IP-CIDR,172.16.0.0/12,DIRECT
IP-CIDR,192.168.0.0/16,DIRECT
IP-CIDR,127.0.0.0/8,DIRECT
GEOIP,private,DIRECT,no-resolve
FINAL,Proxies
EOF

  chmod 600 "${CLIENT_SB_JSON}" "${CLASH_YAML}" "${SURGE_CONF}"

  log_info "客户端配置已生成："
  log_info "  Clash/Mihomo ：${CLASH_YAML}"
  log_info "  Surge        ：${SURGE_CONF}"
  log_info "  sing-box JSON：${CLIENT_SB_JSON}"
  log_info "  Shadowrocket ：${SR_TXT}"
}

# ==============================================================
# §9  防火墙管理
# ==============================================================

_init_fw_state() {
  if [[ ! -f "${FW_STATE}" ]]; then
    echo '{"rules":[]}' > "${FW_STATE}"
    chmod 600 "${FW_STATE}"
  fi
}

# 将防火墙规则变更追加写入 state 文件
_record_fw_rule() {
  local fw_type="$1" port="$2" proto="$3" command="$4"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if command -v jq &>/dev/null; then
    local tmp="${TMP_DIR}/fw_tmp.json"
    jq --arg t "${fw_type}" \
       --argjson p "${port}" \
       --arg pr "${proto}" \
       --arg c "${command}" \
       --arg ts "${ts}" \
       '.rules += [{"type":$t,"port":$p,"protocol":$pr,"command":$c,"added_at":$ts}]' \
       "${FW_STATE}" > "${tmp}" && mv "${tmp}" "${FW_STATE}"
  else
    # 无 jq 时使用简单字符串追加（仅作兜底）
    local entry="{\"type\":\"${fw_type}\",\"port\":${port},\"protocol\":\"${proto}\",\"command\":\"${command}\",\"added_at\":\"${ts}\"}"
    if grep -q '"rules":\[\]' "${FW_STATE}" 2>/dev/null; then
      sed -i "s|\"rules\":\[\]|\"rules\":[${entry}]|" "${FW_STATE}"
    else
      sed -i "s|\]\}$|,${entry}]}|" "${FW_STATE}"
    fi
  fi

  log_audit "防火墙规则已记录：${fw_type} ${proto}/${port}"
}

configure_firewall() {
  log_step "配置防火墙"
  _init_fw_state

  local port="${LISTEN_PORT}"
  local any_added=false

  # ── UFW ─────────────────────────────────────────────────
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    log_info "检测到 UFW（active），添加 ${port}/tcp 放行规则..."
    if ufw allow "${port}/tcp" comment "sb-deploy" >/dev/null 2>&1; then
      _record_fw_rule "ufw" "${port}" "tcp" "ufw allow ${port}/tcp"
      log_info "UFW：${port}/tcp 已放行"
      any_added=true
    else
      log_warn "UFW 规则添加失败，请手动执行：ufw allow ${port}/tcp"
    fi
  fi

  # ── firewalld ────────────────────────────────────────────
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    local zone
    zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "public")
    log_info "检测到 firewalld（active），添加 ${port}/tcp 到 zone ${zone}..."
    if firewall-cmd --zone="${zone}" --add-port="${port}/tcp" --permanent >/dev/null 2>&1 && \
       firewall-cmd --reload >/dev/null 2>&1; then
      _record_fw_rule "firewalld" "${port}" "tcp" \
        "firewall-cmd --zone=${zone} --add-port=${port}/tcp --permanent"
      log_info "firewalld：${port}/tcp 已放行（zone: ${zone}）"
      any_added=true
    else
      log_warn "firewalld 规则添加失败，请手动放行端口 ${port}/tcp"
    fi
  fi

  # ── iptables（总是执行，确保 ACCEPT 插入到 REJECT/DROP 之前）──────────────
  # Oracle Cloud 等厂商默认存在 REJECT/DROP 兜底规则，-A 追加到末尾会被提前拦截
  if command -v iptables &>/dev/null; then
    local reject_pos rule_line need_add=false
    reject_pos=$(iptables -L INPUT --line-numbers -n 2>/dev/null | \
      awk '/REJECT|DROP/{print $1; exit}')
    rule_line=$(iptables -L INPUT --line-numbers -n 2>/dev/null | \
      awk -v p="${port}" '$0 ~ "dpt:"p && /ACCEPT/{print $1; exit}')

    if [[ -z "${rule_line}" ]]; then
      need_add=true
    elif [[ -n "${reject_pos}" && "${rule_line}" -gt "${reject_pos}" ]]; then
      log_warn "iptables：${port}/tcp 规则位于 REJECT 之后（无效），重新插入..."
      iptables -D INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
      need_add=true
    fi

    if [[ "${need_add}" == true ]]; then
      log_info "检测到 iptables，添加 ${port}/tcp ACCEPT 规则..."
      local insert_ok=false
      if [[ -n "${reject_pos}" ]]; then
        iptables -I INPUT "${reject_pos}" -p tcp --dport "${port}" -j ACCEPT \
          2>/dev/null && insert_ok=true
      else
        iptables -A INPUT -p tcp --dport "${port}" -j ACCEPT \
          2>/dev/null && insert_ok=true
      fi

      if [[ "${insert_ok}" == true ]]; then
        _record_fw_rule "iptables" "${port}" "tcp" \
          "iptables -I INPUT -p tcp --dport ${port} -j ACCEPT"
        log_info "iptables：${port}/tcp 已放行（插入位置：${reject_pos:-末尾}）"
        netfilter-persistent save >/dev/null 2>&1 || \
          iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        any_added=true
      else
        log_warn "iptables 规则添加失败，请手动放行端口 ${port}/tcp"
      fi
    else
      log_info "iptables：${port}/tcp 规则已存在且有效"
      any_added=true
    fi
  fi

  if [[ "${any_added}" == false ]]; then
    log_warn "未检测到已激活的防火墙管理器。若系统使用其他防火墙，请手动放行 TCP ${port}"
  fi
}

_remove_single_fw_rule() {
  local type="$1" port="$2" proto="$3"

  case "${type}" in
    ufw)
      if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "${port}/${proto}"; then
          ufw delete allow "${port}/${proto}" >/dev/null 2>&1 && \
            log_info "UFW 规则已移除：${port}/${proto}" || \
            log_warn "UFW 规则移除失败：${port}/${proto}"
        fi
      fi
      ;;
    firewalld)
      if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        local zone
        zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "public")
        if firewall-cmd --zone="${zone}" --query-port="${port}/${proto}" 2>/dev/null; then
          firewall-cmd --zone="${zone}" --remove-port="${port}/${proto}" --permanent >/dev/null 2>&1 && \
            firewall-cmd --reload >/dev/null 2>&1 && \
            log_info "firewalld 规则已移除：${port}/${proto}" || \
            log_warn "firewalld 规则移除失败：${port}/${proto}"
        fi
      fi
      ;;
    iptables)
      if command -v iptables &>/dev/null; then
        if iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null; then
          iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null && \
            log_info "iptables 规则已移除：${port}/${proto}" || \
            log_warn "iptables 规则移除失败：${port}/${proto}"
        fi
      fi
      ;;
  esac
}

remove_firewall_rules() {
  log_step "回收防火墙规则"

  if [[ ! -f "${FW_STATE}" ]]; then
    log_info "未找到防火墙规则记录，跳过"
    return 0
  fi

  if command -v jq &>/dev/null; then
    local count
    count=$(jq '.rules | length' "${FW_STATE}" 2>/dev/null || echo 0)
    log_info "共有 ${count} 条规则记录"

    for i in $(seq 0 $((count - 1))); do
      local t p pr
      t=$(jq -r ".rules[${i}].type"     "${FW_STATE}")
      p=$(jq -r ".rules[${i}].port"     "${FW_STATE}")
      pr=$(jq -r ".rules[${i}].protocol" "${FW_STATE}")
      _remove_single_fw_rule "${t}" "${p}" "${pr}"
    done
  else
    log_warn "jq 不可用，尝试简单回收防火墙规则..."
    local ports
    ports=$(grep -oP '"port":[[:space:]]*\K[0-9]+' "${FW_STATE}" 2>/dev/null || true)
    for p in ${ports}; do
      command -v ufw &>/dev/null && ufw delete allow "${p}/tcp" 2>/dev/null || true
      if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
      fi
    done
  fi
}

# ==============================================================
# §10  systemd 服务
# ==============================================================

create_systemd_service() {
  log_step "创建 systemd 服务"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=sing-box proxy service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStartPre=${BIN_PATH} check -c ${SERVER_JSON}
ExecStart=${BIN_PATH} run -c ${SERVER_JSON}
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1
  log_info "systemd 服务已创建：${SERVICE_FILE}"
  log_info "已设置开机自启"
}

start_and_verify_service() {
  log_step "启动 sing-box"

  if ! systemctl start sing-box 2>/dev/null; then
    log_error "sing-box 启动命令失败"
    _rollback_on_service_fail
    exit ${E_SERVICE}
  fi

  sleep 2

  if systemctl is-active --quiet sing-box; then
    log_info "sing-box 服务启动成功"
  else
    log_error "sing-box 启动后立即退出，请检查配置"
    systemctl status sing-box --no-pager 2>/dev/null | head -20 || true
    _rollback_on_service_fail
    exit ${E_SERVICE}
  fi
}

_rollback_on_service_fail() {
  if [[ -f "${BACKUP_DIR}/server.json.bak" ]]; then
    log_warn "正在回滚到备份配置..."
    cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
    systemctl restart sing-box 2>/dev/null || true
    if systemctl is-active --quiet sing-box; then
      log_warn "已回滚，旧配置服务恢复运行"
    fi
  fi
}

# ==============================================================
# §11  输出 & 二维码
# ==============================================================

show_qrcode() {
  local link="$1"
  echo ""
  echo -e "${CYAN}━━ 二维码（手机扫码导入）━━${NC}"
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "${link}" 2>/dev/null || \
      echo -e "${YELLOW}二维码生成失败，请手动复制上方链接导入${NC}"
  else
    echo -e "${YELLOW}qrencode 未安装，无法显示二维码。请手动复制链接导入：${NC}"
  fi
  echo ""
}

check_service_status_brief() {
  echo ""
  echo -e "${BOLD}服务状态：${NC}"
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    echo -e "  sing-box 服务 ：${GREEN}运行中${NC}"
  else
    echo -e "  sing-box 服务 ：${RED}未运行${NC}"
  fi
  echo -e "  监听端口     ：TCP ${LISTEN_PORT}"
  if _is_port_in_use "${LISTEN_PORT}"; then
    echo -e "  端口状态     ：${GREEN}监听中${NC}"
  else
    echo -e "  端口状态     ：${YELLOW}未检测到（可能需要稍等片刻或检查配置）${NC}"
  fi
  echo ""
}

print_install_summary() {
  local vless_link
  vless_link=$(_build_vless_link)

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║           sing-box M1 安装完成！                             ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  check_service_status_brief

  echo -e "${BOLD}节点信息：${NC}"
  echo -e "  服务器 IP  ：${SERVER_IP}"
  echo -e "  端口        ：${LISTEN_PORT}"
  echo -e "  协议        ：VLESS + Reality + xtls-rprx-vision"
  echo -e "  SNI         ：${SNI}"
  echo ""

  echo -e "${BOLD}VLESS 分享链接（Shadowrocket 可直接扫码或复制导入）：${NC}"
  echo ""
  echo -e "${CYAN}${vless_link}${NC}"
  echo ""

  show_qrcode "${vless_link}"

  echo -e "${BOLD}配置文件路径：${NC}"
  echo -e "  服务端配置       ：${SERVER_JSON}"
  echo -e "  Clash/Mihomo     ：${CLASH_YAML}"
  echo -e "  Surge            ：${SURGE_CONF}"
  echo -e "  sing-box 客户端  ：${CLIENT_SB_JSON}"
  echo -e "  Shadowrocket 链接：${SR_TXT}"
  echo ""

  echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│  【重要】云厂商安全组 / 云防火墙                              │${NC}"
  echo -e "${YELLOW}└──────────────────────────────────────────────────────────────┘${NC}"
  echo -e "若你的 VPS 厂商提供云防火墙 / 安全组（如 Oracle、AWS、GCP、"
  echo -e "阿里云、腾讯云等），需自行登录其控制台放行 TCP ${LISTEN_PORT}。"
  echo -e "脚本只能修改 VPS 系统内部防火墙，无法修改云厂商安全组。"
  echo ""

  echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│  【M1 运行权限说明（已知风险）】                              │${NC}"
  echo -e "${YELLOW}└──────────────────────────────────────────────────────────────┘${NC}"
  echo -e "M1 阶段 sing-box 以 root 用户运行。该设计用于降低首版实现复杂度，"
  echo -e "后续 M2 将改为专用系统用户运行，并通过 CAP_NET_BIND_SERVICE 绑定低位端口。"
  echo ""

  echo -e "再次运行本脚本即可进入管理菜单。"
  echo ""
}

# ==============================================================
# §12  安装状态
# ==============================================================

is_installed() {
  [[ -f "${BIN_PATH}" ]] &&
  [[ -f "${SERVER_JSON}" ]] &&
  [[ -f "${VLESS_CRED}" ]] &&
  [[ -f "${REALITY_CRED}" ]]
}

save_install_state() {
  local sb_ver
  sb_ver=$("${BIN_PATH}" version 2>/dev/null | grep -oP 'sing-box version \K[\d.]+' || echo "${SB_PINNED_VERSION}")

  cat > "${INSTALL_STATE}" <<EOF
{
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "script_version": "${SCRIPT_VERSION}",
  "singbox_version": "${sb_ver}",
  "port": ${LISTEN_PORT},
  "sni": "${SNI}",
  "server_ip": "${SERVER_IP}",
  "arch": "${SB_ARCH}"
}
EOF
  chmod 600 "${INSTALL_STATE}"
}

# ==============================================================
# §13  目录初始化
# ==============================================================

init_dirs() {
  mkdir -p "${CONFIG_DIR}" "${CRED_DIR}" "${STATE_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"
  chmod 700 "${INSTALL_DIR}" "${CONFIG_DIR}" "${CRED_DIR}" "${STATE_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"
  mkdir -p "${LOG_DIR}"
  chmod 700 "${LOG_DIR}"
}

# ==============================================================
# §14  管理菜单：各功能实现
# ==============================================================

menu_view_link() {
  load_credentials
  local vless_link
  vless_link=$(_build_vless_link)

  echo ""
  echo -e "${BOLD}VLESS 节点链接：${NC}"
  echo ""
  echo -e "${CYAN}${vless_link}${NC}"
  echo ""
  show_qrcode "${vless_link}"

  echo -e "${BOLD}多行配置文件路径（可整段打印后手动复制）：${NC}"
  echo -e "  Clash/Mihomo     ：${CLASH_YAML}"
  echo -e "  Surge            ：${SURGE_CONF}"
  echo -e "  sing-box 客户端  ：${CLIENT_SB_JSON}"
  echo -e "  Shadowrocket 链接：${SR_TXT}"
  echo ""
}

menu_show_qr() {
  load_credentials
  local vless_link
  vless_link=$(_build_vless_link)
  show_qrcode "${vless_link}"
}

menu_export_shadowrocket() {
  load_credentials
  local vless_link
  vless_link=$(_build_vless_link)
  echo ""
  echo -e "${BOLD}Shadowrocket 链接：${NC}"
  echo ""
  echo -e "${CYAN}${vless_link}${NC}"
  echo ""
  show_qrcode "${vless_link}"
}

menu_export_clash() {
  echo ""
  echo -e "${BOLD}Clash/Mihomo 配置（整段内容 → 手动复制）：${NC}"
  echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"
  cat "${CLASH_YAML}"
  echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"
  echo ""
  echo -e "文件路径：${CLASH_YAML}"
}

menu_export_surge() {
  echo ""
  echo -e "${BOLD}Surge 配置（整段内容 → 手动复制）：${NC}"
  echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"
  cat "${SURGE_CONF}"
  echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"
  echo ""
  echo -e "${YELLOW}注意：Surge 对 VLESS-Reality 的支持因版本而异，若导入失败请改用 Shadowrocket 或 Mihomo。${NC}"
  echo -e "文件路径：${SURGE_CONF}"
}

menu_export_singbox_client() {
  echo ""
  echo -e "${BOLD}sing-box 客户端 JSON（整段内容 → 手动复制）：${NC}"
  echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"
  cat "${CLIENT_SB_JSON}"
  echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"
  echo ""
  echo -e "文件路径：${CLIENT_SB_JSON}"
}

menu_service_status() {
  echo ""
  echo -e "${BOLD}systemctl status sing-box：${NC}"
  systemctl status sing-box --no-pager 2>/dev/null || true
  load_credentials 2>/dev/null || true
  check_service_status_brief
}

menu_restart_service() {
  log_step "重启 sing-box"

  if systemctl restart sing-box 2>/dev/null; then
    sleep 2
    if systemctl is-active --quiet sing-box; then
      log_info "sing-box 已成功重启"
    else
      log_error "sing-box 重启后未能正常运行，请检查日志"
    fi
  else
    log_error "sing-box 重启命令失败"
  fi
}

menu_view_logs() {
  echo ""
  echo -e "${BOLD}安装日志（最近 50 行）：${NC}"
  tail -50 "${INSTALL_LOG}" 2>/dev/null || echo "（日志文件不存在）"
  echo ""
  echo -e "${BOLD}sing-box 运行日志（journalctl，最近 30 行）：${NC}"
  journalctl -u sing-box -n 30 --no-pager 2>/dev/null || \
    tail -30 "/var/log/sb-deploy/singbox.log" 2>/dev/null || \
    echo "（暂无运行日志）"
}

menu_update_singbox() {
  log_step "更新 sing-box"

  local current_ver
  current_ver=$("${BIN_PATH}" version 2>/dev/null | \
    grep -oP 'sing-box version \K[\d.]+' || echo "未知")
  log_info "当前版本：v${current_ver}"

  log_info "正在检查 GitHub 最新稳定版本..."
  local latest_ver
  latest_ver=$(_get_latest_stable_version)
  log_info "最新稳定版本：v${latest_ver}"

  if [[ "${current_ver}" == "${latest_ver}" ]]; then
    log_info "已是最新稳定版本（v${latest_ver}），无需更新"
    return 0
  fi

  echo ""
  echo -e "  当前版本：v${current_ver}"
  echo -e "  可更新到：v${latest_ver}（已测试稳定版）"
  echo ""
  echo -ne "确认更新到 v${latest_ver}？[y/N]："
  read -r confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "已取消更新"; return 0; }

  # 备份
  local arch="${SB_ARCH}"
  if [[ -z "${arch}" ]]; then
    arch=$(uname -m)
    [[ "${arch}" == "x86_64" ]] && arch="amd64" || arch="arm64"
  fi

  mkdir -p "${BACKUP_DIR}"
  [[ -f "${BIN_PATH}" ]] && cp "${BIN_PATH}" "${BACKUP_DIR}/sing-box.bak"
  [[ -f "${SERVER_JSON}" ]] && cp "${SERVER_JSON}" "${BACKUP_DIR}/server.json.bak"
  log_audit "更新前备份完成"

  # 下载新版
  local filename="sing-box-${latest_ver}-linux-${arch}"
  local tarball="${filename}.tar.gz"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/${tarball}"
  local tmp_tar="${TMP_DIR}/${tarball}"

  mkdir -p "${TMP_DIR}"
  if ! curl -fL --max-time 180 --retry 3 --progress-bar -o "${tmp_tar}" "${url}"; then
    log_error "下载新版本失败，更新中止"
    return ${E_DOWNLOAD}
  fi

  tar -xzf "${tmp_tar}" -C "${TMP_DIR}"
  local new_bin="${TMP_DIR}/${filename}/sing-box"
  chmod +x "${new_bin}"

  # 配置兼容性检查（新版二进制 check 旧配置）
  log_info "检查新版本与当前配置的兼容性..."
  if ! "${new_bin}" check -c "${SERVER_JSON}" 2>/dev/null; then
    log_error "新版本（v${latest_ver}）与当前配置不兼容，更新中止，旧版本保留"
    rm -rf "${TMP_DIR:?}/${filename}" "${tmp_tar}"
    return ${E_CONFIG}
  fi

  # 替换二进制
  systemctl stop sing-box 2>/dev/null || true
  install -m 755 "${new_bin}" "${BIN_PATH}"
  systemctl start sing-box 2>/dev/null
  sleep 2

  if systemctl is-active --quiet sing-box; then
    log_info "更新成功！当前版本：$("${BIN_PATH}" version 2>/dev/null | head -1)"
    log_audit "sing-box 更新到 v${latest_ver}"
  else
    log_error "更新后服务未正常启动，正在回滚..."
    [[ -f "${BACKUP_DIR}/sing-box.bak" ]] && install -m 755 "${BACKUP_DIR}/sing-box.bak" "${BIN_PATH}"
    [[ -f "${BACKUP_DIR}/server.json.bak" ]] && cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
    systemctl start sing-box 2>/dev/null || true
    log_warn "已回滚到旧版本 v${current_ver}"
  fi

  rm -rf "${TMP_DIR:?}/${filename}" "${tmp_tar}" 2>/dev/null || true
}

menu_change_port() {
  load_credentials
  log_step "修改监听端口"

  echo -e "当前端口：${LISTEN_PORT}"
  echo ""
  echo -ne "请输入新端口（推荐：443、8443、2053、2083，回车取消）："
  read -r new_port
  [[ -z "${new_port}" ]] && { echo "已取消"; return 0; }

  if ! [[ "${new_port}" =~ ^[0-9]+$ ]] || \
     [[ "${new_port}" -lt 1 ]] || [[ "${new_port}" -gt 65535 ]]; then
    log_error "无效端口号：${new_port}"
    return 1
  fi

  [[ "${new_port}" == "${LISTEN_PORT}" ]] && { log_info "端口未改变"; return 0; }

  if _is_port_in_use "${new_port}"; then
    log_error "端口 ${new_port} 已被占用，请选择其他端口"
    return 1
  fi

  # 备份
  mkdir -p "${BACKUP_DIR}"
  cp "${SERVER_JSON}" "${BACKUP_DIR}/server.json.bak"

  # 修改 server.json（listen_port）
  local old_port="${LISTEN_PORT}"
  if command -v jq &>/dev/null; then
    jq --argjson p "${new_port}" '.inbounds[0].listen_port = $p' \
      "${SERVER_JSON}" > "${SERVER_JSON}.tmp" && mv "${SERVER_JSON}.tmp" "${SERVER_JSON}"
  else
    sed -i "s/\"listen_port\":[[:space:]]*${old_port}/\"listen_port\": ${new_port}/" "${SERVER_JSON}"
  fi

  if ! "${BIN_PATH}" check -c "${SERVER_JSON}" 2>/dev/null; then
    log_error "配置检查失败，回滚端口修改"
    cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
    return ${E_CONFIG}
  fi

  LISTEN_PORT="${new_port}"

  # 更新防火墙：先移除旧端口，再添加新端口
  _remove_single_fw_rule "ufw"      "${old_port}" "tcp" 2>/dev/null || true
  _remove_single_fw_rule "firewalld" "${old_port}" "tcp" 2>/dev/null || true
  _remove_single_fw_rule "iptables"  "${old_port}" "tcp" 2>/dev/null || true
  configure_firewall

  # 重新生成客户端配置
  IPV4_ADDR=$(curl -4 -s --max-time 8 "https://api4.ipify.org" 2>/dev/null || echo "")
  IPV6_ADDR=$(curl -6 -s --max-time 8 "https://api6.ipify.org" 2>/dev/null || echo "")
  SERVER_IP="${IPV4_ADDR:-${IPV6_ADDR}}"
  generate_client_configs

  # 重启服务
  systemctl restart sing-box 2>/dev/null
  sleep 2

  if systemctl is-active --quiet sing-box; then
    log_info "端口已修改为 ${new_port}，服务已重启"
    log_audit "监听端口从 ${old_port} 修改为 ${new_port}"
  else
    log_error "服务重启失败，正在回滚..."
    cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
    LISTEN_PORT="${old_port}"
    systemctl restart sing-box 2>/dev/null || true
    return ${E_SERVICE}
  fi

  echo ""
  echo -e "${YELLOW}请同步修改云厂商安全组的端口规则（${old_port} → ${new_port}）！${NC}"
  menu_view_link
}

menu_change_sni() {
  load_credentials
  log_step "修改 Reality SNI"

  echo -e "当前 SNI：${SNI}"
  echo ""

  local new_sni=""
  while true; do
    echo -ne "请输入新 SNI（回车取消）："
    read -r new_sni
    [[ -z "${new_sni}" ]] && { echo "已取消"; return 0; }
    [[ "${new_sni}" == "${SNI}" ]] && { log_info "SNI 未改变"; return 0; }

    if _validate_sni "${new_sni}"; then
      break
    fi
  done

  # 备份
  mkdir -p "${BACKUP_DIR}"
  cp "${SERVER_JSON}" "${BACKUP_DIR}/server.json.bak"
  cp "${REALITY_CRED}" "${BACKUP_DIR}/reality.json.bak"

  local old_sni="${SNI}"
  SNI="${new_sni}"

  # 修改 server.json
  if command -v jq &>/dev/null; then
    jq --arg sni "${SNI}" \
       '.inbounds[0].tls.server_name = $sni |
        .inbounds[0].tls.reality.handshake.server = $sni' \
       "${SERVER_JSON}" > "${SERVER_JSON}.tmp" && mv "${SERVER_JSON}.tmp" "${SERVER_JSON}"
  else
    log_error "修改 SNI 需要 jq，请先安装：apt install -y jq"
    cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
    SNI="${old_sni}"
    return 1
  fi

  if ! "${BIN_PATH}" check -c "${SERVER_JSON}" 2>/dev/null; then
    log_error "配置检查失败，回滚 SNI 修改"
    cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
    cp "${BACKUP_DIR}/reality.json.bak" "${REALITY_CRED}"
    SNI="${old_sni}"
    return ${E_CONFIG}
  fi

  # 更新凭据文件
  jq --arg sni "${SNI}" '.sni = $sni' "${REALITY_CRED}" > "${REALITY_CRED}.tmp" && \
    mv "${REALITY_CRED}.tmp" "${REALITY_CRED}"

  # 重新生成客户端配置
  SERVER_IP="${IPV4_ADDR:-${IPV6_ADDR:-$(curl -s --max-time 8 https://api4.ipify.org 2>/dev/null || echo "")}}"
  generate_client_configs

  systemctl restart sing-box 2>/dev/null
  sleep 2

  if systemctl is-active --quiet sing-box; then
    log_info "SNI 已修改为：${SNI}，服务已重启"
    log_audit "SNI 从 ${old_sni} 修改为 ${SNI}"
  else
    log_error "服务重启失败，正在回滚..."
    cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}"
    cp "${BACKUP_DIR}/reality.json.bak" "${REALITY_CRED}"
    SNI="${old_sni}"
    systemctl restart sing-box 2>/dev/null || true
    return ${E_SERVICE}
  fi

  menu_view_link
}

menu_regen_client_configs() {
  load_credentials
  log_step "重新生成客户端配置"

  IPV4_ADDR=$(curl -4 -s --max-time 8 "https://api4.ipify.org" 2>/dev/null || echo "")
  IPV6_ADDR=$(curl -6 -s --max-time 8 "https://api6.ipify.org" 2>/dev/null || echo "")
  SERVER_IP="${IPV4_ADDR:-${IPV6_ADDR}}"

  generate_client_configs
  log_info "客户端配置已重新生成"
  menu_view_link
}

menu_regen_credentials() {
  load_credentials
  log_step "重新生成全部凭据"

  echo -e "${RED}${BOLD}警告：重新生成凭据后，所有旧客户端链接将全部失效！${NC}"
  echo -ne "是否继续？[y/N]："
  read -r confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }

  # 停止服务
  systemctl stop sing-box 2>/dev/null || true

  # 备份
  mkdir -p "${BACKUP_DIR}"
  cp "${VLESS_CRED}" "${BACKUP_DIR}/vless.json.bak" 2>/dev/null || true
  cp "${REALITY_CRED}" "${BACKUP_DIR}/reality.json.bak" 2>/dev/null || true
  cp "${SERVER_JSON}" "${BACKUP_DIR}/server.json.bak" 2>/dev/null || true

  # 重新生成
  generate_credentials
  save_credentials
  generate_server_config

  IPV4_ADDR=$(curl -4 -s --max-time 8 "https://api4.ipify.org" 2>/dev/null || echo "")
  IPV6_ADDR=$(curl -6 -s --max-time 8 "https://api6.ipify.org" 2>/dev/null || echo "")
  SERVER_IP="${IPV4_ADDR:-${IPV6_ADDR}}"
  generate_client_configs

  systemctl start sing-box 2>/dev/null
  sleep 2

  if systemctl is-active --quiet sing-box; then
    log_info "凭据已全部重新生成，服务已重启"
    log_audit "全部凭据重新生成"
  else
    log_error "服务重启失败，正在回滚到旧凭据..."
    cp "${BACKUP_DIR}/vless.json.bak" "${VLESS_CRED}" 2>/dev/null || true
    cp "${BACKUP_DIR}/reality.json.bak" "${REALITY_CRED}" 2>/dev/null || true
    cp "${BACKUP_DIR}/server.json.bak" "${SERVER_JSON}" 2>/dev/null || true
    systemctl start sing-box 2>/dev/null || true
    log_warn "已回滚，旧凭据恢复"
    return ${E_SERVICE}
  fi

  menu_view_link
}

menu_backup() {
  log_step "备份当前配置"

  local ts
  ts=$(date '+%Y%m%d_%H%M%S')
  local backup_dir="${BACKUP_DIR}/snapshot_${ts}"
  mkdir -p "${backup_dir}"
  chmod 700 "${backup_dir}"

  local files_to_backup=(
    "${SERVER_JSON}" "${CLIENT_SB_JSON}" "${CLASH_YAML}"
    "${SURGE_CONF}" "${SR_TXT}" "${VLESS_CRED}" "${REALITY_CRED}"
  )

  for f in "${files_to_backup[@]}"; do
    [[ -f "${f}" ]] && cp "${f}" "${backup_dir}/" 2>/dev/null || true
  done

  chmod 600 "${backup_dir}"/* 2>/dev/null || true
  log_info "备份已保存到：${backup_dir}"
  log_audit "手动备份快照创建：${backup_dir}"
}

menu_restore_backup() {
  log_step "恢复上一个备份"

  local latest_snapshot
  latest_snapshot=$(ls -dt "${BACKUP_DIR}"/snapshot_* 2>/dev/null | head -1)

  if [[ -z "${latest_snapshot}" ]]; then
    log_error "未找到备份快照（${BACKUP_DIR}/snapshot_* 不存在，请先使用菜单 15 创建备份）"
    return 1
  fi

  echo -e "将恢复的备份：$(basename "${latest_snapshot}")"
  echo -ne "确认恢复？当前配置将被覆盖。[y/N]："
  read -r confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }

  systemctl stop sing-box 2>/dev/null || true

  [[ -f "${latest_snapshot}/server.json" ]]  && cp "${latest_snapshot}/server.json"  "${SERVER_JSON}"  2>/dev/null || true
  [[ -f "${latest_snapshot}/vless.json" ]]   && cp "${latest_snapshot}/vless.json"   "${VLESS_CRED}"   2>/dev/null || true
  [[ -f "${latest_snapshot}/reality.json" ]] && cp "${latest_snapshot}/reality.json" "${REALITY_CRED}" 2>/dev/null || true

  if ! "${BIN_PATH}" check -c "${SERVER_JSON}" 2>/dev/null; then
    log_error "备份配置校验失败，请手动检查 ${SERVER_JSON}"
    return ${E_CONFIG}
  fi

  systemctl start sing-box 2>/dev/null
  sleep 2

  if systemctl is-active --quiet sing-box; then
    log_info "备份已恢复（$(basename "${latest_snapshot}")），服务已重启"
    log_audit "从备份快照恢复配置：${latest_snapshot}"
  else
    log_error "恢复后服务未能启动，请检查日志"
    return ${E_SERVICE}
  fi
}

# ==============================================================
# §15  卸载
# ==============================================================

do_uninstall() {
  log_step "完全卸载 sing-box"

  echo ""
  echo -e "${RED}${BOLD}警告：将永久删除 sing-box 及本脚本创建的所有文件！${NC}"
  echo -e "将删除：${BIN_PATH}、${INSTALL_DIR}/、${LOG_DIR}/、${SERVICE_FILE}"
  echo -e "${GREEN}将保留：用户网站、系统 DNS、系统软件源、用户已有防火墙规则、云厂商安全组${NC}"
  echo ""
  echo -ne "确认卸载？[y/N]："
  read -r confirm

  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "已取消卸载"; return 0; }

  # 停止并禁用服务
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true

  # 回收防火墙规则（仅删除 state 文件中记录的规则）
  [[ -f "${FW_STATE}" ]] && remove_firewall_rules || true

  # 删除文件
  rm -f "${BIN_PATH}" 2>/dev/null || log_warn "删除 ${BIN_PATH} 失败"
  rm -f "${SERVICE_FILE}" 2>/dev/null || log_warn "删除 ${SERVICE_FILE} 失败"
  rm -f /usr/local/bin/sb 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  rm -rf "${INSTALL_DIR}" 2>/dev/null || log_warn "删除 ${INSTALL_DIR} 失败"
  rm -rf "${LOG_DIR}" 2>/dev/null || log_warn "删除 ${LOG_DIR} 失败"

  echo ""
  echo -e "${GREEN}${BOLD}sing-box 已卸载。${NC}"
  echo -e "本脚本创建的配置、日志、服务文件已删除。"
  echo -e "${YELLOW}请注意：云厂商控制台的安全组规则（若有）需要你手动删除。${NC}"
  echo ""

  log_audit "sing-box 已完全卸载"
}

# ==============================================================
# §16  管理菜单主界面
# ==============================================================

_menu_header() {
  load_credentials 2>/dev/null || true

  local svc_status
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    svc_status="${GREEN}运行中${NC}"
  else
    svc_status="${RED}未运行${NC}"
  fi
  local ver
  ver=$("${BIN_PATH}" version 2>/dev/null | grep -oP 'sing-box version \K[\d.]+' || echo "?")

  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║           sing-box 管理菜单  M1 v${SCRIPT_VERSION}                   ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "  服务：${svc_status}   端口：${LISTEN_PORT}   版本：v${ver}"
  echo ""
  echo -e "   ${BOLD}1.${NC} 查看节点链接 & 二维码"
  echo -e "   ${BOLD}2.${NC} 显示二维码"
  echo -e "   ${BOLD}3.${NC} 导出 Shadowrocket 链接"
  echo -e "   ${BOLD}4.${NC} 导出 Clash/Mihomo 配置（整段打印）"
  echo -e "   ${BOLD}5.${NC} 导出 Surge 配置（整段打印）"
  echo -e "   ${BOLD}6.${NC} 导出 sing-box 客户端 JSON（整段打印）"
  echo -e "   ${BOLD}7.${NC} 查看服务状态"
  echo -e "   ${BOLD}8.${NC} 重启 sing-box"
  echo -e "   ${BOLD}9.${NC} 查看最近日志"
  echo -e "  ${BOLD}10.${NC} 更新 sing-box 内核"
  echo -e "  ${BOLD}11.${NC} 修改监听端口"
  echo -e "  ${BOLD}12.${NC} 修改 Reality SNI"
  echo -e "  ${BOLD}13.${NC} 重新生成客户端配置"
  echo -e "  ${BOLD}14.${NC} 重新生成全部凭据"
  echo -e "  ${BOLD}15.${NC} 备份当前配置"
  echo -e "  ${BOLD}16.${NC} 恢复上一个备份"
  echo -e "  ${BOLD}17.${NC} 完全卸载"
  echo -e "   ${BOLD}0.${NC} 退出"
  echo ""
  echo -ne "请选择 [0-17]："
}

run_menu() {
  while true; do
    _menu_header
    read -r choice
    echo ""

    case "${choice}" in
      1)  menu_view_link ;;
      2)  menu_show_qr ;;
      3)  menu_export_shadowrocket ;;
      4)  menu_export_clash ;;
      5)  menu_export_surge ;;
      6)  menu_export_singbox_client ;;
      7)  menu_service_status ;;
      8)  menu_restart_service ;;
      9)  menu_view_logs ;;
      10) menu_update_singbox ;;
      11) menu_change_port ;;
      12) menu_change_sni ;;
      13) menu_regen_client_configs ;;
      14) menu_regen_credentials ;;
      15) menu_backup ;;
      16) menu_restore_backup ;;
      17) do_uninstall; break ;;
      0)  echo -e "${NC}已退出"; break ;;
      *)  echo -e "${YELLOW}无效选项，请输入 0-17${NC}" ;;
    esac

    echo ""
    echo -ne "按 Enter 返回菜单..."
    read -r
  done
}

# ==============================================================
# §17  主入口
# ==============================================================

main() {
  # 最早初始化日志（check_root 之后可能就需要写日志）
  mkdir -p /var/log/sb-deploy 2>/dev/null || true
  chmod 700 /var/log/sb-deploy 2>/dev/null || true
  touch /var/log/sb-deploy/install.log /var/log/sb-deploy/error.log \
        /var/log/sb-deploy/audit.log 2>/dev/null || true

  # §1  root 检查（最优先）
  check_root

  # 已安装则直接进管理菜单
  if is_installed; then
    echo -e "${CYAN}检测到 sing-box 已安装，进入管理菜单...${NC}"
    run_menu
    exit ${E_OK}
  fi

  # ──────── 首次安装流程 ────────
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║    sing-box 一键安全部署脚本  M1 v${SCRIPT_VERSION}               ║${NC}"
  echo -e "${BOLD}${CYAN}║    协议：VLESS + Reality + xtls-rprx-vision                  ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  log_audit "安装开始"
  log_info "开始安装 sing-box M1..."

  # 步骤 1-5：系统检测
  check_os          # §4.1
  check_arch        # §4.2
  check_systemd     # §4.1

  # 步骤 6：依赖检测与安装
  check_and_install_deps  # §19

  # 步骤 6.5：优化 BBR 拥塞控制
  optimize_bbr

  # 初始化目录结构
  init_dirs

  # 步骤 7：公网 IP 检测
  detect_ip         # §9.2

  # 步骤 8：端口检测
  check_port 443    # §10.2

  # 步骤 9：提示安全组
  prompt_cloud_sg_notice  # §11.6

  # SNI 配置（含 TLS 1.3 检测）
  prompt_sni        # §9.3

  # 步骤 10-12：下载并安装 sing-box
  download_singbox  # §5 / §3.1

  # 步骤 13-15：生成凭据
  generate_credentials  # §8.2
  save_credentials      # §8.3

  # 步骤 16-17：生成服务端配置 + sing-box check
  generate_server_config  # §9

  # 步骤 18：创建 systemd 服务
  create_systemd_service  # §14

  # 步骤 19：启动服务
  start_and_verify_service  # §14.3

  # 步骤 20：服务状态检查
  check_service_status_brief

  # 步骤 21-23：生成客户端配置 & 二维码
  generate_client_configs  # §12

  # 防火墙配置
  configure_firewall  # §11

  # 保存安装状态
  save_install_state

  # 创建全局快捷管理命令 'sb'，方便以后在任意目录下输入 sb 直接打开管理面板
  log_info "正在创建全局快捷管理命令 'sb'..."
  cp "$0" /usr/local/bin/sb 2>/dev/null && chmod +x /usr/local/bin/sb 2>/dev/null || \
    log_warn "创建全局快捷管理命令 'sb' 失败（可能缺少写入权限）"

  # 步骤 24：输出安装结果
  print_install_summary  # §12 / §14.2 / §11.6

  log_audit "安装完成"
  exit ${E_OK}
}

main "$@"
