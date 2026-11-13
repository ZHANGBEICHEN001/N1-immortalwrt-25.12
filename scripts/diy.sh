#!/usr/bin/env bash
# =============================================================
# N1 定制脚本 —— 在 ImmortalWrt 源码根目录执行
#   调用时机：feeds update -a 之后、feeds install -a 之前
#   作用：注入 luci-app-amlogic、把软件源换成国内镜像、生成 N1 首次启动配置
# =============================================================
set -euo pipefail

if [ ! -f rules.mk ] || [ ! -f include/version.mk ]; then
  echo "::error::请在 ImmortalWrt 源码根目录执行本脚本" >&2
  exit 1
fi

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-OWNER/REPO}"
RELEASE_TAG_PREFIX="${RELEASE_TAG_PREFIX:-N1}"
KERNEL_SERIES="${KERNEL_SERIES:-6.12.y}"
FIRMWARE_SUFFIX="${FIRMWARE_SUFFIX:-.img.gz}"
CN_MIRROR="${CN_MIRROR:-false}"
N1_ROOT_PASSWORD="${N1_ROOT_PASSWORD:-password}"
N1_GH_PROXY="${N1_GH_PROXY:-0}"
N1_IP_MODE="${N1_IP_MODE:-dhcp}"
N1_IP="${N1_IP:-192.168.1.1}"

echo "================ diy.sh ================"
echo "仓库: $GITHUB_REPOSITORY | 内核: $KERNEL_SERIES | CI 国内代理: $CN_MIRROR"
echo "网络: $N1_IP_MODE (静态地址: $N1_IP)"

# -------------------------------------------------------------
# 1) 注入 luci-app-amlogic（N1 上做固件/内核在线升级用）
#    ImmortalWrt 官方 feed 不含此包，需从 ophub 仓库取。
#    注意：OpenClash 已内置于 immortalwrt/luci 的 openwrt-25.12 分支，
#    无需再额外 clone vernesong/OpenClash。
# -------------------------------------------------------------
echo "[1/5] 注入 luci-app-amlogic ..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone --depth 1 -q https://github.com/ophub/luci-app-amlogic "$tmp/src"
rm -rf feeds/luci/applications/luci-app-amlogic
if [ -f "$tmp/src/luci-app-amlogic/Makefile" ]; then
  cp -a "$tmp/src/luci-app-amlogic" feeds/luci/applications/
else
  cp -a "$tmp/src" feeds/luci/applications/luci-app-amlogic
  rm -rf feeds/luci/applications/luci-app-amlogic/.git
fi
if [ ! -f feeds/luci/applications/luci-app-amlogic/Makefile ]; then
  echo "::error::luci-app-amlogic 源码结构异常，请检查 ophub/luci-app-amlogic" >&2
  exit 1
fi

# -------------------------------------------------------------
# 2) 把固件内软件源换成国内镜像
#    include/version.mk 的 VERSION_REPO 会经 VERSION_SED_SCRIPT 写入：
#      apk : /etc/apk/repositories.d/distfeeds.list
#      opkg: /etc/opkg/distfeeds.conf
#    改这一处即可同时覆盖 25.12 的 apk 和旧版 opkg 两种情况。
#    上游 downloads.immortalwrt.org 的 releases/25.12-SNAPSHOT 在国内镜像
#    没有同步，因此指向 USTC 已镜像的最新 25.12.x 稳定版目录。
# -------------------------------------------------------------
echo "[2/5] 切换软件源到中科大 USTC 镜像 ..."
if [ -z "${IMMORTALWRT_RELEASE:-}" ]; then
  IMMORTALWRT_RELEASE="$(curl -fsSL --max-time 15 \
    https://mirrors.ustc.edu.cn/immortalwrt/releases/ 2>/dev/null \
    | grep -oE '25\.12\.[0-9]+' | sort -V | tail -n1 || echo '')"
  IMMORTALWRT_RELEASE="${IMMORTALWRT_RELEASE:-25.12.2}"
fi
CN_REPO="https://mirrors.ustc.edu.cn/immortalwrt/releases/${IMMORTALWRT_RELEASE}"
echo "       使用: $CN_REPO"

sed -i "s|https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT|${CN_REPO}|g" include/version.mk
sed -i "s|https://downloads.immortalwrt.org/|https://mirrors.ustc.edu.cn/immortalwrt/|g" include/version.mk

# 注：25.12 的 VERSION_REPO 不是 Kconfig 符号，写进 .config 会被
# make defconfig 当作未知符号丢弃；改 include/version.mk 才是唯一生效路径。
grep -n 'VERSION_REPO' include/version.mk | head -n 3 || true

# -------------------------------------------------------------
# 3) 可选：CI 里 feeds 的 GitHub 地址也走国内代理
#    GitHub 托管 runner 本身在境外，直连 GitHub 最快，默认关闭。
#    仅当你用国内自建 runner 或本地编译时才需要打开（CN_MIRROR=true）。
#    另外：源码包下载不用管，ImmortalWrt 的 scripts/projectsmirrors.json
#    已内置腾讯/阿里/清华/中科大等国内镜像。
# -------------------------------------------------------------
echo "[3/5] CI 国内代理: $CN_MIRROR"
if [ "$CN_MIRROR" = "true" ]; then
  GH_PROXY="${N1_GITHUB_PROXY:-https://ghfast.top/}"
  echo "       feeds 走代理: $GH_PROXY"
  sed -i "s|https://github.com/|${GH_PROXY}https://github.com/|g" feeds.conf.default
  sed -i "s|https://github.com/|${GH_PROXY}https://github.com/|g" \
    feeds/luci/applications/luci-app-amlogic/Makefile 2>/dev/null || true
fi

# -------------------------------------------------------------
# 4) 生成 luci-app-amlogic 的在线升级目标（指向本仓库 Release）
# -------------------------------------------------------------
echo "[4/5] 生成 /etc/config/amlogic ..."
KERNEL_BRANCH="${KERNEL_SERIES%.y}"
mkdir -p files/etc/config
cat > files/etc/config/amlogic <<EOF
config amlogic 'config'
	option enable '1'
	option amlogic_firmware_repo 'https://github.com/${GITHUB_REPOSITORY}'
	option amlogic_firmware_tag '${RELEASE_TAG_PREFIX}'
	option amlogic_firmware_suffix '${FIRMWARE_SUFFIX}'
	option amlogic_kernel_path 'https://github.com/ophub/kernel'
	option amlogic_kernel_tags 'kernel_stable'
	option amlogic_kernel_branch '${KERNEL_BRANCH}'
	option amlogic_firmware_config '1'
	option amlogic_write_bootloader '1'
	option amlogic_shared_fstype 'ext4'

config settings 'armcpu'
	option governor0 'schedutil'
EOF

# -------------------------------------------------------------
# 5) 替换首次启动脚本里的占位符
# -------------------------------------------------------------
echo "[5/5] 生成网络与首次启动配置 ..."
# files/etc/config/network 默认模板是 DHCP；static 模式在这里整份覆盖。
# ophub 的 remake 不会写 etc/config/network（它只在 -p 非默认时改
# bin/config_generate），所以这里的文件就是固件里的最终网络配置。
mkdir -p files/etc/config
if [ "$N1_IP_MODE" = "static" ]; then
  cat > files/etc/config/network <<EOF
# static 模式：固定管理地址（由 scripts/diy.sh 生成）
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '${N1_IP}'
	option netmask '255.255.255.0'
	option hostname 'N1-OpenWrt'
	option delegate '0'

config globals 'globals'
	option packet_steering '2'
	option steering_flows '256'
EOF
  echo "       已写入静态地址: $N1_IP"
else
  grep -q "option proto 'dhcp'" files/etc/config/network || {
    echo "::error::默认 network 模板不是 DHCP 配置" >&2
    exit 1
  }
  echo "       DHCP 自动获取 IP，首次启动会关闭本机 DHCP 服务器"
fi

if [ -f files/etc/uci-defaults/99-n1-custom.sh ]; then
  pw_escaped="$(printf '%s' "$N1_ROOT_PASSWORD" | sed -e 's/[\\&|]/\\&/g')"
  proxy_escaped="$(printf '%s' "$N1_GH_PROXY" | sed -e 's/[\\&|]/\\&/g')"
  sed -i \
    -e "s|__ROOT_PASSWORD__|${pw_escaped}|g" \
    -e "s|__GH_PROXY__|${proxy_escaped}|g" \
    -e "s|__IP_MODE__|${N1_IP_MODE}|g" \
    files/etc/uci-defaults/99-n1-custom.sh
  chmod 0755 files/etc/uci-defaults/99-n1-custom.sh
fi

echo "================ diy.sh 完成 ================"
