" Vim configuration with Chocolate Donut theme
" This configuration provides a vim-centric experience with themed colors

" Basic Settings
set nocompatible              " Be improved, required
set encoding=utf-8            " UTF-8 encoding
set number                    " Show line numbers
set relativenumber            " Relative line numbers
set cursorline                " Highlight current line
set showcmd                   " Show command in bottom bar
set wildmenu                  " Visual autocomplete for command menu
set lazyredraw                " Redraw only when needed
set showmatch                 " Highlight matching brackets
set ruler                     " Show cursor position
set laststatus=2              " Always show status line

" Search Settings
set incsearch                 " Search as characters are entered
set hlsearch                  " Highlight search results
set ignorecase                " Case insensitive search
set smartcase                 " Smart case search

" Indentation
set expandtab                 " Tabs are spaces
set tabstop=2                 " Number of visual spaces per TAB
set softtabstop=2             " Number of spaces in tab when editing
set shiftwidth=2              " Number of spaces for indentation
set autoindent                " Auto indent
set smartindent               " Smart indent

" File handling
set autoread                  " Auto reload changed files
set nobackup                  " No backup files
set noswapfile                " No swap files
set hidden                    " Allow hidden buffers

" Visual Settings
set wrap                      " Wrap lines
set linebreak                 " Break lines at word boundaries
set scrolloff=5               " Keep 5 lines above/below cursor
set sidescrolloff=10          " Keep 10 columns left/right of cursor

" Enable syntax highlighting
syntax enable

" Chocolate Donut color scheme
" These colors match your terminal's Chocolate Donut theme
set background=dark

" Enable 256 colors in terminal
if !has('gui_running')
  set t_Co=256
endif

" Chocolate Donut color definitions
" Using terminal colors that match Chocolate Donut
highlight Normal ctermfg=181 ctermbg=NONE
highlight Comment ctermfg=241
highlight Constant ctermfg=179
highlight String ctermfg=108
highlight Character ctermfg=108
highlight Number ctermfg=179
highlight Boolean ctermfg=179
highlight Float ctermfg=179
highlight Identifier ctermfg=103
highlight Function ctermfg=103
highlight Statement ctermfg=140
highlight Conditional ctermfg=140
highlight Repeat ctermfg=140
highlight Label ctermfg=140
highlight Operator ctermfg=140
highlight Keyword ctermfg=140
highlight Exception ctermfg=140
highlight PreProc ctermfg=214
highlight Include ctermfg=214
highlight Define ctermfg=214
highlight Macro ctermfg=214
highlight PreCondit ctermfg=214
highlight Type ctermfg=214
highlight StorageClass ctermfg=214
highlight Structure ctermfg=214
highlight Typedef ctermfg=214
highlight Special ctermfg=167
highlight SpecialChar ctermfg=167
highlight Tag ctermfg=167
highlight Delimiter ctermfg=167
highlight SpecialComment ctermfg=167
highlight Debug ctermfg=167
highlight Underlined ctermfg=103 cterm=underline
highlight Error ctermfg=231 ctermbg=167
highlight Todo ctermfg=234 ctermbg=214
highlight CursorLine cterm=NONE ctermbg=235
highlight CursorLineNr ctermfg=214 ctermbg=235
highlight LineNr ctermfg=241 ctermbg=NONE
highlight Visual ctermbg=238
highlight Search ctermfg=234 ctermbg=214
highlight IncSearch ctermfg=234 ctermbg=45
highlight StatusLine ctermfg=181 ctermbg=238
highlight StatusLineNC ctermfg=241 ctermbg=235
highlight VertSplit ctermfg=238 ctermbg=NONE
highlight Pmenu ctermfg=181 ctermbg=235
highlight PmenuSel ctermfg=234 ctermbg=214
highlight Directory ctermfg=103
highlight Folded ctermfg=241 ctermbg=235
highlight FoldColumn ctermfg=241 ctermbg=NONE

" Key Mappings (matching your VS Code vim setup)
let mapleader = " "           " Set leader key to space

" Quick escape with jj
inoremap jj <Esc>

" Better window navigation
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" Clear search highlighting
nnoremap <leader><space> :nohlsearch<CR>

" Save file
nnoremap <leader>w :w<CR>

" Quit
nnoremap <leader>q :q<CR>

" Save and quit
nnoremap <leader>x :wq<CR>

" Enable mouse support
set mouse=a

" Clipboard integration (macOS)
set clipboard=unnamed

" File type detection and plugins
filetype plugin indent on

" Backspace behavior
set backspace=indent,eol,start

" Command timeout (for vi mode responsiveness)
set timeoutlen=1000
set ttimeoutlen=1

" Visual bell instead of beeping
set visualbell
set t_vb=

" Show trailing whitespace
set list
set listchars=trail:·,tab:▸\ 

" Persistent undo
if has('persistent_undo')
  set undodir=~/.vim/undo
  set undofile
endif

" Remember cursor position
augroup remember_cursor_position
  autocmd!
  autocmd BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g`\"" | endif
augroup END

" Create undo directory if it doesn't exist
if !isdirectory($HOME."/.vim/undo")
  call mkdir($HOME."/.vim/undo", "p", 0700)
endif