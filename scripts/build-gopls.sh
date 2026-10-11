#!/usr/bin/env bash
#
# build-gopls.sh —— 用 gone 工具链 + 打过补丁的 x/tools 构建 gopls。
#
# 为什么需要它：
#   1. gopls 把 go/types 静态链接进去了, 官方 gopls 不认识 !err 语法糖,
#      所以必须用 gone 工具链编译(gone 工具链的 go/types 才认识);
#   2. gopls 里还有若干处"只看 .go 后缀"的文件识别(未打开的 .gone 文件、
#      目录扫描、go list 结果过滤...), 需要打上 editors/gopls/*.patch。
#
#   scripts/build-gopls.sh                     # 构建到 ./gone-go/bin/gopls
#   scripts/build-gopls.sh --out /tmp/gopls    # 构建到别处
#   scripts/test.sh --toolchain ./gone-go      # 默认就用 $toolchain/bin/gopls 跑 gopls 套件
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../editors/gopls/VERSION
. "$repo_root/editors/gopls/VERSION"

toolchain="${GONE_GOROOT:-$repo_root/gone-go}"
out=""
cache="${GONE_CACHE:-$repo_root/.cache}"
src_dir=""
force=0

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --toolchain DIR   gone 工具链目录 (默认: $repo_root/gone-go)
  --out FILE        gopls 产物路径 (默认: <toolchain>/bin/gopls)
  --cache DIR       x/tools 源码缓存目录 (默认: $repo_root/.cache)
  --src DIR         使用已有的 x/tools 源码目录, 跳过克隆
  --force           源码缓存已存在时删除重建
  -h, --help        显示本帮助

上游版本记录在 editors/gopls/VERSION (当前 $GONE_GOPLS_TAG)。
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--toolchain)
		toolchain="$2"
		shift
		;;
	--out)
		out="$2"
		shift
		;;
	--cache)
		cache="$2"
		shift
		;;
	--src)
		src_dir="$2"
		shift
		;;
	--force) force=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "未知参数: $1 (用 --help 查看用法)" ;;
	esac
	shift
done

toolchain="$(cd "$toolchain" && pwd)"
go_bin="$toolchain/bin/go"
[ -x "$go_bin" ] || die "$go_bin 不存在; 先跑 scripts/build-toolchain.sh"
[ -n "$out" ] || out="$toolchain/bin/gopls"
command -v git >/dev/null 2>&1 || die "需要 git 来克隆 x/tools"

# ---------------------------------------------------------------- 源码准备 ---
if [ -n "$src_dir" ]; then
	src_dir="$(cd "$src_dir" && pwd)"
	[ -d "$src_dir/gopls" ] || die "$src_dir 看起来不是 x/tools 源码目录"
else
	mkdir -p "$cache"
	src_dir="$cache/tools-$(echo "$GONE_GOPLS_TAG" | tr '/' '-')"
	if [ -d "$src_dir/.git" ] && [ "$force" = 1 ]; then
		echo ">> 删除已有源码 $src_dir"
		rm -rf "$src_dir"
	fi
	if [ ! -d "$src_dir/.git" ]; then
		echo ">> 克隆 $GONE_X_TOOLS_REPO ($GONE_GOPLS_TAG)"
		rm -rf "$src_dir"
		git clone -q --depth 1 --branch "$GONE_GOPLS_TAG" "$GONE_X_TOOLS_REPO" "$src_dir"
	fi
fi

head_sha="$(git -C "$src_dir" rev-parse HEAD)"
echo ">> x/tools: $src_dir @ $head_sha ($GONE_GOPLS_TAG)"
if [ -n "${GONE_X_TOOLS_COMMIT:-}" ] && [ "$head_sha" != "$GONE_X_TOOLS_COMMIT" ]; then
	echo "!! 注意: VERSION 里钉的是 $GONE_X_TOOLS_COMMIT, 补丁是按那个提交生成的" >&2
fi

# ------------------------------------------------------------------ 打补丁 ---
# 补丁相对 x/tools 根目录 (-p1), 重复执行是幂等的: 先看能不能反向应用。
shopt -s nullglob
patches=("$repo_root"/editors/gopls/*.patch)
shopt -u nullglob
[ "${#patches[@]}" -gt 0 ] || die "editors/gopls/ 下没有补丁"

for p in "${patches[@]}"; do
	if git -C "$src_dir" apply --check --reverse "$p" >/dev/null 2>&1; then
		echo ">> 补丁已应用: $(basename "$p")"
		continue
	fi
	echo ">> 应用补丁 $(basename "$p")"
	git -C "$src_dir" apply --whitespace=nowarn "$p" ||
		patch -d "$src_dir" -p1 -N --fuzz=3 <"$p" ||
		die "补丁 $(basename "$p") 应用失败"
done

# -------------------------------------------------------------------- 构建 ---
echo ">> 用 $(GOROOT="$toolchain" "$go_bin" version) 构建 gopls -> $out"
mkdir -p "$(dirname "$out")"
(cd "$src_dir/gopls" && GOROOT="$toolchain" "$go_bin" build -o "$out" .)

# ------------------------------------------------------------------ 自检 ----
# 一个 .gone 工程, 里面既有语法糖, 也有 .gone 写的依赖包:
#   - 工具链不认 .gone / gopls 没打补丁 -> 会报 no Go files 或 missing import
#   - go/types 不认识 !err         -> 会报 non-name !err on left side of :=
# 所以这条自检同时验证了工具链和补丁。
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/lib"
printf 'module gonegoplscheck\n\ngo 1.27\n' >"$check_dir/go.mod"
cat >"$check_dir/main.gone" <<'EOF'
package main

import (
	"fmt"

	"gonegoplscheck/lib"
)

func main() {
	v, !err := lib.Double(21)
	fmt.Println(v)
}
EOF
cat >"$check_dir/lib/lib.gone" <<'EOF'
package lib

func Double(x int) (int, error) { return 2 * x, nil }
EOF

# 自检优先走 LSP(test/gopls/lsp_probe.py): 命令行子命令只加载被点名的文件,
# 抓不到"未打开文件/依赖包没被识别"这类问题, 而 LSP 路径能稳定复现。
# 没有 python3 时退回 gopls check: 能验证工具链, 但补丁缺失可能漏掉。
probe="$repo_root/test/gopls/lsp_probe.py"
if command -v python3 >/dev/null 2>&1 && [ -f "$probe" ]; then
	echo ">> 自检(LSP): 打开一个含语法糖的 .gone 工程, 期望零诊断"
	set +e
	self_check="$(
		cd "$check_dir" &&
			GOROOT="$toolchain" PATH="$toolchain/bin:$PATH" GOPLSCACHE="$check_dir/cache" \
				python3 "$probe" --gopls "$out" --root "$check_dir" main.gone 2>&1
	)"
	rc=$?
	set -e
else
	echo ">> 自检(check): 没有 python3, 退回 gopls check"
	set +e
	self_check="$(
		cd "$check_dir" &&
			GOROOT="$toolchain" GOPLSCACHE="$check_dir/cache" \
				"$out" check ./main.gone 2>&1
	)"
	rc=$?
	set -e
fi
if [ "$rc" -ne 0 ] || [ -n "$self_check" ]; then
	die "自检失败 (exit=$rc):
$self_check

检查一下: 这份 gopls 是不是用 gone 工具链构建的? GOROOT 是否指向 $toolchain?
(如果这里报 missing import / no Go files, 说明补丁没生效;
 如果报 non-name !err, 说明用的是官方工具链的 go/types)"
fi

echo
echo ">> 完成: $out"
GOROOT="$toolchain" "$out" version
cat <<EOF

接到编辑器里:
  VSCode  用 editors/vscode-gone/ 的扩展(或手动设)
          "go.goroot": "$toolchain"
          "go.alternateTools": { "gopls": "$out" }
  Neovim  让 gopls 走这份二进制, 并保证 GOROOT=$toolchain
  Vim     见 editors/vim/gone.vim
EOF
