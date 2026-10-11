set -e
# go doc 走 go/parser.ParseDir + go/doc, 两者都要认识 .gone
"$GO" doc ./lib
