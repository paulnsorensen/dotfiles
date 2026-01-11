" Vim configuration with Selenized Dark theme
" This configuration provides a vim-centric experience with Selenized Dark colors

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

" Selenized Dark color scheme
" These colors match your terminal's Selenized Dark theme
set background=dark

" Enable 256 colors in terminal
if !has('gui_running')
  set t_Co=256
endif

" Selenized Dark color definitions
" Using terminal colors that match Selenized Dark
highlight Normal ctermfg=252 ctermbg=235
highlight Comment ctermfg=245
highlight Constant ctermfg=173
highlight String ctermfg=150
highlight Character ctermfg=150
highlight Number ctermfg=173
highlight Boolean ctermfg=173
highlight Float ctermfg=173
highlight Identifier ctermfg=117
highlight Function ctermfg=117
highlight Statement ctermfg=139
highlight Conditional ctermfg=139
highlight Repeat ctermfg=139
highlight Label ctermfg=139
highlight Operator ctermfg=139
highlight Keyword ctermfg=139
highlight Exception ctermfg=139
highlight PreProc ctermfg=180
highlight Include ctermfg=180
highlight Define ctermfg=180
highlight Macro ctermfg=180
highlight PreCondit ctermfg=180
highlight Type ctermfg=116
highlight StorageClass ctermfg=116
highlight Structure ctermfg=116
highlight Typedef ctermfg=116
highlight Special ctermfg=210
highlight SpecialChar ctermfg=210
highlight Tag ctermfg=210
highlight Delimiter ctermfg=210
highlight SpecialComment ctermfg=210
highlight Debug ctermfg=210
highlight Underlined ctermfg=117 cterm=underline
highlight Error ctermfg=231 ctermbg=167
highlight Todo ctermfg=235 ctermbg=180
highlight CursorLine cterm=NONE ctermbg=236
highlight CursorLineNr ctermfg=180 ctermbg=236
highlight LineNr ctermfg=245 ctermbg=235
highlight Visual ctermbg=238
highlight Search ctermfg=235 ctermbg=180
highlight IncSearch ctermfg=235 ctermbg=116
highlight StatusLine ctermfg=252 ctermbg=238
highlight StatusLineNC ctermfg=245 ctermbg=236
highlight VertSplit ctermfg=238 ctermbg=235
highlight Pmenu ctermfg=252 ctermbg=236
highlight PmenuSel ctermfg=235 ctermbg=180
highlight Directory ctermfg=117
highlight Folded ctermfg=245 ctermbg=236
highlight FoldColumn ctermfg=245 ctermbg=235

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