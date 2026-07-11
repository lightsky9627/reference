#!/usr/bin/env bash
# 通用「构建产物打包 + 上传」脚本
#
# 用法：
#   bash scripts/upload-artifact.sh                          # 自动探测产物目录
#   bash scripts/upload-artifact.sh <构建产物目录>            # 手动指定目录（最高优先级）
#   bash scripts/upload-artifact.sh <构建产物目录> <transfer.sh 地址>
#
# 环境变量（都可选，用来覆盖默认行为）：
#   OUTPUT_DIR      手动指定产物目录，等价于第一个参数，优先级低于位置参数
#   TRANSFER_URL    transfer.sh 地址，等价于第二个参数
#   PROJECT_NAME    强制指定项目名（不指定则自动探测）
#
# 这是一个全新文件，不修改仓库里任何已有文件，
# 拉取上游更新时不会产生冲突。
set -euo pipefail

# ---------- 1. 确定产物目录 ----------
# 优先级：位置参数 > OUTPUT_DIR 环境变量 > 自动探测常见目录名
CANDIDATE_DIRS=(build dist out output public www ".output/public" ".next" ".vercel/output/static")

BUILD_DIR="${1:-${OUTPUT_DIR:-}}"

if [ -z "${BUILD_DIR}" ]; then
  echo "🔍 未指定产物目录，自动探测中..."
  FOUND=""
  MATCHES=()
  for d in "${CANDIDATE_DIRS[@]}"; do
    if [ -d "$d" ] && [ -n "$(find "$d" -maxdepth 3 -type f 2>/dev/null | head -n 1)" ]; then
      MATCHES+=("$d")
    fi
  done

  if [ "${#MATCHES[@]}" -eq 0 ]; then
    echo "❌ 没找到任何非空的常见产物目录（${CANDIDATE_DIRS[*]}）。"
    echo "   请手动指定：bash scripts/upload-artifact.sh <你的产物目录>"
    exit 1
  elif [ "${#MATCHES[@]}" -eq 1 ]; then
    FOUND="${MATCHES[0]}"
    echo "   -> 用 ${FOUND}"
  else
    # 多个候选目录都存在（比如同时有 build 和 dist 的历史遗留文件）时，
    # 不猜，直接报错，让用户显式指定，避免打包错内容。
    echo "⚠️  探测到多个可能的产物目录：${MATCHES[*]}"
    echo "   为避免打包错内容，请手动指定：bash scripts/upload-artifact.sh <你的产物目录>"
    exit 1
  fi
  BUILD_DIR="$FOUND"
fi

TRANSFER_URL="${2:-${TRANSFER_URL:-https://send.bravexist.cn}}"

if [ ! -d "$BUILD_DIR" ]; then
  echo "❌ 构建产物目录不存在: $BUILD_DIR"
  exit 1
fi

# ---------- 2. 环境检查 ----------
if ! command -v curl >/dev/null 2>&1; then
  echo "⚠️  当前构建环境没有 curl，跳过上传（产物仍在 ${BUILD_DIR}，会被正常部署）"
  exit 0
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "⚠️  当前构建环境没有 tar，跳过上传"
  exit 0
fi

# ---------- 3. 确定项目名 ----------
# 优先级：PROJECT_NAME 环境变量 > 各平台自动注入的变量 > package.json 的 name 字段 > 当前目录名
PROJECT_NAME="${PROJECT_NAME:-${CF_PAGES_PROJECT_NAME:-${VERCEL_GIT_REPO_SLUG:-}}}"
if [ -z "$PROJECT_NAME" ] && [ -f package.json ] && command -v node >/dev/null 2>&1; then
  PROJECT_NAME="$(node -p "require('./package.json').name || ''" 2>/dev/null || true)"
fi
PROJECT_NAME="${PROJECT_NAME:-$(basename "$(pwd)")}"
# 项目名可能带 @scope/ 或非法文件名字符，清理一下
PROJECT_NAME="$(echo "$PROJECT_NAME" | sed 's#[@/]#-#g; s/^-*//')"

# ---------- 4. 打包上传 ----------
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="${PROJECT_NAME}-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="/tmp/${ARCHIVE_NAME}"

echo "📦 打包 ${BUILD_DIR}/ -> ${ARCHIVE_NAME}"
tar -czf "$ARCHIVE_PATH" -C "$BUILD_DIR" .

ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1)"
echo "   压缩包大小: ${ARCHIVE_SIZE}"

echo "☁️  上传到 ${TRANSFER_URL} ..."
# --fail 保证 curl 拿到 4xx/5xx 时返回非 0，不至于把错误页面当成下载链接打印出去
if DOWNLOAD_URL="$(curl -fsS --upload-file "$ARCHIVE_PATH" "${TRANSFER_URL%/}/${ARCHIVE_NAME}")"; then
  echo ""
  echo "=================================================="
  echo "✅ 构建产物已上传，下载地址（复制到浏览器 / curl -O 均可）："
  echo "${DOWNLOAD_URL}"
  echo "=================================================="
  echo ""
else
  echo "⚠️  上传失败，构建产物仍会被正常部署，只是没有额外的下载链接"
fi

rm -f "$ARCHIVE_PATH"