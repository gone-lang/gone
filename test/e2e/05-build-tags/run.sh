set -e
# GOOS/GOARCH 后缀与 //go:build 约束对 .gone 一样生效
"$GO" run .
"$GO" list -f 'GoFiles: {{join .GoFiles " "}}' .
"$GO" list -f 'IgnoredGoFiles: {{join .IgnoredGoFiles " "}}' .
