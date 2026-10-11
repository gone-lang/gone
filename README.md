# 简介

这是一个为 Go 添加 !err 错误处理语法糖的项目, 与 Go 完全兼容(毕竟只是语法糖)

有了它你可以写如下代码, 代码更加紧凑 阅读更轻松

```go
// main.gone
package main

import (
  "fmt"
  "os"
)

func main() {
  body, !err := readSelf()
  fmt.Println("main.go content")
  fmt.Println(body)
}

func readSelf() (content string, err error) {
  body, !err := os.ReadFile("main.go")
  content = string(body)
  return
}

```

如果你喜欢这个想法, 请为这个项目添加一颗 Star , 每颗 Star 都是在表达你的喜爱

越多人喜爱, 就越有可能被尽快实现

编译器会把它展开成等价的普通 Go 代码:

```go
// main.go
package main

import (
  "fmt"
  "os"
)

func main() {
  body, err := readSelf()
  if err != nil {
    return
  }
  fmt.Println("main.go content")
  fmt.Println(body)
}

func readSelf() (content string, err error) {
  body, err := os.ReadFile("main.go")
  if err != nil {
    return
  }
  content = string(body)
  return
}

```

那为什么要单独出一个语言呢?

1. 因为官方不接受这个语法糖 https://github.com/golang/go/issues/62253
2. [代码生成](https://github.com/shynome/err4)有弊端, 断点调试只能在生成后的文件打
3. golang 语言简单, 为其添加这么一个功能应该不算太难, 零基础大概一两个月也能搞定, 所以我来试试

于是就去 fork 了 Go 工具链, 在 `cmd/compile` 的前端解析器里把它做成了真正的语法糖。

## 实现状态

已经可以用了: `!err` 在 `cmd/compile/internal/syntax`(解析器) 层脱糖, 类型检查器/IR/SSA/链接器一行都不用改,
所以内联、逃逸分析、`-race`、调试信息全都是普通 Go 代码的水平。

`go vet` 与编辑器那边走的是标准库 `go/types`, 所以也一并适配了(M3);
`.gone` 扩展名则是在 `go/build` 里提供一个唯一真源 (`build.IsGoFile`), 再把工具链里
所有"这是不是一个 Go 源文件"的判断都改成调它(M2) —— 现在
`go build/run/test/vet/doc`、`gofmt`、`go fmt` 都直接吃 `.gone`:

```console
$ cd example && go run main.gone
main.go content
package main
...
```

编辑器侧也做了(M5): 一份 VSCode 扩展把 `.gone` 并进 Go 语言
(高亮、跳转、补全都来自官方 Go 扩展 + 一份用 gone 工具链构建的 gopls),
外加 Vim/Neovim 的 ftdetect 与 gopls 接法, 详见 [编辑器支持](#编辑器支持)。

```bash
# 完整构建: 下载官方 go1.27.2 源码(校验 sha256) → 打补丁 → make.bash 自举(约 1~2 分钟)
scripts/build-toolchain.sh

# 或者快速迭代: 复制本机 GOROOT → 打补丁 → 只重建 cmd/compile, cmd/vet, cmd/go, cmd/gofmt
scripts/build-toolchain.sh --fast --out ./gone-go --force

# 构建 gopls(打上 editors/gopls/*.patch, 用 gone 工具链编译, 装到 ./gone-go/bin/gopls)
scripts/build-gopls.sh --toolchain ./gone-go

# 跑测试套件(默认会用 <工具链>/bin/gopls 跑 gopls 套件)
scripts/test.sh --toolchain ./gone-go

# 使用(在你自己的项目里)
export GOROOT="$PWD/gone-go"
export PATH="$GOROOT/bin:$PATH"
go build ./...   # 直接吃 .gone 文件
```

详细设计见 [design.md](./design.md)。

### 亮点

- **与 Go 完全兼容**: 合法 Go 程序里, 一元 `!` 表达式永远不会出现在赋值左值上,
  所以语法糖只是把一个"原本非法的位置"赋予了新含义, 不会改变任何现有程序的行为。
- **调试信息正确**: 不插入源码行, 合成节点的位置就是 `!` 所在位置, 行号与源码逐行对应,
  断点直接打在源码上(这正是 [err4](https://github.com/shynome/err4) 这类代码生成的短板)。

### 语法

```go
x, !err := f()            // x, err := f(); if err != nil { return }
x, !e1, !e2 := f()        // if e1 != nil || e2 != nil { return }
var x int
x, !err = f()             // 普通赋值同样支持
```

`!err` 只能用在语句列表里直接出现的赋值语句上; 放在 if/for/switch 的 init/post 或 `select`
的 comm 子句里会明确报错(`!err sugar is not allowed in ...`), 因为这些位置没地方插入错误检查。

### `.gone` 扩展名

`.gone` 与 `.go` 同等对待: 同一个包里两种扩展名可以混着写(会一起编译, 按文件名字母序),
`//go:build` 约束、`_linux`/`_amd64` 这类后缀、`_test.gone` 测试文件都照常工作。
工具链里"哪些文件名算 Go 源码"只有一处定义(`go/build.IsGoFile`), 其余地方都调它。

| 命令 | `.gone` 支持情况 |
|---|---|
| `go build` / `go run` / `go install` | 目录、`./...`、命令行文件参数(`go run main.gone`)、`-o` |
| `go test` | `_test.gone`、`-cover`, `go test` 自带的 vet 也照常跑 |
| `go vet` / `go doc` | 走 `go/types` 与 `go/parser.ParseDir` |
| `gofmt` / `go fmt` | `gofmt -l/-w .`、`go fmt ./...` |
| `go list` / `go clean` / `go mod` | `GoFiles`/`IgnoredGoFiles`、可执行名推导、模块扫描 |

注意 `example/` 目录里并排放着 `main.go` 与 `main.gone`(同一份代码的展开前后),
所以 `main.gone` 加了 `//go:build ignore` 以免重复声明;
`go run main.gone` 走的是命令行文件模式, 不看构建约束, 所以照样能跑。

### 编辑器支持

语法高亮/跳转/补全/诊断这些, 复用官方 Go 扩展 + 一份打过补丁的 gopls 就够了:

```bash
# 用 gone 工具链 + editors/gopls/ 的补丁构建 gopls(默认装到 ./gone-go/bin/gopls)
scripts/build-gopls.sh --toolchain ./gone-go
```

为什么 gopls 也要自己构建: 它把 `go/types` 静态链接进去了, 官方那份不认识 `!err`;
而且 gopls 内部还有几处"只看 `.go` 后缀"的文件识别, 不补的话
`import` 一个用 `.gone` 写的包会报 `missing import ...`(补丁内容见 design.md §3.7)。

**VSCode**: `editors/vscode-gone/` 是一个几十行的小扩展

```bash
editors/vscode-gone/build.sh          # 产出 editors/vscode-gone/gone.vsix
code --install-extension editors/vscode-gone/gone.vsix
```

它把 `.gone` 并进 `go` 语言(沿用内置的 Go 语法高亮与官方 Go 扩展), 并提供两个命令:

- `Gone: 配置 gone 工具链` —— 把 `go.goroot` 和 `go.alternateTools.gopls`
  写进工作区设置, 指向 gone 工具链与上面构建的 gopls;
- `Gone: 环境自检` —— 临时写一个带 `!err` 的 `.gone` 文件编译一下,
  告诉你这份 GOROOT 到底是不是 gone 工具链、gopls 是不是带补丁的那份。

判定"这是不是 gone 工具链"的那段逻辑可以在命令行里单独验(不需要开 VSCode):

```bash
editors/vscode-gone/check.sh ./gone-go /opt/go
# ok   .../gone-go: gone=true (期望 true)
# ok   /opt/go: gone=false (期望 false) — 不认 .gone 语法糖
```

**Vim / Neovim**: 复制 `editors/vim/gone.vim` 到 `~/.vim/ftdetect/`
(Neovim: `~/.config/nvim/ftdetect/`), 让 `.gone` 走 Go 的 filetype;
gopls 的接法见该文件里的注释(要点: 用构建出来的 gopls, `GOROOT` 指向
gone 工具链, 且 `PATH` 里有 `$GOROOT/bin`)。

### 当前限制

1. 裸 `return` 要求函数结果是具名的(或函数没有结果), 例如要写成
   `func f() (s string, err error)`; 结果未具名时会编译报错。
2. `.gone` 只被 gone 工具链识别。换官方工具链就得改名成 `.go`;
   第三方工具(编辑器、gopls、各种 lint)各有各的目录扫描逻辑, 未必认这个扩展名。
   另外 `internal/goroot`(判断"这是不是标准库包")仍只看 `.go`, 标准库本身改写不在支持范围。
3. 编辑器侧要用 `scripts/build-gopls.sh` 构建出来的 gopls(gone 工具链 + x/tools 补丁),
   官方那份不行: 它带的 `go/types` 不认识 `!err`, 文件识别也不认 `.gone`。
   `go vet` 不用管, 它随工具链准备好了。
4. VSCode 官方 Go 扩展内部还有几处 `fileName.endsWith('.go')`(覆盖率装饰、
   生成测试、调试配置等), 这些功能对 `.gone` 不生效; 语言服务器重启、`go.mod`
   换工具链这些仍按 Go 扩展原有逻辑走。

### 路线图

- [x] **M1** 解析器脱糖 `!err`, 重建工具链并验证
- [x] **M2** 工具链识别 `.gone` 扩展名(`go/build`、模块索引、`go` 命令、`go/parser.ParseDir`、`go/doc`、`gofmt`), `go build ./...` 直接吃 `.gone`
- [x] **M3** `go/types` 支持, 让 `go vet` / gopls 认识 `!err`
- [x] **M5** 编辑器侧: VSCode 扩展 + Vim ftdetect + `x/tools`/gopls 补丁 + `build-gopls.sh`
- [ ] **M4** 结果未具名时自动 `return zero..., err`; 错误信息打磨
