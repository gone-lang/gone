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

已经可以用了。语法糖在 `cmd/compile/internal/syntax`(解析器) 层脱糖, 类型检查器/IR/SSA/链接器一行都不用改,
所以内联、逃逸分析、`-race`、调试信息全都是普通 Go 代码的水平。

编辑器/`go vet` 那边走的是标准库 `go/types`, 所以也一并适配了(只需要改 `go/types`,
`go/parser` 与 `gofmt` 本来就能正确处理 `!err`)。

```bash
# 完整构建: 下载官方 go1.27.2 源码(校验 sha256) → 打补丁 → make.bash 自举(约 1~2 分钟)
scripts/build-toolchain.sh

# 或者快速迭代: 复制本机 GOROOT → 打补丁 → 只重建 cmd/compile(约 3 秒)
scripts/build-toolchain.sh --fast --out ./gone-go --force

# 跑测试套件
scripts/test.sh --toolchain ./gone-go

# 使用
export GOROOT="$PWD/gone-go"
export PATH="$GOROOT/bin:$PATH"
go build ./...
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

### 当前限制

1. 裸 `return` 要求函数结果是具名的(或函数没有结果), 例如要写成
   `func f() (s string, err error)`; 结果未具名时会编译报错。
2. `.gone` 扩展名暂时还不被 `go build` 识别, 需要先改名成 `.go`(见下一条路线图)。
3. gopls 是外部二进制、把 `go/types` 静态链接了进去, 所以要**用 gone 工具链重装一份**:
   `GOROOT=$PWD/gone-go $PWD/gone-go/bin/go install golang.org/x/tools/gopls@latest`;
   现成的官方 gopls 里带的还是原版 `go/types`。(`go vet` 已经随工具链准备好了)

### 路线图

- [x] **M1** 解析器脱糖 `!err`, 重建工具链并验证
- [ ] **M2** `go/build` + 模块扫描识别 `.gone` 扩展名, `go build ./...` 直接吃 `.gone`
- [x] **M3** `go/types` 支持, 让 `go vet` / gopls 认识 `!err`(`go/parser` 与 `gofmt` 本来就无需改动)
- [ ] **M4** 结果未具名时自动 `return zero..., err`; 错误信息打磨
