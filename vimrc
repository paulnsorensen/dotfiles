" Vim configuration with Brownfield theme
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

" Brownfield color scheme
" These colors match your terminal's Brownfield theme
set background=dark

" Enable 256 colors in terminal
if !has('gui_running')
  set t_Co=256
endif

" Brownfield color definitions
" Using terminal colors that match Brownfield
highlight Normal ctermfg=253 ctermbg=NONE
highlight Comment ctermfg=245
highlight Constant ctermfg=209
highlight String ctermfg=148
highlight Character ctermfg=148
highlight Number ctermfg=209
highlight Boolean ctermfg=209
highlight Float ctermfg=209
highlight Identifier ctermfg=105
highlight Function ctermfg=105
highlight Statement ctermfg=170
highlight Conditional ctermfg=170
highlight Repeat ctermfg=170
highlight Label ctermfg=170
highlight Operator ctermfg=170
highlight Keyword ctermfg=170
highlight Exception ctermfg=170
highlight PreProc ctermfg=220
highlight Include ctermfg=220
highlight Define ctermfg=220
highlight Macro ctermfg=220
highlight PreCondit ctermfg=220
highlight Type ctermfg=220
highlight StorageClass ctermfg=220
highlight Structure ctermfg=220
highlight Typedef ctermfg=220
highlight Special ctermfg=138
highlight SpecialChar ctermfg=138
highlight Tag ctermfg=138
highlight Delimiter ctermfg=138
highlight SpecialComment ctermfg=138
highlight Debug ctermfg=138
highlight Underlined ctermfg=105 cterm=underline
highlight Error ctermfg=231 ctermbg=138
highlight Todo ctermfg=234 ctermbg=220
highlight CursorLine cterm=NONE ctermbg=234
highlight CursorLineNr ctermfg=220 ctermbg=234
highlight LineNr ctermfg=245 ctermbg=NONE
highlight Visual ctermbg=235
highlight Search ctermfg=234 ctermbg=220
highlight IncSearch ctermfg=234 ctermbg=109
highlight StatusLine ctermfg=253 ctermbg=235
highlight StatusLineNC ctermfg=245 ctermbg=234
highlight VertSplit ctermfg=235 ctermbg=NONE
highlight Pmenu ctermfg=253 ctermbg=234
highlight PmenuSel ctermfg=234 ctermbg=220
highlight Directory ctermfg=105
highlight Folded ctermfg=245 ctermbg=234
highlight FoldColumn ctermfg=245 ctermbg=NONE

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

" Clipboard integration
if has('mac')
  set clipboard=unnamed
else
  set clipboard=unnamedplus
endif

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
