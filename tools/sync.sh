#!/usr/bin/env bash
# ============================================================================
# SubCase 上游同步脚本
#
# 目标：跟随上游 sub-store-org/subcase 更新，同时完整保留自己 fork 上的
#       自定义后端改动（feature/custom-backend 分支）。
#
# 模型：
#   upstream/main   —— 官方上游，永不改动
#   origin/main    —— 你的 fork 的 main，镜像上游（可直接 reset --hard 对齐）
#   feature/custom-backend —— 你的改动所在分支，永远 rebase 到最新 upstream/main
#
# 冲突处理策略：
#   只有当上游改动了与你改动「同一文件同一区域」时才会冲突。
#   SettingsScreen.kt 与 ConfigStore.kt 是最可能冲突的文件。
#   解决后用 `verify.sh` 做本地静态校验，通过再推送。
#
# 用法：
#   ./sync.sh              # 同步 + 校验 + 推送 + 构建
#   ./sync.sh --no-push    # 只同步和校验，不推送
#   ./sync.sh --no-build   # 不同步构建
# ============================================================================
set -uo pipefail

REPO_DIR="${REPO_DIR:-/c/Users/Administrator/WorkBuddy/gh-work/subcase-dev}"
UPSTREAM="https://github.com/sub-store-org/subcase.git"
FORK="https://github.com/zhangxiao439/subcase.git"
FEATURE_BRANCH="feature/custom-backend"

# 自动定位 python / kotlinc（便携版），避免硬编码路径换机器就失效
if [ -z "${PY:-}" ]; then
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
: "${PY:=python3}"

# 自动加载已保存的 token（无需每次手动 export）
if [ -z "${GITHUB_TOKEN:-}" ]; then
  for f in "$HOME/.workbuddy/secrets/github_token.sh" \
           "$HOME/.github_token"; do
    if [ -f "$f" ]; then
      . "$f" 2>/dev/null
      [ -n "${GITHUB_TOKEN:-}" ] && break
    fi
  done
fi

if [ -z "${KOTLINC:-}" ]; then
  for c in "$(command -v kotlinc 2>/dev/null)" \
           /c/Users/Administrator/WorkBuddy/gh-work/kotlinc/kotlinc/bin/kotlinc.bat \
           /c/Users/Administrator/WorkBuddy/gh-work/kotlinc/bin/kotlinc.bat; do
    [ -n "$c" ] && [ -f "$c" ] && { KOTLINC="$c"; break; }
  done
fi
export PY KOTLINC

DO_PUSH=1
DO_BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-push)  DO_PUSH=0 ;;
    --no-build) DO_BUILD=0 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数: $arg（用 --help 查看用法）"; exit 1 ;;
  esac
done

cd "$REPO_DIR" || { echo "找不到仓库目录: $REPO_DIR"; exit 1; }

say() { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()  { echo -e "  \033[32m✓\033[0m $*"; }
warn(){ echo -e "  \033[33m!\033[0m $*"; }
err(){ echo -e "  \033[31m✗\033[0m $*"; }

# ---------------------------------------------------------------- 1. 拉上游
say "1/5 拉取上游更新"
git remote set-url upstream "$UPSTREAM" 2>/dev/null || git remote add upstream "$UPSTREAM"
git remote set-url origin "$FORK"     2>/dev/null || git remote add origin "$FORK"
git fetch --prune upstream 2>&1 | tail -3
git fetch --prune origin   2>&1 | tail -3

OLD=$(git rev-parse upstream/main)
NEW=$(git rev-parse upstream/main)
ok "上游 main = ${NEW:0:8}  ($(git log -1 --format=%s upstream/main))"

if [ "$OLD" != "$NEW" ]; then :; fi
COMMITS=$(git log --oneline @{u}..upstream/main 2>/dev/null | wc -l)
ok "待同步提交数（相对 origin/main）: $COMMITS"

# ------------------------------------------------- 2. 重置 main 镜像上游
say "2/5 让 fork 的 main 镜像上游 main"
git checkout -q main
git reset --hard upstream/main
# 注意：不能在已 checkout 的分支上用 `git branch -f`（会报
# "cannot force update the branch used by worktree"）。reset --hard 已经对齐，
# 分支指针本身就指向 upstream/main，无需额外操作。
ok "main 已对齐 upstream/main ($(git rev-parse --short HEAD))"

# ------------------------------------- 3. 把自己的分支 rebase 到最新上游
say "3/5 rebase $FEATURE_BRANCH 到最新上游"
git checkout -q "$FEATURE_BRANCH" 2>/dev/null || git checkout -q -b "$FEATURE_BRANCH" upstream/main

if git diff --quiet upstream/main HEAD; then
  warn "分支与上游无差异，跳过 rebase"
else
  # rebase 前先备份，出问题可回退
  BACKUP="backup/$(date +%Y%m%d-%H%M%S)"
  git branch "$BACKUP" HEAD 2>/dev/null && ok "已备份到分支 $BACKUP"

  if git rebase upstream/main; then
    ok "rebase 成功，无冲突"
  else
    err "rebase 出现冲突！"
    echo ""
    echo "  冲突文件："
    git diff --name-only --diff-filter=U | sed 's/^/    /'
    echo ""
    echo "  解决步骤："
    echo "    1) 编辑冲突文件，把 <<<<<<< / ======= / >>>>>>> 标记去掉，"
    echo "       保留「上游的新内容」+「你自己的改动」两者"
    echo "    2) git add <文件> && git rebase --continue"
    echo "    3) 重复直到完成；想放弃则 git rebase --abort"
    echo ""
    exit 2
  fi
fi

echo ""
echo "  当前与上游的差异（应只有你自己的文件）："
git diff --stat upstream/main | sed 's/^/    /'

# ------------------------------------------------------- 4. 本地静态校验
say "4/5 本地静态校验"
if [ -x "$(dirname "$0")/verify.sh" ]; then
  if "$(dirname "$0")/verify.sh"; then
    ok "静态校验通过"
  else
    err "静态校验未通过，终止推送"
    exit 3
  fi
else
  warn "未找到 verify.sh，跳过"
fi

# ------------------------------------------------------------- 5. 推送
if [ "$DO_PUSH" -eq 1 ]; then
  say "5/5 推送到你的 fork"
  # 需要 GITHUB_TOKEN 或已配置的 git 凭据
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    export GIT_ASKPASS=/dev/null
    AUTH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/zhangxiao439/subcase.git"
  else
    AUTH_URL="$FORK"
  fi

  git push "$AUTH_URL" "main:refs/heads/main" --force 2>&1 | tail -3
  if [ ${PIPESTATUS[0]} -eq 0 ]; then
    ok "main 已推送"
  else
    err "main 推送失败（需要设置 GITHUB_TOKEN 或配置 git 凭据）"
    exit 4
  fi

  # feature 分支是 rebase 后的改写，远端旧 sha 与本地 remote-tracking 引用可能不一致，
  # 裸 --force-with-lease 会报 "stale info"。这里显式指定远端当前 sha 作为 lease 基准，
  # 既能推送 rebase 后的历史，又保留「远端被别人改过就拒绝」的保护。
  git fetch -q origin 2>/dev/null
  REMOTE_SHA=$(git ls-remote "$AUTH_URL" "refs/heads/$FEATURE_BRANCH" 2>/dev/null | awk '{print $1}')
  if [ -n "$REMOTE_SHA" ]; then
    git push --force-with-lease="$FEATURE_BRANCH:$REMOTE_SHA" \
      "$AUTH_URL" "$FEATURE_BRANCH:refs/heads/$FEATURE_BRANCH" 2>&1 | tail -3
  else
    # 远端还没有这个分支，直接建
    git push "$AUTH_URL" "$FEATURE_BRANCH:refs/heads/$FEATURE_BRANCH" 2>&1 | tail -3
  fi
  if [ ${PIPESTATUS[0]} -eq 0 ]; then
    ok "$FEATURE_BRANCH 已推送"
  else
    err "$FEATURE_BRANCH 推送失败"
    exit 4
  fi
else
  say "5/5 跳过推送 (--no-push)"
fi

# ------------------------------------------------------------- 6. 构建
if [ "$DO_BUILD" -eq 1 ]; then
  say "附加 云端构建"
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    warn "未设置 GITHUB_TOKEN，无法自动拉取构建产物"
    echo "  手动查看: https://github.com/zhangxiao439/subcase/actions"
  else
    export GITHUB_TOKEN
    python3 "$(dirname "$0")/fetch_apk.py" "$FEATURE_BRANCH" 2>&1 | tail -20
  fi
fi

say "完成"
echo "  fork: https://github.com/zhangxiao439/subcase"
echo "  分支: main（=上游） / $FEATURE_BRANCH（=上游 + 你的自定义后端改动）"
