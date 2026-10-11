" gone: 让 .gone 文件直接用 Go 的语法高亮/缩进/其他 ftplugin。
"
" 安装(Vim):
"   cp editors/vim/gone.vim ~/.vim/ftdetect/gone.vim
" 安装(Neovim):
"   cp editors/vim/gone.vim ~/.config/nvim/ftdetect/gone.vim
"
" gopls 那一边需要两份"gone 版"的东西:
"   1. gone 工具链(它的 go/types 认识 !err 语法糖)
"   2. 用脚本构建的 gopls(它认得 .gone 扩展名, 且静态链接了上面的 go/types)
"      scripts/build-gopls.sh --toolchain ./gone-go     # 产物: ./gone-go/bin/gopls
"
" 以 nvim-lspconfig 为例:
"   local lsp = require('lspconfig')
"   lsp.gopls.setup({
"     cmd = { '/path/to/gone-go/bin/gopls' },
"     -- gopls 会用 PATH 里的 go 去跑 go list, 所以要保证是 gone 工具链的 go
"     init_options = { env = { GOROOT = '/path/to/gone-go', PATH = '/path/to/gone-go/bin:' .. vim.env.PATH } },
"   })
"
" 手工配置或其它 LSP 插件时, 只要满足两条即可:
"   - gopls 可执行文件是 scripts/build-gopls.sh 构建出来的
"   - 环境变量 GOROOT 指向 gone 工具链, 且 PATH 里有 $GOROOT/bin

autocmd BufNewFile,BufRead *.gone setfiletype go
