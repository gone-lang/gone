#!/usr/bin/env bash
#
# build.sh —— 编译并打包 VSCode 扩展(产出 .vsix, 不发布到市场)。
#
#   editors/vscode-gone/build.sh
#
# 需要 node/npm, 首次会下载 typescript / @types/* / @vscode/vsce。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v npm >/dev/null 2>&1 || {
	echo "error: 需要 npm (node >= 18)" >&2
	exit 1
}

echo ">> npm install"
npm install --no-audit --no-fund --silent

echo ">> tsc"
npx --no-install tsc -p .

echo ">> 打包 .vsix"
npx --yes @vscode/vsce package --allow-missing-repository --skip-license --out gone.vsix

echo
echo ">> 完成: $(pwd)/gone.vsix"
echo ">> 安装: code --install-extension gone.vsix   (或在扩展面板里 Install from VSIX)"
