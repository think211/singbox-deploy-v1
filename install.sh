#!/usr/bin/env bash
# ==============================================================
# Sing-box 一键部署引导脚本（Bootstrap）
# 用途：仅做引导，下载主逻辑脚本后落盘再执行
# 用法：bash install.sh
# ==============================================================
set -euo pipefail

# ────────── 配置（使用前根据实际托管地址修改）──────────
# 主脚本的固定版本 URL（建议指向 tag/commit，不要用随时变化的 main 分支）
readonly MAIN_SCRIPT_URL="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/v1.0.0/sb-deploy.sh"

# 主脚本的 sha256（从独立渠道获取并填入，用于完整性校验）
# 若留空，则跳过哈希校验（不推荐用于生产）
readonly EXPECTED_SHA256=""

readonly TMP_SCRIPT="/tmp/sb-deploy-$$.sh"

# ────────── 基础检查 ──────────
if [[ $EUID -ne 0 ]]; then
  echo "[✗] 需要 root 权限。请使用 sudo 或切换到 root 后重新执行。"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "[!] curl 未安装，尝试安装..."
  apt-get update -qq && apt-get install -y -qq curl || {
    echo "[✗] curl 安装失败，请手动安装后重试"
    exit 1
  }
fi

# ────────── 下载主脚本 ──────────
echo "[*] 正在下载部署脚本..."
if ! curl -fL --max-time 60 --retry 3 -o "${TMP_SCRIPT}" "${MAIN_SCRIPT_URL}"; then
  echo "[✗] 下载失败：${MAIN_SCRIPT_URL}"
  echo "    请检查网络连接后重试，或手动下载主脚本"
  rm -f "${TMP_SCRIPT}"
  exit 1
fi

# ────────── 完整性校验 ──────────
if [[ -n "${EXPECTED_SHA256}" ]]; then
  echo "[*] 正在校验脚本完整性..."
  local_sha256=$(sha256sum "${TMP_SCRIPT}" | awk '{print $1}')
  if [[ "${local_sha256}" != "${EXPECTED_SHA256}" ]]; then
    echo "[✗] sha256 校验失败！"
    echo "    预期：${EXPECTED_SHA256}"
    echo "    实际：${local_sha256}"
    echo "    脚本可能已被篡改，请从独立渠道核对哈希后再执行"
    rm -f "${TMP_SCRIPT}"
    exit 1
  fi
  echo "[✓] 完整性校验通过"
else
  echo "[!] 未配置 EXPECTED_SHA256，跳过校验（建议在生产环境中配置）"
fi

# ────────── 执行主脚本 ──────────
chmod +x "${TMP_SCRIPT}"
echo "[*] 开始执行主脚本..."
bash "${TMP_SCRIPT}" "$@"
exit_code=$?

rm -f "${TMP_SCRIPT}"
exit ${exit_code}
