vim9script

#  Highlighting code blocks in .aichat files
#  Inspired and based on https://github.com/preservim/vim-markdown

import autoload 'vim9_ai_config.vim'

var filetype_dict: dict<string>
if exists('g:vim_markdown_fenced_languages')
  filetype_dict = {}
  for filetype in g:vim_markdown_fenced_languages
    var key = matchstr(filetype, '[^=]*')
    var val = matchstr(filetype, '[^=]*$')
    filetype_dict[key] = val
  endfor
else
  filetype_dict = {
    'c++': 'cpp',
    'viml': 'vim',
    'bash': 'sh',
    'ini': 'dosini',
    'js': 'javascript',
    'jsx': 'javascriptreact',
    'ts': 'typescript',
    'tsx': 'typescriptreact',
  }
endif

def MarkdownHighlightSources(force: bool)
  # Syntax highlight source code embedded in notes.
  # Look for code blocks in the current file
  var filetypes: dict<bool> = {}
  for line in getline(1, '$')
    var ft = matchstr(line, '\(`\{3,}\|\~\{3,}\)\s*\zs[0-9A-Za-z_+-]*\ze.*')
    if !empty(ft) && ft !~# '^\d*$'
      filetypes[ft] = true
    endif
  endfor
  if !exists('b:aichat_known_filetypes')
    # set of file types with syntax already included
    b:aichat_known_filetypes = {}
  endif
  if !exists('b:aichat_included_filetypes')
    # set of syntax file names already included
    b:aichat_included_filetypes = {}
  endif
  if !force && (b:aichat_known_filetypes == filetypes || empty(filetypes))
    return
  endif

  # Now we're ready to actually highlight the code blocks.
  var startgroup = 'aichatCodeStart'
  var endgroup = 'aichatCodeEnd'
  for ft in keys(filetypes)
    if force || !has_key(b:aichat_known_filetypes, ft)
      var filetype = has_key(filetype_dict, ft) ? filetype_dict[ft] : ft
      var group = 'aichatSnippet' .. toupper(substitute(filetype, '[+-]', '_', 'g'))
      var include = ''
      if !has_key(b:aichat_included_filetypes, filetype)
        include = SyntaxInclude(filetype)
        b:aichat_included_filetypes[filetype] = 1
      else
        include = '@' .. toupper(filetype)
      endif
      var command_backtick = 'syntax region %s matchgroup=%s start="^\s*`\{3,}\s*%s.*$" matchgroup=%s end="\s*`\{3,}\s*$" keepend contains=%s'
      var command_tilde = 'syntax region %s matchgroup=%s start="^\s*\~\{3,}\s*%s.*$" matchgroup=%s end="\s*\~\{3,}\s*$" keepend contains=%s'
      exe printf(command_backtick, group, startgroup, ft, endgroup, include)
      exe printf(command_tilde, group, startgroup, ft, endgroup, include)
      exe printf('syntax cluster aichatNonListItem add=%s', group)

      b:aichat_known_filetypes[ft] = 1
    endif
  endfor
enddef

def MarkdownHighlightChatOptions(force: bool)
  # use jproperties syntax to highlight chat options
  var filetype = 'jproperties'
  if force || !has_key(b:aichat_known_filetypes, filetype)
    var include = ''
    if !has_key(b:aichat_included_filetypes, filetype)
      include = SyntaxInclude(filetype)
      b:aichat_included_filetypes[filetype] = 1
    else
      include = '@' .. toupper(filetype)
    endif
    syntax region aichatOptions start="\[chat\]" end="^$" contains=@JPROPERTIES
    b:aichat_known_filetypes[filetype] = 1
  endif
enddef

def SyntaxInclude(filetype: string): string
  # Include the syntax highlighting of another {filetype}.
  var grouplistname = '@' .. toupper(filetype)
  # Unset the name of the current syntax while including the other syntax
  # because some syntax scripts do nothing when "b:current_syntax" is set
  var syntax_save = ''
  if exists('b:current_syntax')
    syntax_save = b:current_syntax
    unlet b:current_syntax
  endif
  try
    exe 'syntax include' grouplistname 'syntax/' .. filetype .. '.vim'
    exe 'syntax include' grouplistname 'after/syntax/' .. filetype .. '.vim'
  catch /E484/
    # Ignore missing scripts
  endtry
  # Restore the name of the current syntax
  if !empty(syntax_save)
    b:current_syntax = syntax_save
  elseif exists('b:current_syntax')
    unlet b:current_syntax
  endif
  return grouplistname
enddef

def MarkdownRefreshSyntax(force: bool)
  vim9_ai_config.Init()
  MarkdownHighlightSources(force)
  MarkdownHighlightChatOptions(force)
enddef

def MarkdownClearSyntaxVariables()
  if exists('b:aichat_included_filetypes')
    unlet! b:aichat_included_filetypes
  endif
enddef

augroup Aichat
  autocmd! * <buffer>
  autocmd BufWinEnter <buffer> call MarkdownRefreshSyntax(true)
  autocmd BufUnload <buffer> call MarkdownClearSyntaxVariables()
  autocmd BufWritePost <buffer> call MarkdownRefreshSyntax(false)
  autocmd InsertEnter,InsertLeave <buffer> call MarkdownRefreshSyntax(false)
  autocmd CursorHold,CursorHoldI <buffer> call MarkdownRefreshSyntax(false)
augroup END
