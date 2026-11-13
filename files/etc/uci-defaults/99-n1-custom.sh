#!/bin/sh
# =============================================================
# N1 首次启动配置（OpenWrt 执行完会自动删除本脚本）
# 占位符由 scripts/diy.sh 在编译期替换，请勿直接编辑生效值。
#   __ROOT_PASSWORD__ -> 由 GitHub Actions 变量 vars.N1_ROOT_PASSWORD 注入
#   __GH_PROXY__      -> 由 GitHub Actions 变量 vars.N1_GH_PROXY 注入，0 表示关闭
#   __IP_MODE__       -> 由 build-n1.yml 的 ip_mode 输入注入：dhcp / static
# =============================================================
ROOT_PASSWORD="__ROOT_PASSWORD__"
GH_PROXY="__GH_PROXY__"
IP_MODE="__IP_MODE__"

# 主机名 / 时区 / 国内 NTP
uci -q set system.@system[0].hostname='N1-OpenWrt'
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.ntp.enabled='1'
uci -q delete system.ntp.server
uci -q add_list system.ntp.server='ntp.aliyun.com'
uci -q add_list system.ntp.server='time1.cloud.tencent.com'
uci -q add_list system.ntp.server='cn.ntp.org.cn'
uci -q commit system

# 让 DHCP 请求立刻带上新主机名，主路由客户端列表里能看到 N1-OpenWrt
echo 'N1-OpenWrt' > /proc/sys/kernel/hostname 2>/dev/null || true

# ---------- 网络模式：DHCP 自动获取 IP ----------
# uci-defaults 在网络服务启动之前执行，这里做最终裁决：
# 即便打包脚本或 config_generate 写过静态地址，也会改回 DHCP。
if [ "$IP_MODE" = "dhcp" ]; then
  uci -q set network.lan.proto='dhcp'
  uci -q delete network.lan.ipaddr 2>/dev/null || true
  uci -q delete network.lan.netmask 2>/dev/null || true
  uci -q delete network.lan.gateway 2>/dev/null || true
  uci -q delete network.lan.dns 2>/dev/null || true
  uci -q commit network

  # N1 旁路由不能再发 DHCP，否则会和主路由抢着分配地址
  if uci -q get dhcp.lan >/dev/null 2>&1; then
    uci -q set dhcp.lan.ignore='1'
    uci -q commit dhcp
  fi
fi

# 默认密码（务必在首次登录后修改）
if [ -n "$ROOT_PASSWORD" ] && [ "$ROOT_PASSWORD" != "CHANGE_ME" ]; then
  printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd root >/dev/null 2>&1 || true
fi

# OpenClash：GEO 数据源官方默认已是国内 CDN（jsdelivr / ispip.clang.cn），
# 这里只处理"GitHub 加速地址"，用于下载 Mihomo 内核与更新包。
# 默认 0（关闭）；需要时在仓库 Settings -> Variables 配置 N1_GH_PROXY。
if [ "$GH_PROXY" != "0" ] && [ -n "$GH_PROXY" ]; then
  if uci -q get openclash.config >/dev/null 2>&1; then
    uci -q set openclash.config.github_address_mod="$GH_PROXY"
    uci -q commit openclash
  fi
fi

exit 0
