#!/usr/bin/env bash
#
# check.sh —— 编译并用普通 node 跑工具链判定的冒烟测试(不需要 VSCode)。
#
#   editors/vscode-gone/check.sh <gone-toolchain> [不是 gone 的工具链 ...]
#
set -euo pipefail
caller_pwd="$PWD"
cd "$(dirname "${BASH_SOURCE[0]}")"
[ $# -ge 1 ] || {
	echo "用法: $0 <gone-toolchain> [不是 gone 的工具链 ...]" >&2
	exit 2
}
if [ ! -d node_modules ]; then
	echo ">> npm install"
	npm install --no-audit --no-fund --silent
fi
npx --no-install tsc -p .

# 参数里的相对路径是相对"调用者所在目录"的, 这里先转成绝对路径
abs=()
for arg in "$@"; do
	case "$arg" in
	/*) abs+=("$arg") ;;
	*) abs+=("$caller_pwd/$arg") ;;
	esac
done
node test/check-toolchain.js "${abs[@]}"
