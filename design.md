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

### 3.2 补丁点：`cmd/compile/internal/syntax` 解析器脱糖

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

2. **`.gone` 扩展名暂时还要靠改名。**
   本轮只改了编译器；`go build` 侧的扩展名识别属 M2，所以现在
   `.gone` 文件需要改名成 `.go` 才能被 `go build` 处理
   （`go tool compile some.gone` 已经可以，编译器本身不看扩展名）。

3. **IDE（gopls）暂不支持。** gopls 走 `go/parser` + `go/types`，属 M3。
   目前 `gofmt` 已经能正常处理（原样保留 `!err`），但 `go vet` 会因为 `go/types` 报错。

## 5. 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M1** | `cmd/compile/internal/syntax` 解析器脱糖 `!err`，重建工具链并验证 | ✅ 已完成 |
| M2 | `go/build` + `go list`/模块扫描识别 `.gone` 扩展名，`go build ./...` 直接吃 `.gone` | 待定 |
| M3 | `go/parser` + `go/types` 支持，让 gopls / `go vet` / `goimports` 认识 `!err` | 待定 |

> M2 落地时要注意 `example/` 目录同时放着 `main.go` 和 `main.gone`
> （一个是手工展开的等价代码），扩展名一旦被识别就会出现重复声明，需要一起调整。
| M4 | 结果未具名时自动 `return zero..., err`（需要类型信息，在 noder/types 层补）；错误信息打磨 | 待定 |
| M5 | 更多语法糖变体（如 `!panic`、`!continue`）——需要先讨论语法，避免歧义 | 待讨论 |

## 6. 工具链构建与测试

```bash
# 完整构建：下载官方 go1.27.2 源码(校验 sha256) → 打补丁 → make.bash 自举
scripts/build-toolchain.sh

# 快速迭代：复制本机 GOROOT → 打补丁 → 只重建 cmd/compile（约 3 秒）
scripts/build-toolchain.sh --fast --out ./gone-go --force

# 用产物跑测试套件
scripts/test.sh --toolchain ./gone-go

# 日常使用
export GOROOT="$PWD/gone-go"
export PATH="$GOROOT/bin:$PATH"
go build ./...
```

固件版本记录在 `toolchain/VERSION`。补丁是针对该版本源码生成的；
升级 Go 版本后必须重新验证补丁能否干净应用（用 `patch --dry-run` 或直接跑测试套件）。

测试套件：

- `test/cases/*/` —— 行为用例（成功继续执行 / 错误传播 / 多标记 / 普通赋值 / 取反不受影响 /
  `:=` 重复声明具名结果 / 连续多个糖），比对 stdout。
- `test/reject/*/` —— 非法位置用例，比对报错文本**含行列号**（确保 `!` 被精确指向）。

## 7. 已验证内容

- `scripts/test.sh`：11/11 通过（go1.27.0 fast 模式 与 go1.27.2 完整自举 两套工具链）。
- 回归：`go test cmd/compile/internal/syntax cmd/compile/internal/types2 cmd/compile/internal/noder` 全绿。
- 全量：`make.bash` 用改后的编译器等自举了三轮，并编译了整个标准库与全部命令。
- 自举：用打了补丁的编译器编译 `cmd/compile` 自己，产出的编译器再跑测试套件仍然全绿。
- 行号：`-gcflags=-S` 确认 nil 检查的代码归属行 == `!err` 所在行。

## 8. 风险

- **补丁跟随上游**：Go 每个版本 `cmd/compile/internal/syntax` 都可能微调，
  升级时需要重新 rebase 补丁（补丁很小，成本可控）。
- **M3 的 `go/types` 改动比 M1 大**：`go/types` 不能改写 AST，只能在类型检查时
  把 `!x` 当作 `x` 处理并标记为已使用；同时要保证「声明但未使用」等诊断不误报。
- **生态意外**：语法糖在**所有** `.go` 文件里都生效（不只是 `.gone`）。
  考虑到 §2.3 的完全向后兼容性，这不会改变任何现有程序的语义；
  但确实会让「写错的文件」报出不同的错误信息。若将来需要收敛，
  可以按文件扩展名/构建标签开关。
