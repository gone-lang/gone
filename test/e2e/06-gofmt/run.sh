set -e
echo "gofmt -l:"
"$GOFMT" -l .
echo "go fmt:"
"$GO" fmt . 2>&1 | sort
echo "gofmt -l (再来一次):"
"$GOFMT" -l .
echo "格式化结果:"
cat a.gone
