// Command gotypescheck type-checks a fixed source snippet with go/parser and
// go/types and prints the resulting diagnostics. It is the M3 regression test:
// it exercises the paths that editors and vet depend on.
//
// Run it with the gone toolchain:
//
//	scripts/build-toolchain.sh --fast --out ./gone-go
//	GOROOT=$PWD/gone-go go run ./test/tools/gotypescheck
//
// Expected output is in want.
package main

import (
	"fmt"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"sort"
)

// src covers the cases that must be accepted (no diagnostic at all) and the
// two positions that must be rejected.
const src = `package p

func g() (int, error)          { return 0, nil }
func two() (int, error, error) { return 0, nil, nil }

// 短变量声明: 新声明的 err 只被语法糖的隐式检查读取, 不能报 declared and not used
func fresh() {
	x, !err := g()
	_ = x
}

// 普通赋值: 变量只被语法糖读取
func assign() {
	var e error
	var x int
	x, !e = g()
	_ = x
}

// 具名结果
func named() (n int, err error) {
	x, !err := g()
	n = x
	return
}

// 多个标记
func multi() {
	x, !a, !b := two()
	_ = x
}

// 普通取反不受影响
func neg(ok bool) bool {
	if !ok {
		return false
	}
	return !ok
}

// 非法位置: if 的 init
func badIf() {
	if x, !err := g(); x > 0 {
		_ = err
	}
}

// 非法位置: select 的 comm 子句
func badSelect(ch chan int) {
	select {
	case x, !err := <-ch:
		_, _ = x, err
	}
}
`

func main() {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "p.go", src, parser.AllErrors)
	if err != nil {
		fmt.Println("parse error:", err)
		return
	}

	var errs []string
	conf := types.Config{
		Importer: importer.Default(),
		Error:    func(err error) { errs = append(errs, err.Error()) },
	}
	// 诊断信息通过 conf.Error 收集, 这里的返回值忽略即可
	_, _ = conf.Check("p", fset, []*ast.File{f}, &types.Info{})

	sort.Strings(errs)
	for _, e := range errs {
		fmt.Println(e)
	}
	fmt.Printf("errors: %d\n", len(errs))
}
