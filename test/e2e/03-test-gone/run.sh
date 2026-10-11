set -e
cd lib
# 通过的测试: -v 的耗时字段不可预测, 统一替换掉
"$GO" test -count=1 -v -run TestDouble . | sed -E 's/\([0-9.]+s\)/(X)/' | grep -E '^(--- PASS|[[:space:]]*PASS$)'
# 失败的测试: 确认 _test.gone 真的被执行了
set +e
out="$("$GO" test -count=1 -run TestBad . 2>&1)"
rc=$?
set -e
printf '%s\n' "$out" | sed -E 's/\([0-9.]+s\)/(X)/' | grep -E '^(--- FAIL|[[:space:]]*FAIL$)'
echo "rc=$rc"
