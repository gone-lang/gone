package main

import "fmt"

func load() (string, error) { return "ok", nil }

func main() {
	v, !err := load()
	fmt.Println("go file still works:", v)
}
