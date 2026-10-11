# gone 设计文档

gone = Go + `!err` 错误处理语法糖。本文件记录目标、语法语义、实现方案与里程碑。

---

## 1. 背景与目标

Go 的错误处理样板代码一直是社区痛点（见 [golang/go#62253](https://github.com/golang/go/issues/62253)，
已被官方以 `FrozenDueToAge` 关闭且不计划接受）。

```go
f, err := os.Open(name)
if err != nil {
    return err
}
```

目标：让下面这行代码

```go
f, !err := os.Open(name)
```

在**真正的 Go 编译器**里生效。也就是：

1. **不是**转译器、**不是**代码生成 —— 直接用 `go build` 编译源码本身。
2. **与 Go 完全兼容** —— 任何合法的 Go 程序语义不变。
3. **调试信息正确** —— 断点打在源码（`.gone` / `.go`）上，不是打在生成物上。
   这是否掉 [err4](https://github.com/shynome/err4) 那种 codegen 方案的关键理由。

目标形态（README 里的例子）：

```go
// main.gone
func main() {
    body, !err := readSelf()
    fmt.Println(string(body))
}
```

## 2. 语法与语义

### 2.1 语法

`!` 标记直接出现在赋值语句**左值**中的标识符前面：

```
Assignment = ExpressionList assign_op ExpressionList .
                   ^^^^^^^^^^^^^^ 这里

x, !err := f()      // 短变量声明
x, !err = f()       // 普通赋值
_, !err, !err2 = f() // 多个标记
```

### 2.2 语义

脱糖为「赋值 + 显式错误检查」：

```go
x, !err := f()
```

等价于

```go
x, err := f()
if err != nil {
    return
}
```

多条标记合并成一个条件（按变量名去重）：

```go
x, !e1, !e2 := f()
if e1 != nil || e2 != nil {
    return
}
```

约束：`!err` 只能是**语句列表中直接出现的赋值语句**。因为脱糖会插入一条新语句，
所以 if / for / switch 的 init、post 位置，以及 `select` 的 comm 子句里都没有地方放它，
这些位置会被明确报错（见 §3.3）。

### 2.3 为什么 100% 向后兼容

关键事实：**在合法 Go 程序中，一元 `!` 表达式永远不会出现在赋值左值上。**

- `!x = 1`、`!x := 1` 在 Go 里本来就是语法/类型错误（"non-name !x on left side of :="）。
- 右值里的 `!x` 是正常的布尔取反，脱糖只看左值，完全不碰。

所以：现有合法 Go 程序里不存在会被本语法糖改变语义的写法。
`!` 只是把一个「原本非法的位置」赋予了新含义。

一个佐证：`!err` 在 Go 里**能通过语法分析**，`gofmt` 原样保留，报错发生在类型检查阶段：

```
./main.go:9:8: non-name !err on left side of :=
```

## 3. 实现方案

### 3.1 为什么选「fork 工具链」而不是「转译器」

| 方案 | 行号/调试信息 | 需要 Go 版本升级时 | 生态兼容 |
|---|---|---|---|
| 源码转译器（`.gone` → `.go`） | 可保持 1:1，但 IDE/vet 只认 `.go` | 无 | 需要额外构建步骤 |
| codegen（err4 风格） | **断点只能打在生成文件上** | 无 | 需要 build tag 切换 |
| **fork 工具链（本方案）** | 编译器直接产出，天然正确 | 需要随 Go 版本更新补丁 | `go build` 原生 |

选 fork 工具链：它是唯一能同时满足「真编译器」「调试信息正确」「原生 `go build`」的路。

### 3.2 补丁点 1：`cmd/compile/internal/syntax` 解析器脱糖（编译器侧）

关键在于**在前端最早的一层脱糖**，让类型检查器（types2）和 IR 生成（noder）完全看不到 `!err`：

```
源码 ──▶ syntax 解析器 ──▶ types2 类型检查 ──▶ noder/unified IR ──▶ SSA ──▶ 机器码
              ▲
              └── 只改这里
```

好处：

- **改动面最小**：types2、noder、walk、ssa、链接器一行都不用动。
- **自动获得所有后端能力**：内联、逃逸分析、调试信息、`-race`、泛型……都是普通 Go 代码。
- **补丁只有 2 个文件**（1 个新增 + 3 处小改）。

补丁内容：

| 文件 | 改动 |
|---|---|
| `src/cmd/compile/internal/syntax/errsugar.go` | 新增。识别 `!name`、剥掉 `!`、构造隐式 `if` 语句 |
| `src/cmd/compile/internal/syntax/parser.go` | 3 处钩子：`stmtList` 里脱糖；`simpleStmt`（header 上下文）与 `commClause` 里报错 |

（工具链生态侧的第二个补丁见 §3.5。）

AST 层面就是拼现成节点，没有任何新节点类型：

```go
// x, !err := f()  的 LHS 里，!err 被解析成 Operation{Op: Not, X: Name{err}}
// 脱糖后：Lhs 换成 Name{err}，并在该语句后追加
&IfStmt{
    Cond: &Operation{Op: Neq, X: Name{err}, Y: Name{"nil"}},
    Then: &BlockStmt{List: []Stmt{&ReturnStmt{}}},
}
```

（`nil` 在语法树里就是 `*Name{Value: "nil"}`，类型检查时按预声明对象解析。）

### 3.3 非法位置报错

脱糖会插入新语句，所以只允许出现在语句列表里。其余位置给出明确错误，
而不是让用户看到类型检查器那句困惑的 `non-name !err on left side of :=`：

```
./main.go:6:8: syntax error: !err sugar is not allowed in if statement header
./main.go:6:9: syntax error: !err sugar is not allowed in for statement header
./main.go:6:12: syntax error: !err sugar is not allowed in switch statement header
./main.go:6:10: syntax error: !err sugar is not allowed in select case
```

### 3.4 行号与调试信息

脱糖在 AST 层完成，**不插入任何源码行**，而且合成节点的位置被设为 `!` 标记本身的
`token.Pos`（即那一行的位置）。结果是输出二进制里的行号表与源码**逐行一一对应**：

```
$ go build -gcflags=-S .
0x0034 00052 (/tmp/probe2/main.go:9)  JMP  80     <-- nil 检查
0x0050 00080 (/tmp/probe2/main.go:9)  JEQ  88
0x0057 00087 (/tmp/probe2/main.go:9)  RET
0x0062 00098 (/tmp/probe2/main.go:10) LEAQ ...
```

第 9 行正是 `body, !err := readSelf()`。`dlv` / gdb 在这行下断点即可停在错误检查上。

### 3.5 补丁点 2：`go/types`（让 `go vet` / gopls 也认识语法糖）

编译器改好之后，编辑器和 `go vet` 依然会把语法糖当错误，因为它们走的是标准库
`go/parser` + `go/types`，而不是 `cmd/compile`。

实测结论：**只需要改 `go/types`**。

- `go/parser` 本来就接受 `x, !err := f()`：`!err` 就是一个普通的 `*ast.UnaryExpr`，
  报错要到类型检查阶段才有（`non-name !err on left side of :=`）；
- `go/printer` / `go/format`（即 gofmt）打印 `!err` 正常且幂等，
  所以源码里的语法糖**不会被 gofmt 抹掉**；
- 因此补丁只落在 `src/go/types`。

| 文件 | 改动 |
|---|---|
| `src/go/types/errsugar.go` | 新增。识别并剥离 `!id`、拒绝非法位置、补齐 `Info`（见下） |
| `src/go/types/stmt.go` | 4 处小改：赋值语句处处理语法糖；`simpleStmt` / `labeledStmt` / select comm 三处拒绝 |

只动这两个文件是有意的：`go/types` 里有一部分文件是由 `cmd/compile/internal/types2`
**生成**的（见 `generate_test.go` 的 `filemap`），改它们就必须同步改 types2，
否则 `TestGenerate` 会红。好在 `stmt.go` 不在生成表内、属于 go/types 独有文件，
所以这次完全不用碰 types2 —— 编译器侧本来也不需要，解析器层已经把糖脱掉了。

与编译器不同，这里**不改写 AST**：同一份 AST 可能被**重复类型检查**（gopls 就会这么做）。
如果在 AST 里把 `!err` 就地换成 `err`，第二次检查看到的就是一句普通赋值，
于是开始报 `declared and not used: err`（这个坑实测踩到过，后来专门加了幂等性测试）。

所以做法是：检查时把 `!id` 当成 `id`（改在副本上），同时把 `Info` 补齐，
维持「AST 里的节点在 `Info` 里都有对应项」这个隐含约定：

- `Info.Uses[err] = 变量` —— 隐式检查确实读取了它；
- `Info.Types[!err] = {variable, error 类型}` —— 每个表达式节点都有类型；
- `usedVars[变量] = true` —— 不能被判为「声明但未使用」。

后两条是必需的：`go vet` 的 printf 分析器（`x/tools/refactor/satisfy`）
既要求左值标识符出现在 `Uses` 里，也要求每个表达式节点在 `Types` 里有类型，否则直接 panic。

「只允许出现在语句列表里」这条规则靠**入口检查**实现，而不是给 `stmt` 加 `inList` 参数
（那样会连带改动生成表内的 `range.go`）：在 `simpleStmt`（if/for/switch 的 init 与 post）、
`labeledStmt` 和 select 的 comm 子句三处调用 `rejectErrSugar` —— 它们是仅有的、
语法糖没有落脚点的入口。报错文本与编译器一致
（`!err sugar is not allowed here (only as a direct element of a statement list)`），
位置也一样指向 `!`。

边界：`!_` 不算语法糖，两边一致地报 `cannot use _ as value or type`。
两个小约定：错误码来自 `internal/types/errors`，新文件要照 go/types 的惯例加
`. "internal/types/errors"` 点导入；`check.errorf` 按 `TestErrorCalls` 的要求
至少要带一个格式参数，所以这里用 `check.error`。

### 3.6 补丁点 3：`.gone` 扩展名（`go` 命令侧）

M1 之后编译器已经认识语法糖了，但 `go build` 还不认识 `.gone` 扩展名：
`go build .` 会报 `no Go files`，`go list` 会报 `no Go files`，
连 `go vet`/`go doc`/`gofmt` 也看不到这些文件。M2 就是把「哪些文件名算 Go 源码」
这件事在工具链里补齐。

做法是**收敛到唯一真源**：`go/build` 里的扩展名表 + 两个判断函数，
其余地方一律调它，而不再自己写 `strings.HasSuffix(name, ".go")`：

```go
// src/go/build/build.go
var goFileExts = []string{".go", ".gone"}

func IsGoFile(name string) bool
func IsTestGoFile(name string) bool
```

| 位置 | 改动 |
|---|---|
| `src/go/build/build.go` | 扩展名表 + `IsGoFile`/`IsTestGoFile`；`ImportDir`/`importGo` 等 7 处调用点 |
| `src/cmd/go/internal/modindex/{build,read,scan}.go` | 模块索引（`go list` 的快速路径，是 `go/build` 逻辑的复制品） |
| `src/cmd/go/internal/fsys/fsys.go` | `IsGoDir`：这个目录里有没有 Go 文件 |
| `src/cmd/go/internal/imports/scan.go` | `ScanDir`：扫目录时收集哪些文件 |
| `src/cmd/go/internal/load/pkg.go` | 目录扫描、命令行文件参数、报错文本、可执行名推导 |
| `src/cmd/go/internal/run/run.go` | `go run a.gone` 的文件参数识别、`ExeName` 去扩展名 |
| `src/cmd/go/internal/work/{exec,gc}.go` | vet 配置里 `GoFiles`/`NonGoFiles` 的划分、overlay 重写 |
| `src/cmd/go/internal/{clean,doc,modget,modload,modcmd,base}` | `go clean` 推导要删的可执行名、`go doc` 目录扫描、`go get` 文件名提示、模块扫描、`go mod vendor` 过滤、`IsTestFile` |
| `src/go/parser/interface.go` | `ParseDir`（`go doc` 依赖它）。go/parser 不能 import go/build（go/build import 了 go/parser），所以本地复制一份 `isGoFile` |
| `src/go/doc/{doc,headscan}.go` | `NewFromFiles` 的文件分类 |
| `src/cmd/gofmt/gofmt.go` | `gofmt -l/-w`、`go fmt` 的目录遍历 |

踩到的坑：

1. **`go list` 会绕开 `go/build`。** 修好 `go/build` 之后 `ImportDir` 已经能返回
   `GoFiles=[main.gone]`，但 `go list` 还是报
   `package m2 is not in std (/…/src/m2)` —— 因为 `modload.dirInModule` 判断
   「这个目录里到底有没有 Go 文件」时走的是 `modindex.GetPackage(...).IsGoDir()`
   或 `fsys.IsGoDir()`，而这两个都是只看 `.go` 后缀的独立实现。
   把 modindex（模块索引）和 fsys 一起改掉之后，`go build/run/list/vet/test` 才全部通。
   —— 这也是为什么这轮补丁落点看着多：同一句后缀判断在 cmd/go 里有好几份副本。
2. **构建约束与 `GOOS`/`GOARCH` 后缀天然可用。** `matchFile`/`goodOSArchFile`
   都是先 `strings.Cut(name, ".")` 去掉扩展名再判断，与扩展名长度无关，
   所以 `impl_linux.gone`、`//go:build windows`、`//go:build ignore` 的行为和 `.go` 完全一致
   （`test/e2e/05-build-tags` 覆盖）。

语义约定：

- `.gone` 与 `.go` **同等对待**，同一个包里两种扩展名混用会一起编译（按文件名字母序），
  不搞"同名优先"之类的魔法。
- 于是 `example/` 目录里同时放 `main.go` 与 `main.gone` 会重复声明 —— 给 `main.gone`
  加 `//go:build ignore` 解决（`go run main.gone` 走命令行文件模式，不看构建约束），
  这样 `go build ./...` 和 `go run example/main.gone` 都能用。


### 3.7 补丁点 4：编辑器侧（`x/tools` / gopls，M5）

编译器、`go/types`、`go` 命令都就位之后，编辑器里还差两步：

1. **`.gone` 文件要落到 Go 语言上。** VSCode 那边 `golang.go` 只声明了
   `{id: "go", extensions: [".go"]}`，Go 的语法高亮是 VSCode 内置的
   （`source.go`）。所以只要有一个扩展把 `.gone` 并进 `go` 语言 id，
   官方 Go 扩展（gopls 客户端、调试、测试透镜…）就会接管；Neovim/Vim 侧
   一行 `ftdetect`（`setfiletype go`）即可。
2. **gopls 自己也要认识 `.gone`。** gopls 通过 `go list` 拿文件列表（M2 之后
   已经包含 `.gone`），但它内部还有若干处"只看 `.go` 后缀"的判断，
   这些判断让 `.gone` 文件在**没被打开**时不算 Go 文件，最典型的表现是：

   ```
   main.gone:6:2: could not import example/lib (missing import example/lib)
   ```

   即一个包 import 了另一个用 `.gone` 写的包时，gopls 认为那个包是空的。

所以 M5 也需要一份补丁，落点是 `x/tools`（gopls 是它的子模块）：

| 文件 | 改动 |
|---|---|
| `gopls/internal/file/kind.go` | 新增 `IsGoFile`/`IsTestGoFile`（转发到工具链的 `go/build`）；`KindForLang` 也认 `gone` 这个 languageId |
| `gopls/internal/cache/{parse,snapshot,session}.go` | 解析前的扩展名检查、`fileKind` 的扩展名 switch、改文件后 metadata 失效判断 |
| `gopls/internal/server/{diagnostics,command}.go` | 「整个目录里有没有 Go 代码」的目录扫描、文件参数转目录 |
| `gopls/internal/golang/{compileropt,rename_check,addtest}.go` | options 文件过滤、改名时的忽略文件判断、生成测试文件名（`x.gone` → `x_test.gone`） |
| `gopls/internal/cmd/cmd.go` | 命令行子命令按扩展名推断 languageId |
| `go/packages/golist.go` | `go list` 结果里 `CompiledGoFiles` 的过滤（**上面那条 missing import 的根因**） |
| `internal/{imports,gopathwalk,modindex}`、`cmd/goimports` | 目录扫描、依赖包符号索引、goimports 的文件判断 |

和 M2 的思路一样：这些判断都改成调用工具链的 `go/build.IsGoFile`（gopls 内部再包一层
`gopls/internal/file.IsGoFile`）。这也意味着**补丁后的 gopls 必须用 gone 工具链构建**，
否则 `build.IsGoFile` 都不存在 —— 这正好也是它本来就需要的东西（gopls 静态链接了
`go/types`，官方工具链的 `go/types` 不认识 `!err`）。

分发方式（不发布到市场，全部本地构建）：

- `scripts/build-gopls.sh`：克隆 `editors/gopls/VERSION` 钉住的 `gopls/v0.23.0`
  （提交号也钉住了）→ 应用 `editors/gopls/*.patch` → 用 gone 工具链构建到
  `<工具链>/bin/gopls` → 最后做一次**自检**（用 LSP 探测一个含语法糖的 `.gone` 工程，
  要求零诊断）。
- `editors/vscode-gone/`：一个很小的 TS 扩展。语言贡献把 `.gone` 并进 `go`
  （并在打开时用 `setTextDocumentLanguage` 兜底），另外提供
  「Gone: 配置 gone 工具链」（把 `go.goroot`、`go.alternateTools.gopls` 写到工作区设置）
  和「Gone: 环境自检」（临时写一个带 `!err` 的 `.gone` 文件并用该工具链编译，
  判断这份 GOROOT 到底是不是 gone 工具链）两个命令。
  判定逻辑单独放在 `src/toolchain.ts`（不依赖 VSCode API），
  所以能用普通 node 跑：`editors/vscode-gone/check.sh <gone 工具链> <普通工具链>`；
  `build.sh` 负责 `tsc` + 打包 `.vsix`（不发布市场）。
- `editors/vim/gone.vim`：ftdetect + gopls 接法示例。

编辑器集成有些地方注定是我们管不到的：VSCode Go 扩展内部也有几处
`fileName.endsWith('.go')`（覆盖率装饰、生成测试、调试配置），这些功能对 `.gone`
不生效；`go.mod` 里换工具链、语言服务器重启等仍按 Go 扩展原有逻辑走。


## 4. 限制

1. **裸 `return` 要求函数结果全为具名，或函数没有结果。**
   生成的是 `return`（与 README 给出的展开一致），所以：

   ```go
   func f() (string, error) {        // 结果未具名
       x, !err := g()
       return                         // ← 编译错误: not enough return values
   }
   ```

   解决办法：写成 `func f() (s string, err error)`。
   要做到「自动 `return zero..., err`」需要类型信息，属后续里程碑（见 M4）。

2. **`.gone` 只在 gone 工具链里被识别。**
   用 gone 工具链的 `go build` / `go run` / `go test` / `go vet` / `go doc` / `gofmt`
   都能直接吃 `.gone`（含 `_test.gone`）；但换成官方工具链就得改名成 `.go`，
   第三方工具（编辑器、`gopls`、各种 lint）也各有各的目录扫描逻辑，未必认这个扩展名。
   另外 `internal/goroot`（回答"这是不是标准库包"）仍然只看 `.go`，
   把标准库本身改写成 `.gone` 不在支持范围。

3. **gopls 需要用 gone 工具链重装一份。** `go vet` 已经随工具链准备好了，
   但 gopls 是外部二进制、把 `go/types` 静态链接进去，
   所以要用 `GOROOT=./gone-go go install golang.org/x/tools/gopls@latest` 重装；
   现成的官方 gopls 里带的还是原版 `go/types`。

## 5. 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M1** | `cmd/compile/internal/syntax` 解析器脱糖 `!err`，重建工具链并验证 | ✅ 已完成 |
| **M2** | 工具链识别 `.gone` 扩展名（`go/build`、模块索引、`go` 命令、`go/parser.ParseDir`、`go/doc`、`gofmt`），`go build ./...` 直接吃 `.gone` | ✅ 已完成 |
| **M3** | `go/types` 支持，让 `go vet` / gopls 认识 `!err` | ✅ 已完成 |
| **M5** | 编辑器侧：VSCode 扩展 + Vim ftdetect + `x/tools`/gopls 补丁 + `build-gopls.sh` | ✅ 已完成 |
| M4 | 结果未具名时自动 `return zero..., err`（需要类型信息，在 noder/types 层补）；错误信息打磨 | 待定 |
| M6 | 更多语法糖变体（如 `!panic`、`!continue`）——需要先讨论语法，避免歧义 | 待讨论 |

M1/M3 只管语法糖本身，`.gone` 扩展名由 M2 补齐；两者互不依赖
（只改编译器、不认 `.gone` 时，把文件改名成 `.go` 也能用）。

## 6. 工具链构建与测试

```bash
# 完整构建：下载官方 go1.27.2 源码(校验 sha256) → 打补丁 → make.bash 自举
scripts/build-toolchain.sh

# 快速迭代：复制本机 GOROOT → 打补丁 → 只重建 cmd/compile、cmd/vet、cmd/go、cmd/gofmt（约 30 秒）
scripts/build-toolchain.sh --fast --out ./gone-go --force

# 构建 gopls(打上 editors/gopls/*.patch, 用 gone 工具链编译, 装到 ./gone-go/bin/gopls)
scripts/build-gopls.sh --toolchain ./gone-go

# 用产物跑测试套件(默认会用 <工具链>/bin/gopls 跑 gopls 套件)
scripts/test.sh --toolchain ./gone-go

# 日常使用
export GOROOT="$PWD/gone-go"
export PATH="$GOROOT/bin:$PATH"
go build ./...
```

一个小坑：如果像本文档这样把工具链建在仓库内部（`./gone-go`），
仓库根的 `go.mod` 会罩住 `gone-go/src`，于是从那里跑
`go test go/types` 之类的标准库测试会报
`can't find import: "fmt": main module (…)`；
`go build ./...` 也会顺手扫进整个 `gone-go/src`。
把工具链建到仓库外（`--out /tmp/gone-go`）或者直接指定包路径即可绕开。

固件版本记录在 `toolchain/VERSION`。补丁是针对该版本源码生成的；
升级 Go 版本后必须重新验证补丁能否干净应用（用 `patch --dry-run` 或直接跑测试套件）。

注意：补丁改到哪个包，就必须重建哪些**预编译工具/命令**，否则 `go` 命令用的还是旧二进制 ——
`--fast` 模式因此会重建 `compile`（对应 §3.2）、`vet`（对应 §3.5）、
`go` 与 `gofmt`（对应 §3.6；`cmd/go` 静态链接了 `go/build`、`go/parser`、`go/doc`）。
重建 `bin/go` 时要先写中间文件再 `mv`，否则覆盖正在运行的可执行文件会 `ETXTBSY`。

测试套件：

- `test/cases/*/` —— 行为用例（成功继续执行 / 错误传播 / 多标记 / 普通赋值 / 取反不受影响 /
  `:=` 重复声明具名结果 / 连续多个糖），比对 stdout。
- `test/reject/*/` —— 非法位置用例，比对编译报错文本**含行列号**（确保 `!` 被精确指向）。
- `test/vet/*/` —— `go vet`（走 `go/types`）用例：合法糖必须干净通过、
  真 bug 仍要报出来、非法位置要报出 `go/types` 的错误。
- `test/e2e/*/` —— `.gone` 端到端用例（`run.sh` + `want`）：多文件包、命令行文件参数、
  `go test`（含故意失败的用例）、`go vet` 分析器、构建约束/`GOOS` 后缀、`gofmt`/`go fmt`、
  `go clean`、`go doc`。
- `editors/vscode-gone/check.sh` —— 工具链判定逻辑的冒烟测试（需要一个 gone 工具链
  和一个普通工具链作为反例），不需要开 VSCode。
- `test/gopls/*/` —— 编辑器侧：`test/gopls/lsp_probe.py` 是个极简 LSP 客户端，
  按"编辑器打开文件"的方式给 gopls 发 `didOpen`（`languageId=go`）再收集诊断，
  与 `want` 比对。每个用例用独立的 `GOPLSCACHE`，否则缓存会让结果不稳定。
  没给 `--gopls` 且 `<工具链>/bin/gopls` 不存在、或没有 python3 时，这个套件会被跳过。
- `test/tools/gotypescheck/` —— 直接用 `go/parser` + `go/types` 类型检查一段固定源码，
  比对诊断列表（覆盖「声明但未使用」这类需要 `Info` 完整性的场景）。

## 7. 已验证内容

- `scripts/test.sh`：29/29 通过，覆盖 6 个套件（`--fast` 与完整自举两套工具链，
  外加 `./gone-go/bin/gopls` 的 gopls 套件）。
  M2 的 `test/e2e/*` 覆盖：多文件包、命令行文件参数、`_test.gone`（含故意失败的用例）、
  `go vet` 分析器、构建约束与 `GOOS` 后缀、`gofmt`/`go fmt`、`go clean`、`go doc`。
- M2 补丁（`toolchain/0003-*.patch`）在官方 `go1.27.2.src.tar.gz` 上从头 `patch -p1 -N --fuzz=3`，
  产物与开发分支逐字节一致；`make.bash` 完整自举通过。
- M2 回归：`go test go/build go/parser go/doc cmd/gofmt`，以及 `go build -a std`。
- M1 回归：`go test cmd/compile/internal/syntax cmd/compile/internal/types2 cmd/compile/internal/noder` 全绿。
- 全量：`make.bash` 用改后的编译器等自举了三轮，并编译了整个标准库与全部命令。
- 自举：用打了补丁的编译器编译 `cmd/compile` 自己，产出的编译器再跑测试套件仍然全绿。
- 行号：`-gcflags=-S` 确认 nil 检查的代码归属行 == `!err` 所在行。
- M3 端到端：`go vet` 在语法糖代码上不再 panic 且仍能查出 printf 问题；
  用 gone 工具链重装的 gopls 对合法糖零诊断、对非法位置报出与编译器同位置的错误。
- M3 幂等性：同一份 AST 连续类型检查 3 次结果一致（gopls 会重复检查，这点专门验证过）。
- M5 编辑器侧：`scripts/build-gopls.sh` 从零跑通（克隆 `gopls/v0.23.0` → 打补丁 →
  用 gone 工具链构建 → LSP 自检）。`test/gopls/*` 用 LSP 探测，
  关掉缓存后**可复现**地抓到补丁前后的差别：
  - 补丁前：`main.gone:6:2: could not import gonetest/lib (missing import gonetest/lib)`（连续 3 次）；
  - 补丁后：同一个工程零诊断，且非法位置的报错位置与编译器一致（都指向 `!`）。
  另外验证了编辑器侧的几个场景：`languageId=go` 与 `languageId=gone` 都能工作；
  未打开的兄弟 `.gone` 文件里写错也会被报出来；补丁后 x/tools 全量 `go build ./...` 通过。
- M5 VSCode 扩展：`tsc` 编译通过、`build.sh` 打包出 7.8KB 的 `.vsix`；
  `check.sh` 用普通 node 验证工具链判定（`./gone-go` 判为 gone 工具链、
  `/opt/go` 判为普通工具链）。扩展本身的 UI 行为没有自动化测试（跑 VSCode 集成测试太重），
  这是已知缺口。
- M3 端到端（旧）：`gopls check` 在语法糖代码上零诊断；用 M3 修复前的工具链构建的
  旧 gopls 会报 `declared and not used: err`，所以升级工具链后必须重建 gopls。

## 8. 风险

- **补丁跟随上游**：Go 每个版本 `cmd/compile/internal/syntax` 与 `go/types` 都可能微调，
  升级时需要重新 rebase 补丁（补丁都很小，成本可控）。
- **编辑器侧依赖一个外部仓库**：M5 的补丁钉在 `gopls/v0.23.0`（提交号记在
  `editors/gopls/VERSION`），gopls 升级时补丁同样要 rebase；补丁后的 gopls 只能用
  gone 工具链构建（补丁里直接用了 `go/build.IsGoFile`）。
- **扩展名判断点在 cmd/go 里有多份副本**：`modindex` 与 `fsys` 各自有一份"目录里有没有 Go 文件"
  的实现，上游新增类似判断点时补丁需要跟着补（本轮已把能收敛的都收敛到 `go/build.IsGoFile`）。
- **`Info` 完整性是 M3 的隐性契约**：因为不改写 AST（为了可重复检查），
  `!err` 这个表达式节点会留在 AST 里，必须靠我们补的 `Uses` / `Types` 条目
  让遍历 AST 的工具满意。目前已知 `go vet`（`satisfy`）与 gopls 依赖这一点；
  将来若遇到别的工具越界报错，优先沿用「补齐 `Info`」的思路，而不是改写 AST。
- **`go/types` 与 `types2` 出现分叉**：`types2` 是由 `go/types` 生成的副本
  （`cmd/compile/internal/types2/generate.sh`）。本补丁只加在 `go/types`：
  编译器不需要它，因为 `cmd/compile` 在解析器层就已经脱糖了（§3.2）。
  如果哪天重新生成 `types2`，会顺带带上这段代码，功能上无害（编译器永远看不到 `!err`）。
- **生态意外**：语法糖在**所有** `.go` 文件里都生效（不只是 `.gone`）。
  考虑到 §2.3 的完全向后兼容性，这不会改变任何现有程序的语义；
  但确实会让「写错的文件」报出不同的错误信息。若将来需要收敛，
  可以按文件扩展名/构建标签开关。
