# 简介

这是一个为 Go 添加 !err 错误处理语法糖的项目

有了它你可以写如下代码, 代码更加紧凑阅读更轻松

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