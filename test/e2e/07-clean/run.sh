set -e
# 模拟 go build 留下的可执行文件/测试可执行文件, 名字由源文件名推出
touch prog prog.exe prog.test prog.test.exe
"$GO" clean
for f in prog prog.exe prog.test prog.test.exe; do
	if [ -e "$f" ]; then echo "$f 还在"; else echo "$f 已删除"; fi
done
