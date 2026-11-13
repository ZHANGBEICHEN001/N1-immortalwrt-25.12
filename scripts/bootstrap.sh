#!/usr/bin/env bash
# =============================================================
# 一键初始化：把本目录推送为 fork 仓库的轻量默认分支 main，
# 并打开 GitHub Actions 的写权限。在本地执行一次即可。
#
# 前置：已安装 git 与 GitHub CLI (gh)，且已 gh auth login。
# 用法：bash scripts/bootstrap.sh <gh登录用户名>/<fork仓库名>
# 注意：owner 必须和 gh 当前登录账号完全一致，拼错会得到 404。
# =============================================================
set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then
  echo "用法: bash scripts/bootstrap.sh <gh登录用户名>/<fork仓库名>" >&2
  echo "例如: bash scripts/bootstrap.sh zhangsan/immortalwrt" >&2
  exit 1
fi

for cmd in git gh; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少命令: $cmd" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "请先执行 gh auth login" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
if [ "$OWNER" = "$REPO" ] || [ -z "$REPO_NAME" ]; then
  echo "用法: bash scripts/bootstrap.sh <gh登录用户名>/<fork仓库名>" >&2
  exit 1
fi

LOGIN="$(gh api user --jq .login 2>/dev/null)" || {
  echo "无法读取 gh 登录账号，请重新执行 gh auth login" >&2; exit 1; }

echo "[1/6] 校验账号、仓库与 fork 关系 ..."
if [ "$OWNER" != "$LOGIN" ]; then
  echo "  错误: 用户名与 gh 当前登录账号不一致" >&2
  echo "    你传入的 owner : $OWNER" >&2
  echo "    gh 当前登录    : $LOGIN" >&2
  echo "    请改跑: bash scripts/bootstrap.sh $LOGIN/$REPO_NAME" >&2
  exit 1
fi
echo "  登录账号: $LOGIN"

if ! gh api "repos/$REPO" >/dev/null 2>&1; then
  echo "  错误: 仓库 $REPO 不存在或当前账号无权访问（HTTP 404）" >&2
  echo "    如果还没创建 fork，可执行（会建到当前登录账号下）：" >&2
  echo "      gh repo fork immortalwrt/immortalwrt --fork-name $REPO_NAME --clone=false" >&2
  echo "    或到 https://github.com/immortalwrt/immortalwrt/fork 创建后重跑。" >&2
  exit 1
fi

PARENT="$(gh api "repos/$REPO" --jq '.parent.full_name // empty' 2>/dev/null)" || PARENT=""
if [ "$PARENT" != "immortalwrt/immortalwrt" ]; then
  echo "  错误: $REPO 不是 immortalwrt/immortalwrt 的 fork（父仓库: ${PARENT:-无}）" >&2
  echo "    sync-upstream.yml 依赖 GitHub 官方 fork 同步接口，非 fork 仓库无法工作。" >&2
  echo "    请改用真正的 fork 仓库，或到 https://github.com/immortalwrt/immortalwrt/fork 新建。" >&2
  exit 1
fi
echo "  已确认 fork 关系: $PARENT"

echo "[2/6] 确保 fork 中存在 openwrt-25.12 分支 ..."
if gh api "repos/$REPO/branches/openwrt-25.12" >/dev/null 2>&1; then
  echo "  分支已存在"
else
  # GitHub 的 Fork 默认只复制上游默认分支 master，其它分支需要手动建
  echo "  Fork 默认只带 master，正在从上游创建 openwrt-25.12 ..."
  SHA="$(gh api repos/immortalwrt/immortalwrt/commits/openwrt-25.12 --jq .sha)" || {
    echo "  错误: 无法读取上游 openwrt-25.12 的 commit" >&2; exit 1; }
  if gh api -X POST "repos/$REPO/git/refs" \
      -f ref='refs/heads/openwrt-25.12' -f sha="$SHA" >/dev/null 2>&1; then
    echo "  已创建 openwrt-25.12 (${SHA:0:12})"
  else
    echo "  错误: 创建分支失败" >&2
    echo "    请到 https://github.com/$REPO/branches 手动新建分支 openwrt-25.12 后重跑。" >&2
    exit 1
  fi
fi

echo "[3/6] 先同步一次上游源码 ..."
if ! gh repo sync "$REPO" --source immortalwrt/immortalwrt \
      --branch openwrt-25.12 --force; then
  if ! gh api -X POST "repos/$REPO/merge-upstream" \
        -f branch='openwrt-25.12' >/dev/null 2>&1; then
    echo "  警告: 同步接口返回异常；分支刚创建且已指向上游最新提交时属正常，不影响构建" >&2
  fi
fi

echo "[4/6] 推送配置分支 main ..."
gh auth setup-git >/dev/null 2>&1 || true
cd "$ROOT"
if [ ! -d .git ]; then
  git init -q -b main 2>/dev/null || { git init -q; git checkout -q -b main; }
fi
git add -A
if ! git diff --cached --quiet; then
  git -c user.name="N1 Builder" -c user.email="n1-builder@users.noreply.github.com" \
    commit -qm "feat: N1 自动构建配置 (ImmortalWrt 25.12)"
fi
git branch -M main
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$REPO.git"
git push -f -u origin main

echo "[5/6] 设 main 为默认分支（Actions 的 schedule 只在默认分支生效）..."
gh repo edit "$REPO" --default-branch main >/dev/null

echo "[6/6] 打开 Actions 写权限（创建 Release 需要）..."
gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true >/dev/null

cat <<EOF

================ 初始化完成 ================
仓库:      https://github.com/$REPO
默认分支:  main（轻量配置分支，只放本项目文件）
源码分支:  openwrt-25.12（与上游一致，由 sync-upstream.yml 每周自动快进）

建议现在手动跑一次，验证整条流水线：
  gh workflow run build-n1.yml --repo $REPO --ref main
  gh run list --repo $REPO --workflow=build-n1.yml --limit 3
  gh run watch --repo $REPO

首次全量编译约 2-4 小时；之后每周有 dl / ccache 缓存会明显更快。
可选配置（Settings -> Secrets and variables -> Actions -> Variables）：
  N1_ROOT_PASSWORD   固件 root 密码，默认 password，务必改成自己的
  N1_GH_PROXY        OpenClash 的 GitHub 加速前缀，默认 0（关闭）
  IMMORTALWRT_RELEASE 国内镜像版本，默认自动探测最新 25.12.x
EOF
