#!/usr/bin/env bash
#
# test.sh —— 用 gone 工具链跑 !err 测试套件。
#
#   scripts/build-toolchain.sh --fast --out ./gone-go --force
#   scripts/test.sh --toolchain ./gone-go
#
# 五个套件:
#   test/cases/           行为用例 (main.gone + want), go run 后的 stdout 必须与 want 一致
#   test/reject/          非法位置 (main.gone + want), 编译器报错必须与 want 一致 (含行列号)
#   test/vet/             非法/合法 (main.gone + want), go vet 输出必须与 want 一致
#   test/e2e/             .gone 扩展名的端到端用例 (run.sh + want), 脚本 stdout 必须与 want 一致
#   test/tools/*/         用 go/types 的检查器小程序 (main.go + want), stdout 必须与 want 一致
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
gofmt_bin="$toolchain/bin/gofmt"
if [ ! -x "$gofmt_bin" ]; then
	echo "error: $gofmt_bin 不存在或不可执行" >&2
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

selected() { # name
	[ -z "$filter" ] || [[ "$1" == *"$filter"* ]]
}

# 把用例源码放进一个临时 module。
# M2 起 go build 直接识别 .gone 扩展名, 所以按原扩展名复制(.gone / .go 都支持)。
setup_case_dir() { # $1 = 用例目录, $2 = 目标目录
	mkdir -p "$2"
	printf 'module gonetest\n\ngo 1.27\n' >"$2/go.mod"
	cp "$1"/main.* "$2/"
}

# ---------------------------------------------------------------------------
# 套件 1: 行为用例, go run 的 stdout 必须与 want 一致

run_cases() {
	local dir name tmp out rc want
	for dir in "$repo_root"/test/cases/*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		selected "$name" || continue

		tmp="$work/case-$name"
		setup_case_dir "$dir" "$tmp"
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

# ---------------------------------------------------------------------------
# 套件 2: 非法位置, 编译器报错必须与 want 一致

run_rejects() {
	local dir name tmp out rc want got
	for dir in "$repo_root"/test/reject/*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		selected "$name" || continue

		tmp="$work/reject-$name"
		setup_case_dir "$dir" "$tmp"
		set +e
		out="$(cd "$tmp" && GOROOT="$toolchain" "$go_bin" build . 2>&1)"
		rc=$?
		set -e
		want="$(cat "$dir/want")"
		# 只保留 main.gone|main.go:行:列: 消息 形式的报错行, 并去掉 ./ 前缀
		got="$(printf '%s\n' "$out" | sed -nE 's#^(\./)?(main\.(gone|go):[0-9]+:[0-9]+: .*)$#\2#p')"

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

# ---------------------------------------------------------------------------
# 套件 3: go vet (走 go/types) 的输出必须与 want 一致

run_vet() {
	local dir name tmp out rc want got
	for dir in "$repo_root"/test/vet/*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		selected "$name" || continue

		tmp="$work/vet-$name"
		setup_case_dir "$dir" "$tmp"
		set +e
		out="$(cd "$tmp" && GOROOT="$toolchain" "$go_bin" vet . 2>&1)"
		rc=$?
		set -e
		# go vet 在类型检查失败时会把错误包一层 "vet: " 前缀
		got="$(printf '%s\n' "$out" | sed -nE 's#^(vet: )?(\./)?(main\.(gone|go):[0-9]+:[0-9]+: .*)$#\3#p')"
		want="$(cat "$dir/want")"

		if [ "$got" != "$want" ]; then
			report "$name" 0 "go vet 输出不一致 (exit=$rc):
  得到: $(printf '%q' "$got")
  期望: $(printf '%q' "$want")
  原始输出:
$out"
			continue
		fi
		report "$name" 1
	done
}

# ---------------------------------------------------------------------------
# 套件 4: .gone 端到端用例 (run.sh + want), 在临时 module 里执行脚本并对 stdout 做比对

run_e2e() {
	local dir name tmp out rc want want_rc
	for dir in "$repo_root"/test/e2e/*/; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		selected "$name" || continue

		tmp="$work/e2e-$name"
		mkdir -p "$tmp"
		printf 'module gonetest\n\ngo 1.27\n' >"$tmp/go.mod"
		# 复制用例内容, 跳过 want/rc 这两个期望文件
		(cd "$dir" && tar cf - --exclude=./want --exclude=./rc .) | (cd "$tmp" && tar xf -)

		want_rc=0
		[ -f "$dir/rc" ] && want_rc="$(cat "$dir/rc")"
		want="$(cat "$dir/want")"

		set +e
		out="$(cd "$tmp" && GO="$go_bin" GOFMT="$gofmt_bin" GOROOT="$toolchain" bash "$dir/run.sh" 2>&1)"
		rc=$?
		set -e

		if [ "$rc" -ne "$want_rc" ]; then
			report "$name" 0 "退出码不一致 (exit=$rc, 期望 $want_rc):
$out"
			continue
		fi
		if [ "$out" != "$want" ]; then
			report "$name" 0 "输出不一致:
  得到: $(printf '%q' "$out")
  期望: $(printf '%q' "$want")"
			continue
		fi
		report "$name" 1
	done
}

# ---------------------------------------------------------------------------
# 套件 5: 直接用 go/types 的检查器小程序

run_tools() {
	local dir name tmp out want
	for dir in "$repo_root"/test/tools/*/; do
		[ -d "$dir" ] || continue
		name="tool-$(basename "$dir")"
		selected "$name" || continue

		tmp="$work/$name"
		mkdir -p "$tmp"
		printf 'module gonetest\n\ngo 1.27\n' >"$tmp/go.mod"
		cp -a "$dir"/*.go "$tmp/"
		set +e
		out="$(cd "$tmp" && GOROOT="$toolchain" "$go_bin" run . 2>&1)"
		set -e
		want="$(cat "$dir/want")"

		if [ "$out" != "$want" ]; then
			report "$name" 0 "输出不一致:
  得到: $(printf '%q' "$out")
  期望: $(printf '%q' "$want")"
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
run_vet
run_e2e
run_tools

echo
echo ">> 通过 $pass, 失败 $fail"
[ "$fail" -eq 0 ]
