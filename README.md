# N1 固件自动构建 · ImmortalWrt 25.12

基于 [`immortalwrt/immortalwrt@openwrt-25.12`](https://github.com/immortalwrt/immortalwrt/tree/openwrt-25.12) 为**斐讯 N1（Amlogic S905D，单网口）**自动编译固件：

- 源码以 **Fork** 形式放在 GitHub，每周自动同步上游 `openwrt-25.12` 分支；
- **每周一**自动编译并打包成可直接写入 eMMC 的 `.img.gz`，发布到 Releases；
- 内置 **OpenClash**（来自 ImmortalWrt 官方 luci feed）、LuCI、`luci-app-amlogic`；
- LAN 默认通过 **DHCP 自动获取 IP**，插上网线由主路由分配，不用固定地址（可一键切回静态 IP）；
- 固件内软件源指向**中科大 USTC 国内镜像**。

---

## 1. 整体架构

N1 没有独立的 OpenWrt target。做法是：先编译出通用的 `armsr/armv8` rootfs，再用 [ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt) 的打包脚本，配上 flippy 的 Amlogic 内核与 N1 的 dtb，生成 `s905d` 镜像。这是社区验证过的 25.12 分支标准链路。

```
immortalwrt/immortalwrt @ openwrt-25.12  （上游）
        │  GitHub 官方 fork 同步接口 (gh repo sync / merge-upstream)
        ▼
你的 fork @ openwrt-25.12 分支          （纯净镜像，绝不手工改）
        │  actions/checkout
        ▼
编译 armsr/armv8 → rootfs.tar.gz
        │  ophub action: -b s905d -u flippy -k 6.12.y
        ▼
openwrt_s905d_n1_*.img.gz → GitHub Release
```

### 分支设计（重要）

| 分支 | 内容 | 谁维护 |
|---|---|---|
| `main`（**默认分支**） | 仅本项目的 `.github/workflows/`、`config/`、`files/`、`scripts/`、`README.md`，几十 KB | 你 |
| `openwrt-25.12` | 与上游完全一致的 ImmortalWrt 源码，不含任何自定义文件 | `sync-upstream.yml` 每周自动快进 |
| `master` 等 | Fork 时自带的上游分支，本项目不使用，可忽略 | — |

为什么不直接在源码分支上加 workflow：上游自己也有 `.github/workflows/`，每周合并容易产生冲突、且 Actions 每次都要拉几百 MB 全历史。改成「轻量默认分支 + 纯净源码镜像分支」后，同步走 GitHub 官方接口（秒级、零冲突），构建时分别 checkout 两个分支即可。`main` 设为默认分支还有个必要条件：**GitHub Actions 的 `schedule` 只在默认分支生效**。

### 文件清单

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-n1.yml` | 每周一编译、打包、发 Release、清理旧 Release |
| `.github/workflows/sync-upstream.yml` | 同步 fork 的 `openwrt-25.12` 分支到上游并记录 commit SHA |
| `config/n1.config` | 编译种子配置（target、软件包、精简项、软件源） |
| `scripts/diy.sh` | 注入 `luci-app-amlogic`、换国内镜像源、按 IP 模式生成网络与首次启动配置 |
| `files/etc/config/network` | 默认 DHCP 网络配置；`static` 模式由 `diy.sh` 整份覆盖 |
| `files/etc/uci-defaults/99-n1-custom.sh` | 首次启动设主机名/时区/国内 NTP/root 密码，并在 DHCP 模式关闭本机 DHCP 服务器 |
| `scripts/bootstrap.sh` | 本地一键初始化 fork 仓库（gh CLI） |
| `UPSTREAM_SHA` | 由同步工作流维护的上游 commit 记录 |

---

## 2. 部署（一次性，约 3 分钟）

**前置**：GitHub 账号、本地装好 `git` 与 [GitHub CLI](https://cli.github.com) 并 `gh auth login`。登录时 token 需要 `repo` 与 `workflow` scope（推送 `.github/workflows/` 必须有 `workflow`），并同意用它配置 Git 凭证：

```bash
gh auth login --web --git-protocol https --scopes "repo,read:org,workflow"
```

1. **Fork 源码**：打开 <https://github.com/immortalwrt/immortalwrt/fork>，创建一个 fork（仓库名随意）。**建议设为 Public** —— 公开仓库的 Actions 免费且不限时长配额；私有仓库每月 2000 分钟，一次全量编译 2~4 小时会很快用完。

   > 注意：**GitHub 的 Fork 默认只复制上游的默认分支 `master`**，不会带 `openwrt-25.12`。下面的脚本会自动从上游最新 commit 帮你把这个分支建出来，不用手工操作。

2. **把本项目下载到本地**，在目录里执行：

   ```bash
   bash scripts/bootstrap.sh <gh登录用户名>/<fork仓库名>
   ```

   **`<gh登录用户名>` 必须和 `gh api user --jq .login` 的输出完全一致**，写错（哪怕一个字母）会因为查无此用户而得到一连串 HTTP 404。可用 `gh auth status` 查看当前登录的是哪个账号。仓库名大小写不敏感，GitHub 会自动匹配。

   脚本会：校验账号与 fork 关系 → 从上游创建 `openwrt-25.12` 分支并同步一次 → 把本目录推成 `main` 分支 → 设为默认分支 → 打开 Actions 写权限（创建 Release 需要）。

   <details><summary>不用脚本的手动等价步骤</summary>

   ```bash
   git init -b main && git add -A && git commit -m "feat: N1 build config"
   git remote add origin https://github.com/<用户>/<仓库>.git
   git push -f -u origin main
   gh repo sync <用户>/<仓库> --source immortalwrt/immortalwrt --branch openwrt-25.12 --force
   ```
   然后在 **Settings → Branches** 把默认分支改成 `main`，在 **Settings → Actions → General → Workflow permissions** 选 **Read and write permissions** 并保存。

   </details>

3. **手动跑一次验证**（首次全量编译约 2~4 小时）：

   ```bash
   gh workflow run build-n1.yml --repo <用户>/<仓库> --ref main
   gh run watch --repo <用户>/<仓库>
   ```

   成功标志：Releases 里出现 `N1-YYYYMMDD`，包含 `*.img.gz`、`*rootfs.tar.gz`、`sha256sums.txt`。

4. （推荐）在 **Settings → Secrets and variables → Actions → Variables** 里加：

   | 变量 | 默认值 | 说明 |
   |---|---|---|
   | `N1_ROOT_PASSWORD` | `password` | 固件 root 密码，**务必改成自己的** |
   | `N1_GH_PROXY` | `0` | OpenClash 的 GitHub 加速前缀，如 `https://ghfast.top/`；`0` 为关闭 |
   | `IMMORTALWRT_RELEASE` | 自动探测 | 国内镜像版本，如 `25.12.2` |
   | `N1_FIRMWARE_SUFFIX` | `.img.gz` | 若打包产物是 `.img.xz` 则改成 `.img.xz` |

---

## 3. 定时与自动同步

GitHub Actions 的 `cron` **一律按 UTC 计算**，与 `TZ: Asia/Shanghai` 无关。换算关系：

| 工作流 | cron (UTC) | 北京时间 | 做什么 |
|---|---|---|---|
| `sync-upstream.yml` | `47 0 * * 1` | **每周一 08:47** | 同步上游源码 |
| `build-n1.yml` | `17 1 * * 1` | **每周一 09:17** | 编译 + 打包 + 发 Release |

同步在构建前 30 分钟跑，保证当周固件用的是最新上游代码。想改时间，只需改两个 yml 里的 cron（北京时间减 8 小时换算成 UTC；注意跨日时星期会往前一天）。

**同步原理**：`gh repo sync` 调用 GitHub 官方的 `POST /repos/{owner}/{repo}/merge-upstream` 接口，把 fork 的 `openwrt-25.12` 分支快进到上游同名分支，不 clone 源码、不产生合并提交。同步后会把上游 SHA 写入 `UPSTREAM_SHA`，并显示在 workflow 的 Summary 里；构建工作流的 Release 说明也会带上该 SHA，方便追溯。

> GitHub 规定：仓库 **连续 60 天没有任何活动**时，定时工作流会被自动停用，需要到 Actions 页面手动重新启用。偶尔手动触发一次即可避免。

也可以在 Actions 页面手动运行 `Sync upstream ImmortalWrt`，勾选 `trigger_build` 立即触发一次构建（默认关闭，避免和周一定时任务重复）。

手动运行 `Build N1 Firmware` 时可选的输入：`ip_mode`（`dhcp` / `static`）、`openwrt_ip`（仅 static 生效）、`openwrt_kernel`、`cn_mirror`、`no_cache`。定时构建固定使用默认值 `ip_mode=dhcp`。

---

## 4. 产物与刷机

每次 Release 含：

- `openwrt_s905d_n1_*.img.gz` —— 写入 U 盘 / eMMC 的完整镜像（flippy `6.12.y` 内核，自动取同系列最新）；
- `immortalwrt-armsr-armv8-generic-rootfs.tar.gz` —— 通用 rootfs，可用于救砖或换内核重新打包；
- `sha256sums.txt` —— 校验和。

**默认信息**：LAN 默认通过 DHCP 自动获取 IP，账号 `root`，密码 `password`（或你设的 `N1_ROOT_PASSWORD`），主机名 `N1-OpenWrt`。固件内已装 LuCI、OpenClash、`luci-app-amlogic`（系统里可直接在线更新固件/内核）。

### 网络模式：自动获取 IP

默认 `ip_mode=dhcp`。固件里写了两份保障，确保打包脚本不会把静态地址覆盖回来：

1. `files/etc/config/network` —— `config interface 'lan'` 用 `option proto 'dhcp'`、`option device 'eth0'`。已核实 ophub 的 `remake` **不会写 `etc/config/network`**，它的 `-p` 参数只改 `bin/config_generate` 里的默认 IP（且仅在非默认值时改）；DHCP 模式下本工作流会把该参数固定为默认值 `192.168.1.1`，等于完全跳过这一步。
2. `files/etc/uci-defaults/99-n1-custom.sh` —— 首次启动、网络服务拉起之前执行，强制 `network.lan.proto=dhcp`，清掉 `ipaddr/netmask/gateway/dns` 残留，并设 `dhcp.lan.ignore=1` **关闭 N1 自己的 DHCP 服务器**（否则会和主路由抢着分配地址）。这一层是最终裁决。

**怎么找到 N1 的 IP**：登录主路由后台，在 DHCP 客户端 / 已连接设备列表里找主机名 `N1-OpenWrt`（网络配置里显式设了 `option hostname 'N1-OpenWrt'`，DHCP 请求会带上它）；也可以用 `arp -a` 或局域网扫描工具按主机名找。建议顺手在主路由给 `N1-OpenWrt` 做一条静态地址绑定，以后地址固定更好管理。

| 场景 | 该选什么 |
|---|---|
| 接在主路由后面，当旁路由 / 单臂设备 | 默认 `dhcp`，插上网线就能从主路由列表里找到 |
| N1 直连电脑、或网络里没有 DHCP 服务器 | 手动触发时选 `ip_mode=static` + 填 `openwrt_ip`，否则拿不到地址 |
| N1 要当主路由拨号 | 选 `static`，再在 LuCI 里配 WAN/PPPoE（本项目默认不带 PPPoE 包） |

> DHCP 只解决「N1 自己怎么拿地址」。要让其它设备的流量经过 N1（例如走 OpenClash），还需要在客户端或主路由上把网关 / DNS 指向 N1 实际拿到的 IP，这一步本项目不代为配置。

**刷机大致流程**：解压 `.img.gz` → 用 balenaEtcher / Rufus 写入 U 盘 → N1 从 U 盘启动（需设备已支持 USB 引导，未支持时先按 N1 常规流程处理 bootloader）→ 进入系统后用 `luci-app-amlogic` 或 `openwrt-install-amlogic` 写入 eMMC。

> ⚠️ 刷机有变砖风险。写入 eMMC 前请先用 `openwrt-ddbr` 之类的工具备份原厂 eMMC，并确认设备确为斐讯 N1（S905D）。具体命令以 [ophub 项目文档](https://github.com/ophub/amlogic-s9xxx-openwrt) 当前版本为准。

---

## 5. 「换成国内源」具体换了什么

分三层，避免只改一半：

| 层级 | 处理 | 位置 |
|---|---|---|
| **固件内软件源**（装包用，最关键） | `downloads.immortalwrt.org` → `mirrors.ustc.edu.cn/immortalwrt/releases/25.12.x` | `scripts/diy.sh` 改 `include/version.mk` 的 `VERSION_REPO`。注意 25.12 里它不是 Kconfig 符号，写进 `.config` 会被 `make defconfig` 丢弃 |
| **刷机后系统时间** | 时区 `Asia/Shanghai`、NTP 用阿里云/腾讯云/`cn.ntp.org.cn` | `files/etc/uci-defaults/99-n1-custom.sh` |
| **CI 构建期下载** | ImmortalWrt 上游 `scripts/projectsmirrors.json` **已经内置**腾讯/阿里/清华/中科大镜像，无需额外改 | 上游自带 |

两个容易踩的点：

- 25.12 分支默认 **`CONFIG_USE_APK=y`**（用的是 `apk`，不是 `opkg`）。软件源由 `include/version.mk` 的 `VERSION_REPO` 一处生成，同时填充 `/etc/apk/repositories.d/distfeeds.list`（apk）和 `/etc/opkg/distfeeds.conf`（opkg），改这一处两边都覆盖。装包请用 `apk add <包名>`。
- 上游源码分支的版本号是 `25.12-SNAPSHOT`，但中科大镜像**没有**同步 SNAPSHOT 目录（清华目前也没有 ImmortalWrt 镜像）。所以 `diy.sh` 会自动探测 USTC 上最新的 `25.12.x` 稳定版并指向它；纯用户态软件包通用，内核模块仍以打包时 flippy 内核自带的为准。可用 `IMMORTALWRT_RELEASE` 变量固定版本。

另外：CI 跑在 GitHub 境外 runner 上，**feeds 的 git 源默认直连 GitHub 最快**。只有你用国内自建 runner 或本地编译时，才在手动触发时勾选 `cn_mirror`（给 `feeds.conf.default` 加 GitHub 代理前缀）。

OpenClash 的 GEO 数据源（Country.mmdb / geosite.dat / geoip.dat）官方默认已经用 `testingcf.jsdelivr.net` 与 `ispip.clang.cn`，本身就是国内可直连；只有下载 Mihomo 内核可能慢，需要时设 `N1_GH_PROXY` 或在 LuCI 里配「GitHub 地址修改」。

---

## 6. 常见自定义

| 想改什么 | 改哪里 |
|---|---|
| 增删软件包 | `config/n1.config`（`=y` 加入 / `=n` 去掉）。加第三方包请在 `scripts/diy.sh` 里 clone 到 `package/` 或 `feeds/`，并在 `feeds install -a` 之前完成 |
| 换打包内核 | 手动触发时的 `openwrt_kernel` 输入，默认 `6.12.y`；同时 `diy.sh` 会把 `luci-app-amlogic` 的内核分支设成对应 `6.12` |
| 切回固定 IP | 手动触发时把 `ip_mode` 选 `static`，再填 `openwrt_ip`（如 `192.168.1.2`）；定时构建仍默认 DHCP |
| 让其它设备走 N1 | 在客户端或主路由把网关/DNS 指向 N1 的 IP，并给 `N1-OpenWrt` 做静态地址绑定 |
| 改密码 | Actions 变量 `N1_ROOT_PASSWORD`，不要写进仓库 |
| Release 保留数量 | `build-n1.yml` 最后一步的 `tail -n +9`，现为保留 8 个 |
| 关闭自动清理旧 Release | 删掉 `build-n1.yml` 里「清理旧 Release」这一步 |
| 完全不打包 `luci-app-amlogic` | 删掉 `diy.sh` 的第 1 段和 `n1.config` 里对应的 `=y`（第 4 段会一并跳过） |

---

## 7. 排错

| 现象 | 原因 / 处理 |
|---|---|
| `make defconfig` 后 `CONFIG_PACKAGE_*` 全丢、报「OpenClash 未进入配置」 | `.config` 种子必须在 `feeds install -a` **之后**才放入；feeds 阶段会重建 `tmp/.config-package.in`，提前放入的包符号会被 kconfig 当成未知符号丢弃。同理 diy.sh 往 feeds 注入新包后必须再跑一次 `feeds update -a` 重建索引 |
| `recursive dependency detected` 刷屏 | ImmortalWrt feeds 里 dnsdist / snort3 / luci-app-weechat 等包自带的 Kconfig 警告，日志仍会输出 `configuration written to .config`，不致命，可忽略 |
| `bootstrap.sh` 报 HTTP 404 / 「用户名与登录账号不一致」 | 传入的 owner 必须和 `gh api user --jq .login` 完全一致；`gh auth status` 可查看当前登录账号。用户名拼错时 GitHub 会返回 404 而不是 403 |
| `git push` 被拒、提示 workflow scope | token 缺 `workflow` 权限，执行 `gh auth refresh -s workflow` 后重试 |
| `Sync upstream` 报「is not a fork」 | 仓库必须是 `immortalwrt/immortalwrt` 的 fork；用网页 Fork 创建，不能只 import 源码 |
| 定时任务到点不跑 | 默认分支必须是 `main`；GitHub 整点 cron 可能延迟 5~30 分钟；或仓库 60 天无活动被自动停用 |
| Release 创建失败 403 | Settings → Actions → General → Workflow permissions 需要 **Read and write**；`bootstrap.sh` 已自动设置 |
| 编译超时 | 单次 job 上限 6 小时（本项目设 350 分钟）。首次全量最慢，之后 `dl` / `ccache` 缓存会明显加速；仍超时就精简 `n1.config` 里的包 |
| 磁盘不足 | 已用 `jlumbroso/free-disk-space` 清理预装 SDK；不要同时开多个编译任务（`concurrency` 已做排队） |
| `make -j1 V=s` 报第三方包错 | 本项目只额外依赖 `ophub/luci-app-amlogic` 一个第三方源；先手动重跑 `sync-upstream.yml` 再构建，或临时去掉该包验证 |
| OpenClash 内核下载不动 | 设 `N1_GH_PROXY` 或在 LuCI → OpenClash → 版本更新里配置 GitHub 加速 |
| 装包提示 `opkg: not found` | 25.12 用 apk：`apk update && apk add <包名>` |
| 刷机后找不到 N1 的 IP | 默认 DHCP 模式必须接在有 DHCP 服务器的网络；到主路由客户端列表找 `N1-OpenWrt` 或用 `arp -a` 扫描。直连电脑请选 `static` 模式重编 |
| 局域网里出现两个 DHCP 服务器 | 默认已设 `dhcp.lan.ignore=1`；若改回了默认配置，到 LuCI → 网络 → 接口 → LAN 里把「忽略此接口」勾上 |

---

## 8. 致谢与许可

- 源码：[ImmortalWrt](https://github.com/immortalwrt/immortalwrt)（GPL-2.0-only）
- 打包脚本与内核：[ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt)、[ophub/kernel](https://github.com/ophub/kernel)、[unifreq/openwrt_packit](https://github.com/unifreq/openwrt_packit)
- 25.12 分支 N1 配置实践参考：[nantayo/N1-OpenWrt](https://github.com/nantayo/N1-OpenWrt)、[stephensund/n1](https://github.com/stephensund/n1)
- OpenClash：[vernesong/OpenClash](https://github.com/vernesong/OpenClash)（本项目直接使用 ImmortalWrt 官方 luci feed 内已收录的版本）

固件刷写有风险，使用前请自行备份并确认设备型号。
