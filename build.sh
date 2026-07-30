#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

IMAGE_NAME="${IMAGE_NAME:-oracle/database:11.2.0.4-ee}"
PLATFORM="${PLATFORM:-linux/amd64}"
ZIP1="database/p13390677_112040_Linux-x86-64_1of7.zip"
ZIP2="database/p13390677_112040_Linux-x86-64_2of7.zip"

echo "=========================================="
echo "Oracle 11.2.0.4 Docker 镜像构建"
echo "项目目录：$PROJECT_DIR"
echo "镜像名称：$IMAGE_NAME"
echo "目标平台：$PLATFORM"
echo "安装介质：$ZIP1"
echo "        $ZIP2"
echo "=========================================="

for ZIP in "$ZIP1" "$ZIP2"; do
    if [[ ! -f "$ZIP" ]]; then
        echo "错误：找不到安装介质：$ZIP"
        echo
        echo "请将官方发布的 Oracle Database 11.2.0.4 Linux x86-64 安装包放到："
        echo "  $PROJECT_DIR/database/"
        exit 1
    fi
    if [[ ! -s "$ZIP" ]]; then
        echo "错误：安装介质文件为空：$ZIP"
        exit 1
    fi
done

echo
echo "安装介质信息："
ls -lh "$ZIP1" "$ZIP2"

echo
echo "计算 SHA-256："
shasum -a 256 "$ZIP1" "$ZIP2"

echo
echo "检查 zip 完整性："
for ZIP in "$ZIP1" "$ZIP2"; do
    if ! unzip -tq "$ZIP" >/dev/null; then
        echo "错误：zip 文件损坏或无法读取：$ZIP"
        exit 1
    fi
done

echo "zip 完整性检查通过"

# 检查 Oracle 安装入口是否存在
# 注意：不能写成 `unzip -l "$ZIP1" | grep -q ...`。grep -q 一旦匹配会立刻
# 关闭管道退出，unzip 因此被 SIGPIPE 提前终止（退出码 141），在 set -o
# pipefail 下会让整条管道判定为失败，即使 grep 确实匹配到了。这里先把
# 列表读入变量再 grep，彻底绕开管道。
ZIP1_LISTING="$(unzip -l "$ZIP1")"
if ! grep -q ' database/runInstaller$' <<<"$ZIP1_LISTING"; then
    echo "错误：$ZIP1 中未找到 database/runInstaller"
    echo
    echo "正确的第一个压缩包应包含："
    echo "  database/runInstaller"
    echo "  database/stage/"
    echo "  database/install/"
    exit 1
fi

echo "已找到 database/runInstaller"

BUILD_ARGS=(
    docker build
    --platform "$PLATFORM"
    --progress=plain
    -t "$IMAGE_NAME"
)

# 支持 ./build.sh --no-cache
if [[ "${1:-}" == "--no-cache" ]]; then
    BUILD_ARGS+=(--no-cache)
elif [[ -n "${1:-}" ]]; then
    echo "错误：不支持的参数：$1"
    echo "用法："
    echo "  ./build.sh"
    echo "  ./build.sh --no-cache"
    exit 1
fi

BUILD_ARGS+=(.)

echo
echo "开始构建："
printf ' %q' "${BUILD_ARGS[@]}"
echo
echo

"${BUILD_ARGS[@]}"

echo
echo "=========================================="
echo "镜像构建成功"
echo "镜像名称：$IMAGE_NAME"
echo "=========================================="

docker image inspect "$IMAGE_NAME" \
    --format '镜像ID：{{.Id}}{{println}}创建时间：{{.Created}}{{println}}平台：{{.Os}}/{{.Architecture}}'
