#!/usr/bin/env bash
#
# build-toolchain.sh —— 构建带 !err 语法糖的 gone Go 工具链。
#
# 产物是一个完整的 GOROOT, 用法和普通 Go 一样:
#
#   export GOROOT="$PWD/gone-go"
#   export PATH="$GOROOT/bin:$PATH"
#   go build ./...
#
# 两种模式:
#   默认     下载官方 go<VERSION>.src.tar.gz(校验 sha256), 打上 toolchain/*.patch,
#            再用 make.bash 完整自举(约 1~2 分钟)
#   --fast   复制本机已装 Go 的 GOROOT, 打上补丁后只重建 cmd/compile(约 20 秒)
#            适合开发迭代; 产物里除 compile 之外都是本机原版工具
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../toolchain/VERSION
. "$repo_root/toolchain/VERSION"

mode=full
out="$repo_root/gone-go"
cache="${GONE_CACHE:-$repo_root/.cache}"
bootstrap=""
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
  --fast              快速模式: 复制本机 GOROOT, 只重建 cmd/compile
  --out DIR           产物 GOROOT 目录 (默认: $repo_root/gone-go)
  --cache DIR         下载缓存目录 (默认: $repo_root/.cache)
  --src DIR           使用已有的 Go 源码目录, 跳过下载
  --bootstrap PATH    引导用 go 可执行文件 (默认: PATH 中的 go)
  --force             目标目录已存在时删除重建
  -h, --help          显示本帮助
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--fast) mode=fast ;;
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
	--bootstrap)
		bootstrap="$2"
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

if [ -z "$bootstrap" ]; then
	bootstrap="$(command -v go || true)"
	[ -n "$bootstrap" ] || die "PATH 中找不到 go, 请用 --bootstrap 指定引导工具链"
fi

# 后面会 cd 进 $out/src, 相对路径会失效, 这里先绝对化
abspath() {
	local d b
	d="$(dirname "$1")"
	b="$(basename "$1")"
	if [ -d "$d" ]; then
		printf '%s/%s\n' "$(cd "$d" && pwd)" "$b"
	else
		printf '%s/%s\n' "$PWD" "$1"
	fi
}
out="$(abspath "$out")"
cache="$(abspath "$cache")"

apply_patches() {
	local dir="$1" p
	for p in "$repo_root"/toolchain/*.patch; do
		[ -e "$p" ] || continue
		echo ">> 应用补丁 $(basename "$p")"
		if [ -d "$dir/.git" ] && command -v git >/dev/null 2>&1; then
			git -C "$dir" apply --whitespace=nowarn "$p" || patch -d "$dir" -p1 -N --fuzz=3 <"$p"
		else
			patch -d "$dir" -p1 -N --fuzz=3 <"$p"
		fi
	done
}

prepare_out() {
	if [ -e "$out" ]; then
		[ "$force" = 1 ] || die "$out 已存在, 加 --force 覆盖"
		rm -rf "$out"
	fi
	mkdir -p "$(dirname "$out")"
}

build_full() {
	prepare_out
	mkdir -p "$cache"
	local tarball="$cache/$GONE_GO_SRC"

	if [ -n "$src_dir" ]; then
		[ -d "$src_dir/src" ] || die "$src_dir 看起来不是 Go 源码目录"
		echo ">> 复制源码 $src_dir -> $out"
		cp -a "$src_dir" "$out"
	else
		if [ ! -f "$tarball" ]; then
			echo ">> 下载 $GONE_GO_SRC_URL"
			curl -fL --retry 3 -o "$tarball.part" "$GONE_GO_SRC_URL"
			mv "$tarball.part" "$tarball"
		fi
		local got_sha
		got_sha="$(sha256sum "$tarball" | cut -d' ' -f1)"
		if [ -n "${GONE_GO_SRC_SHA256:-}" ] && [ "$GONE_GO_SRC_SHA256" != "$got_sha" ]; then
			die "源码包 sha256 不匹配: 期望 $GONE_GO_SRC_SHA256, 实际 $got_sha"
		fi
		echo ">> 解包 $tarball"
		local tmp
		tmp="$(mktemp -d "$cache/extract.XXXXXX")"
		tar -C "$tmp" -xzf "$tarball"
		mv "$tmp/go" "$out"
		rm -rf "$tmp"
	fi

	echo ">> 源码版本: $(cat "$out/VERSION")"
	apply_patches "$out"

	local bootstrap_goroot
	bootstrap_goroot="$("$bootstrap" env GOROOT 2>/dev/null || true)"
	[ -n "$bootstrap_goroot" ] || bootstrap_goroot="$(dirname "$(dirname "$bootstrap")")"

	echo ">> make.bash (GOROOT_BOOTSTRAP=$bootstrap_goroot)"
	(cd "$out/src" && GOROOT_BOOTSTRAP="$bootstrap_goroot" ./make.bash)
}

build_fast() {
	command -v patch >/dev/null 2>&1 || die "快速模式需要 patch 命令"
	prepare_out

	local pristine goos goarch
	pristine="$("$bootstrap" env GOROOT)"
	[ -n "$pristine" ] && [ -d "$pristine/src" ] || die "找不到本机 GOROOT, 请改用完整模式"
	goos="$("$bootstrap" env GOOS)"
	goarch="$("$bootstrap" env GOARCH)"

	echo ">> 复制 GOROOT $pristine -> $out"
	cp -a "$pristine" "$out"
	chmod -R u+w "$out/src"

	echo ">> 源码版本: $(cat "$out/VERSION")"
	apply_patches "$out"

	echo ">> 重建 cmd/compile -> pkg/tool/${goos}_${goarch}/compile"
	(cd "$out/src" && GOROOT="$out" "$out/bin/go" build -o "$out/pkg/tool/${goos}_${goarch}/compile" ./cmd/compile)
}

if [ "$mode" = fast ]; then
	build_fast
else
	build_full
fi

echo
echo ">> 完成: $out"
echo ">> 版本: $(GOROOT="$out" "$out/bin/go" version)"
cat <<EOF

使用方式:
  export GOROOT="$out"
  export PATH="\$GOROOT/bin:\$PATH"
EOF
