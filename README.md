# 存档

被各位大佬建议并查看gopls源码后，突然觉得 `if err != nil {}`也不是不能接受了捏，借助编辑器设置好快速补全就行了

实话：还是太菜了，改是能改，花的时间太多了，借助编辑器快速补全更划算

不过如果有空闲了还是想实现这个语法糖

# 简介

这是一个为 Go 添加 !err 错误处理语法糖的项目, 与 Go 完全兼容(毕竟只是语法糖)

有了它你可以写如下代码, 代码更加紧凑 阅读更轻松

转换前:

```go
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

转换后:

```go
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
3. golang 语言简单, 为其添加这么一个功能应该不算太难, 零基础大概一两个月也能搞定, 所以我来试试(但不是现在,实现应该是在 11 月之后)
