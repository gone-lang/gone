set -e
# 显式把 .gone 文件当命令行参数 (go run/go build 的文件模式)
"$GO" run main.gone util.gone
"$GO" build main.gone util.gone
# exeFromFiles: 可执行文件名应当是第一个源文件去掉扩展名
if [ ! -x ./main ]; then
	echo "没有生成可执行文件 ./main"
	exit 1
fi
./main
rm -f ./main
# _test.gone 不能交给 go run
"$GO" run util_test.gone 2>&1 | sed 's/^go: //'
