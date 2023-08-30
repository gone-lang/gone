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
