#!/usr/bin/env bash
#
# test.sh —— 用 gone 工具链跑 !err 测试套件。
#
#   scripts/build-toolchain.sh --fast --force
#   scripts/test.sh --toolchain ./gone-go
#
# test/cases/   每个目录: main.gone + want(期望 stdout)
#               要求编译运行成功, 且 stdout 与 want 完全一致
# test/reject/  每个目录: main.gone + want(期望的错误信息, 含行列号)
#               要求编译失败, 且报错与 want 完全一致
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
toolchain="${GONE_GOROOT:-}"
filter=""

usage() {
	cat <<EOF
用法: $(basename "$0") --toolchain DIR [--filter SUBSTR]

选项:
  --toolchain DIR    gone 工具链目录 (build-toolchain.sh 的产物)
  --filter SUBSTR    只跑名字里含 SUBSTR 的用例
  -h, --help         显示本帮助
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--toolchain)
		toolchain="$2"
		shift
		;;
	--filter)
		filter="$2"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "未知参数: $1" >&2
		usage
		exit 2
		;;
	esac
	shift
done

if [ -z "$toolchain" ]; then
	usage
	exit 2
fi
toolchain="$(cd "$toolchain" && pwd)"
go_bin="$toolchain/bin/go"
if [ ! -x "$go_bin" ]; then
	echo "error: $go_bin 不存在或不可执行" >&2
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

report() { # name ok detail
	if [ "$2" = 1 ]; then
		pass=$((pass + 1))
		printf 'ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf 'FAIL %s\n' "$1"
		if [ -n "${3:-}" ]; then
			printf '%s\n' "$3" | sed 's/^/     /'
		fi
	fi
}

setup_dir() { # $1 = main.gone 源文件, $2 = 目标目录
	mkdir -p "$2"
	printf 'module gonetest\n\ngo 1.27\n' >"$2/go.mod"
	# TODO(M2): 目前 go build 还不能识别 .gone 扩展名, 所以先改名成 .go 再交给编译器。
	# 语法糖本身完全由 cmd/compile 实现, 与扩展名无关。
	cp "$1" "$2/main.go"
}

run_cases() {
	local dir name tmp out rc want
	for dir in "$repo_root"/test/cases/*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then continue; fi

		tmp="$work/case-$name"
		setup_dir "$dir/main.gone" "$tmp"
		set +e
		out="$(cd "$tmp" && GOROOT="$toolchain" "$go_bin" run . 2>&1)"
		rc=$?
		set -e
		want="$(cat "$dir/want")"

		if [ "$rc" -ne 0 ]; then
			report "$name" 0 "编译/运行失败 (exit=$rc):
$out"
			continue
		fi
		if [ "$out" != "$want" ]; then
			report "$name" 0 "stdout 不一致:
  得到: $(printf '%q' "$out")
  期望: $(printf '%q' "$want")"
			continue
		fi
		report "$name" 1
	done
}

run_rejects() {
	local dir name tmp out rc want got
	for dir in "$repo_root"/test/reject/*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then continue; fi

		tmp="$work/reject-$name"
		setup_dir "$dir/main.gone" "$tmp"
		set +e
		out="$(cd "$tmp" && GOROOT="$toolchain" "$go_bin" build . 2>&1)"
		rc=$?
		set -e
		want="$(cat "$dir/want")"
		# 只保留 main.go:行:列: 消息 形式的报错行, 并去掉 ./ 前缀
		got="$(printf '%s\n' "$out" | sed -nE 's#^(\./)?(main\.go:[0-9]+:[0-9]+: .*)$#\2#p')"

		if [ "$rc" -eq 0 ]; then
			report "$name" 0 "期望编译失败, 但成功了"
			continue
		fi
		if [ "$got" != "$want" ]; then
			report "$name" 0 "报错不一致:
  得到: $(printf '%q' "$got")
  期望: $(printf '%q' "$want")
  原始输出:
$out"
			continue
		fi
		report "$name" 1
	done
}

echo ">> 工具链: $toolchain"
echo ">> 版本: $(GOROOT="$toolchain" "$go_bin" version)"
echo

run_cases
run_rejects

echo
echo ">> 通过 $pass, 失败 $fail"
[ "$fail" -eq 0 ]
