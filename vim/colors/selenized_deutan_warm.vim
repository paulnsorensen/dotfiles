" Selenized Deutan Warm - A deuteranopia-safe, circadian-friendly colorscheme
" Based on Selenized by Jan Warchoł, transformed for CVD accessibility
" 
" Design principles:
"   - Warm backgrounds (a*=+3, b*=+5) reduce blue light for circadian health
"   - Accent colors spread along b* (blue-yellow) axis for deuteranopia safety
"   - Green → Teal shift moves success colors OFF the red-green confusion axis
"   - All critical pairs validated: b* diff + 1.5×L* diff ≥ 25

set background=dark
hi clear
if exists("syntax_on")
    syntax reset
endif

let g:colors_name = "selenized_deutan_warm"

" ============================================================================
" PALETTE DEFINITION (CIELAB-derived)
" ============================================================================
" Background/Foreground
let s:bg_0   = "#3E3530"  " L*=23, a*=3, b*=5   - Main background
let s:bg_1   = "#4A403B"  " L*=28, a*=3, b*=5   - Highlight bg
let s:bg_2   = "#5D534D"  " L*=36, a*=3, b*=5   - Selection/visual
let s:dim_0  = "#908579"  " L*=56, a*=2, b*=8   - Comments
let s:fg_0   = "#C4B7A3"  " L*=75, a*=1, b*=12  - Main foreground
let s:fg_1   = "#E0D3BE"  " L*=85, a*=1, b*=12  - Emphasized text

" Accents (Deuteranopia-safe)
let s:red     = "#F05A19"  " L*=58, a*=55, b*=62  - Vermillion (errors)
let s:green   = "#3EB8A5"  " L*=68, a*=-38, b*=0  - Teal (success)
let s:yellow  = "#F0B822"  " L*=78, a*=8, b*=75   - Types, highlights
let s:blue    = "#0091EF"  " L*=58, a*=0, b*=-57  - Functions
let s:magenta = "#FC94D8"  " L*=74, a*=48, b*=-18 - Constants
let s:cyan    = "#3ACBF2"  " L*=76, a*=-25, b*=-30 - Strings
let s:orange  = "#FF8752"  " L*=70, a*=45, b*=50  - Warnings
let s:violet  = "#B587E3"  " L*=64, a*=35, b*=-40 - Keywords

" Bright variants (L* + 5.2)
let s:br_red     = "#FF6928"
let s:br_green   = "#4FC6B3"
let s:br_yellow  = "#FFC734"
let s:br_blue    = "#009FFE"
let s:br_magenta = "#FFA2E7"
let s:br_cyan    = "#4FD9FF"
let s:br_orange  = "#FF955F"
let s:br_violet  = "#C495F2"

" ============================================================================
" HELPER FUNCTION
" ============================================================================
function! s:hl(group, fg, bg, attr)
    let l:cmd = "hi " . a:group
    if a:fg != ""
        let l:cmd .= " guifg=" . a:fg
    endif
    if a:bg != ""
        let l:cmd .= " guibg=" . a:bg
    endif
    if a:attr != ""
        let l:cmd .= " gui=" . a:attr
    else
        let l:cmd .= " gui=NONE"
    endif
    execute l:cmd
endfunction

" ============================================================================
" UI ELEMENTS
" ============================================================================
call s:hl("Normal",       s:fg_0,   s:bg_0,   "")
call s:hl("NormalFloat",  s:fg_0,   s:bg_1,   "")
call s:hl("FloatBorder",  s:dim_0,  s:bg_1,   "")
call s:hl("Cursor",       s:bg_0,   s:fg_0,   "")
call s:hl("CursorLine",   "",       s:bg_1,   "")
call s:hl("CursorColumn", "",       s:bg_1,   "")
call s:hl("ColorColumn",  "",       s:bg_1,   "")
call s:hl("LineNr",       s:dim_0,  "",       "")
call s:hl("CursorLineNr", s:yellow, "",       "bold")
call s:hl("SignColumn",   s:dim_0,  s:bg_0,   "")
call s:hl("VertSplit",    s:bg_2,   s:bg_0,   "")
call s:hl("WinSeparator", s:bg_2,   s:bg_0,   "")

call s:hl("Visual",       "",       s:bg_2,   "")
call s:hl("VisualNOS",    "",       s:bg_2,   "")
call s:hl("Search",       s:bg_0,   s:yellow, "")
call s:hl("IncSearch",    s:bg_0,   s:orange, "")
call s:hl("CurSearch",    s:bg_0,   s:orange, "bold")
call s:hl("Substitute",   s:bg_0,   s:orange, "")

call s:hl("StatusLine",   s:fg_0,   s:bg_2,   "")
call s:hl("StatusLineNC", s:dim_0,  s:bg_1,   "")
call s:hl("TabLine",      s:dim_0,  s:bg_1,   "")
call s:hl("TabLineFill",  s:dim_0,  s:bg_0,   "")
call s:hl("TabLineSel",   s:fg_1,   s:bg_2,   "bold")

call s:hl("Pmenu",        s:fg_0,   s:bg_1,   "")
call s:hl("PmenuSel",     s:bg_0,   s:cyan,   "bold")
call s:hl("PmenuSbar",    "",       s:bg_2,   "")
call s:hl("PmenuThumb",   "",       s:dim_0,  "")

call s:hl("Folded",       s:dim_0,  s:bg_1,   "italic")
call s:hl("FoldColumn",   s:dim_0,  s:bg_0,   "")

call s:hl("MatchParen",   s:br_yellow, s:bg_2, "bold")
call s:hl("NonText",      s:bg_2,   "",       "")
call s:hl("SpecialKey",   s:bg_2,   "",       "")
call s:hl("Whitespace",   s:bg_2,   "",       "")
call s:hl("EndOfBuffer",  s:bg_1,   "",       "")

call s:hl("Directory",    s:blue,   "",       "")
call s:hl("Title",        s:yellow, "",       "bold")
call s:hl("Question",     s:green,  "",       "")
call s:hl("MoreMsg",      s:green,  "",       "")
call s:hl("ModeMsg",      s:fg_1,   "",       "bold")
call s:hl("WarningMsg",   s:orange, "",       "")
call s:hl("ErrorMsg",     s:red,    "",       "bold")

" ============================================================================
" SYNTAX HIGHLIGHTING
" ============================================================================
call s:hl("Comment",      s:dim_0,  "",       "italic")

call s:hl("Constant",     s:magenta, "",      "")
call s:hl("String",       s:cyan,   "",       "")
call s:hl("Character",    s:cyan,   "",       "")
call s:hl("Number",       s:magenta, "",      "")
call s:hl("Boolean",      s:magenta, "",      "")
call s:hl("Float",        s:magenta, "",      "")

call s:hl("Identifier",   s:fg_0,   "",       "")
call s:hl("Function",     s:blue,   "",       "")

call s:hl("Statement",    s:violet, "",       "")
call s:hl("Conditional",  s:violet, "",       "")
call s:hl("Repeat",       s:violet, "",       "")
call s:hl("Label",        s:violet, "",       "")
call s:hl("Operator",     s:fg_0,   "",       "")
call s:hl("Keyword",      s:violet, "",       "")
call s:hl("Exception",    s:violet, "",       "")

call s:hl("PreProc",      s:orange, "",       "")
call s:hl("Include",      s:orange, "",       "")
call s:hl("Define",       s:orange, "",       "")
call s:hl("Macro",        s:orange, "",       "")
call s:hl("PreCondit",    s:orange, "",       "")

call s:hl("Type",         s:yellow, "",       "")
call s:hl("StorageClass", s:yellow, "",       "")
call s:hl("Structure",    s:yellow, "",       "")
call s:hl("Typedef",      s:yellow, "",       "")

call s:hl("Special",      s:orange, "",       "")
call s:hl("SpecialChar",  s:orange, "",       "")
call s:hl("Tag",          s:blue,   "",       "")
call s:hl("Delimiter",    s:fg_0,   "",       "")
call s:hl("SpecialComment", s:dim_0, "",      "bold,italic")
call s:hl("Debug",        s:orange, "",       "")

call s:hl("Underlined",   s:blue,   "",       "underline")
call s:hl("Ignore",       s:bg_2,   "",       "")
call s:hl("Error",        s:red,    "",       "bold,underline")
call s:hl("Todo",         s:bg_0,   s:yellow, "bold")

" ============================================================================
" DIFF
" ============================================================================
" Using teal for add (green replacement) and vermillion for delete (red replacement)
call s:hl("DiffAdd",      "",       "#1A3A35", "")  " Teal tinted background
call s:hl("DiffChange",   "",       "#3A3530", "")  " Warm neutral
call s:hl("DiffDelete",   s:red,    "#3A2A25", "")  " Vermillion tinted background
call s:hl("DiffText",     "",       "#4A4540", "bold")

call s:hl("diffAdded",    s:green,  "",        "")
call s:hl("diffRemoved",  s:red,    "",        "")
call s:hl("diffChanged",  s:orange, "",        "")
call s:hl("diffFile",     s:yellow, "",        "bold")
call s:hl("diffLine",     s:cyan,   "",        "")

" ============================================================================
" GIT (Fugitive, etc.)
" ============================================================================
call s:hl("gitcommitSummary",     s:fg_0,   "", "")
call s:hl("gitcommitComment",     s:dim_0,  "", "italic")
call s:hl("gitcommitHeader",      s:violet, "", "")
call s:hl("gitcommitSelectedType", s:green, "", "")
call s:hl("gitcommitSelectedFile", s:green, "", "")
call s:hl("gitcommitDiscardedType", s:red,  "", "")
call s:hl("gitcommitDiscardedFile", s:red,  "", "")
call s:hl("gitcommitUntrackedFile", s:cyan, "", "")

" ============================================================================
" DIAGNOSTICS (LSP, etc.)
" ============================================================================
call s:hl("DiagnosticError",       s:red,     "", "")
call s:hl("DiagnosticWarn",        s:orange,  "", "")
call s:hl("DiagnosticInfo",        s:cyan,    "", "")
call s:hl("DiagnosticHint",        s:blue,    "", "")
call s:hl("DiagnosticOk",          s:green,   "", "")

call s:hl("DiagnosticUnderlineError", "", "", "undercurl")
call s:hl("DiagnosticUnderlineWarn",  "", "", "undercurl")
call s:hl("DiagnosticUnderlineInfo",  "", "", "undercurl")
call s:hl("DiagnosticUnderlineHint",  "", "", "undercurl")

call s:hl("DiagnosticVirtualTextError", s:red,    s:bg_1, "italic")
call s:hl("DiagnosticVirtualTextWarn",  s:orange, s:bg_1, "italic")
call s:hl("DiagnosticVirtualTextInfo",  s:cyan,   s:bg_1, "italic")
call s:hl("DiagnosticVirtualTextHint",  s:blue,   s:bg_1, "italic")

" ============================================================================
" TREESITTER (if available)
" ============================================================================
if has("nvim")
    hi! link @comment Comment
    hi! link @constant Constant
    hi! link @string String
    hi! link @character Character
    hi! link @number Number
    hi! link @boolean Boolean
    hi! link @float Float
    hi! link @function Function
    hi! link @function.builtin Function
    hi! link @function.call Function
    hi! link @method Function
    hi! link @parameter Identifier
    hi! link @keyword Keyword
    hi! link @keyword.function Keyword
    hi! link @keyword.return Keyword
    hi! link @conditional Conditional
    hi! link @repeat Repeat
    hi! link @label Label
    hi! link @operator Operator
    hi! link @exception Exception
    hi! link @type Type
    hi! link @type.builtin Type
    hi! link @structure Structure
    hi! link @include Include
    hi! link @variable Identifier
    hi! link @variable.builtin Special
    hi! link @text Normal
    hi! link @text.strong Bold
    hi! link @text.emphasis Italic
    hi! link @text.underline Underlined
    hi! link @text.uri Underlined
    hi! link @tag Tag
    hi! link @tag.attribute Identifier
    hi! link @tag.delimiter Delimiter
    hi! link @punctuation Delimiter
    hi! link @punctuation.bracket Delimiter
    hi! link @punctuation.delimiter Delimiter
    hi! link @punctuation.special Special
endif

" ============================================================================
" TERMINAL COLORS
" ============================================================================
if has("nvim")
    let g:terminal_color_0  = s:bg_0
    let g:terminal_color_1  = s:red
    let g:terminal_color_2  = s:green
    let g:terminal_color_3  = s:yellow
    let g:terminal_color_4  = s:blue
    let g:terminal_color_5  = s:magenta
    let g:terminal_color_6  = s:cyan
    let g:terminal_color_7  = s:fg_0
    let g:terminal_color_8  = s:dim_0
    let g:terminal_color_9  = s:br_red
    let g:terminal_color_10 = s:br_green
    let g:terminal_color_11 = s:br_yellow
    let g:terminal_color_12 = s:br_blue
    let g:terminal_color_13 = s:br_magenta
    let g:terminal_color_14 = s:br_cyan
    let g:terminal_color_15 = s:fg_1
elseif has("terminal")
    let g:terminal_ansi_colors = [
        \ s:bg_0, s:red, s:green, s:yellow,
        \ s:blue, s:magenta, s:cyan, s:fg_0,
        \ s:dim_0, s:br_red, s:br_green, s:br_yellow,
        \ s:br_blue, s:br_magenta, s:br_cyan, s:fg_1
        \ ]
endif

" vim: set sw=4 ts=4 et:
