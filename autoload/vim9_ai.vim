vim9script

#  Main implementation of vim9-ai commands.

import autoload 'vim9_ai_config.vim'
import autoload 'vim9_ai_context.vim'
import autoload 'vim9_ai_curl.vim'
import autoload 'vim9_ai_provider.vim'
import autoload 'vim9_ai_roles.vim'
import autoload 'vim9_ai_util.vim'

vim9_ai_config.Init()

var plugin_root = expand('<sfile>:p:h:h')

#  remembers last command parameters to be used in AIRedoRun
var last_is_selection = false
var last_uses_range = 0
var last_firstline = 1
var last_lastline = 1
var last_instruction = ''
var last_command = ''
var last_config: dict<any> = {}
var redo_selection_hint = -1
var redo_firstline = 1
var redo_lastline = 1

var scratch_buffer_name = '>>> AI chat'
var chat_redraw_interval = 250 # milliseconds

var is_handling_paste_mode = false

# async chat jobs, keyed by buffer number
var ai_job_pool: dict<any> = {}

def StartsWith(longer: string, shorter: string): bool
  return longer[: len(shorter) - 1] ==# shorter
enddef

def GetLastChatBufferNumber(): number
  for buf in reverse(getbufinfo())
    var bufname = bufname(buf.bufnr)
    if buf.listed && StartsWith(bufname, scratch_buffer_name)
      return buf.bufnr
    endif
  endfor
  return -1
enddef

def GetTabLocalChatBufferNumber(): number
  var chat_bufnr = gettabvar(tabpagenr(), 'vim9_ai_chat_bufnr', -1)
  if !bufexists(chat_bufnr) || !buflisted(chat_bufnr)
    return -1
  endif
  return chat_bufnr
enddef

def GetReusedChatBufferNumber(): number
  # reuse tab local buffer if available
  var tab_local_buffnr = GetTabLocalChatBufferNumber()
  if tab_local_buffnr != -1
    return tab_local_buffnr
  endif
  # else reuse last chat buffer
  return GetLastChatBufferNumber()
enddef

#  Configures ai-chat scratch window.
#  - scratch_buffer_keep_open = 0: opens new ai-chat every time, excludes the
#    buffer from the buffer list
#  - scratch_buffer_keep_open = 1: opens the last ai-chat buffer (unless
#    force_new = 1), keeps the buffer in the buffer list
def OpenChatWindow(open_conf: string, force_new: bool): void
  var open_cmd = has_key(g:vim9_ai_open_chat_presets, open_conf)
        ? g:vim9_ai_open_chat_presets[open_conf]
        : open_conf
  # The command comes from the user configuration and may use legacy range
  # syntax (e.g. "55vnew"); the legacy modifier keeps both old and new forms
  # working inside Vim9 script.
  if !empty(open_cmd)
    exe 'legacy ' .. open_cmd
  endif

  # reuse chat in keep-open mode
  var keep_open = string(g:vim9_ai_chat['ui']['scratch_buffer_keep_open']) ==# '1'
  var reused_chat_buffer_name = GetReusedChatBufferNumber()
  if keep_open && reused_chat_buffer_name != -1 && !force_new
    var current_buffer = bufnr('%')
    # reuse chat buffer
    exe 'buffer ' .. reused_chat_buffer_name
    # close new buffer that was created by open_cmd
    if bufloaded(current_buffer)
      # if `hidden` is turned off, the buffer is unloaded automatically
      exe 'bd ' .. current_buffer
    endif
    # set tab local chat buffer number
    settabvar(tabpagenr(), 'vim9_ai_chat_bufnr', bufnr('%'))
    return
  endif

  setlocal buftype=nofile
  setlocal noswapfile
  setlocal ft=aichat
  if keep_open
    setlocal bufhidden=hide
  else
    setlocal bufhidden=wipe
  endif
  if bufexists(scratch_buffer_name)
    # spawn another window if chat already exists
    var index = 2
    while bufexists(scratch_buffer_name .. ' ' .. index)
      index += 1
    endwhile
    exe 'file ' .. scratch_buffer_name .. ' ' .. index
  else
    exe 'file ' .. scratch_buffer_name
  endif
  # set tab local chat buffer number
  settabvar(tabpagenr(), 'vim9_ai_chat_bufnr', bufnr('%'))
enddef

def SetPaste(config: dict<any>): void
  if !&paste && string(get(get(config, 'ui', {}), 'paste_mode', '')) ==# '1'
    is_handling_paste_mode = true
    setlocal paste
  endif
enddef

def SetNopaste(config: dict<any>): void
  if is_handling_paste_mode
    setlocal nopaste
    is_handling_paste_mode = false
  endif
enddef

def GetSelectionOrRange(is_selection: bool, is_range: number, firstline: number,
      lastline: number): string
  if is_selection
    return GetVisualSelection()
  elseif is_range != 0
    return trim(join(getline(firstline, lastline), "\n"))
  else
    return ''
  endif
enddef

def SelectSelectionOrRange(is_selection: bool, firstline: number, lastline: number): void
  if is_selection
    exe 'normal! gv'
  else
    exe ':' .. firstline
    exe 'normal! V'
    exe ':' .. lastline
  endif
enddef

def GetVisualSelection(): string
  var line_start = getpos("'<")[1]
  var column_start = getpos("'<")[2]
  var line_end = getpos("'>")[1]
  var column_end = getpos("'>")[2]
  var lines = getline(line_start, line_end)
  if empty(lines)
    return ''
  endif
  # The exclusive mode means that the last character of the selection area is
  # not included in the operation scope.
  var keep_end = column_end - (&selection ==# 'inclusive' ? 2 : 3)
  lines[-1] = lines[-1][: keep_end]
  lines[0] = lines[0][column_start - 1 :]
  return join(lines, "\n")
enddef

#  A visual range should be treated as character-wise selection only when the
#  command-line invocation actually came from `'<,'>...`.
def IsVisualSelectionRangeInner(uses_range: number, line_start: number, line_end: number,
      last_cmd_override: string): bool
  if !uses_range
    return false
  endif

  if redo_selection_hint >= 0
    return redo_selection_hint == 1
          && line_start == line("'<")
          && line_end == line("'>")
  endif

  var last_cmd = !empty(last_cmd_override) ? last_cmd_override : histget(':', -1)
  if last_cmd =~# '^\s*AIRedo\>'
    return line_start == line("'<") && line_end == line("'>")
  endif

  return last_cmd =~# '^\s*''<,''>' && line_start == line("'<") && line_end == line("'>")
enddef

export def IsVisualSelectionRange(uses_range: number, line_start: number, line_end: number,
      ...args: list<any>): bool
  return IsVisualSelectionRangeInner(uses_range, line_start, line_end, len(args) > 0 ? args[0] : '')
enddef

def MakeContext(command_type: string, config_default: dict<any>, config_extension: dict<any>,
      instruction: string, selection: string, is_selection: bool): dict<any>
  return vim9_ai_context.MakeAiContext({
    'config_default': config_default,
    'config_extension': config_extension,
    'user_instruction': instruction,
    'user_selection': selection,
    'is_selection': is_selection,
    'command_type': command_type,
  })
enddef

def GetRequestTimeoutMs(options: dict<any>): number
  var t = get(options, 'request_timeout', 20)
  if type(t) == v:t_string
    t = str2float(t)
  endif
  if t <= 0
    t = 20
  endif
  return float2nr(t) * 1000 + 30000
enddef

def RememberLastCommand(command_type: string, config: dict<any>, instruction: string,
      uses_range: number, is_selection: bool, firstline: number, lastline: number): void
  last_command = command_type
  last_config = config
  last_instruction = instruction
  last_uses_range = uses_range
  last_is_selection = is_selection
  last_firstline = firstline
  last_lastline = lastline
enddef

#  Complete prompt
export def AIRun(uses_range: number, firstline: number, lastline: number,
      config: dict<any>, ...args: list<any>): void
  var instruction = len(args) > 0 ? args[0] : ''
  var r_firstline = redo_selection_hint >= 0 ? redo_firstline : firstline
  var r_lastline = redo_selection_hint >= 0 ? redo_lastline : lastline
  var is_selection = IsVisualSelectionRangeInner(uses_range, r_firstline, r_lastline, '')
  var selection = GetSelectionOrRange(is_selection, uses_range, r_firstline, r_lastline)
  var context = MakeContext('complete', g:vim9_ai_complete, config, instruction, selection, is_selection)

  RememberLastCommand('complete', config, instruction, uses_range, is_selection, r_firstline, r_lastline)

  var cursor_on_empty_line = empty(getline('.'))
  try
    SetPaste(context['config'])
    if cursor_on_empty_line
      exe 'normal! ' .. r_lastline .. 'G'
      cursor(line('.'), col('$'))
    else
      exe 'normal! ' .. r_lastline .. 'G'
      append(line('.'), '')
      cursor(line('.') + 1, 1)
    endif
    RunAICompletion(context)
    exe 'normal! ' .. r_lastline .. 'G'
  finally
    SetNopaste(context['config'])
  endtry
enddef

#  Edit prompt
export def AIEditRun(uses_range: number, firstline: number, lastline: number,
      config: dict<any>, ...args: list<any>): void
  var instruction = len(args) > 0 ? args[0] : ''
  var r_firstline = redo_selection_hint >= 0 ? redo_firstline : firstline
  var r_lastline = redo_selection_hint >= 0 ? redo_lastline : lastline
  var is_selection = IsVisualSelectionRangeInner(uses_range, r_firstline, r_lastline, '')
  var selection = GetSelectionOrRange(is_selection, uses_range, r_firstline, r_lastline)
  var context = MakeContext('edit', g:vim9_ai_edit, config, instruction, selection, is_selection)

  RememberLastCommand('edit', config, instruction, uses_range, is_selection, r_firstline, r_lastline)

  try
    SetPaste(context['config'])
    SelectSelectionOrRange(is_selection, r_firstline, r_lastline)
    # delete the selection (instead of "c") so that we stay in Normal mode and
    # can render the response with buffer operations
    exe 'normal! d'
    RunAICompletion(context)
  finally
    SetNopaste(context['config'])
  endtry
enddef

#  Generate image
export def AIImageRun(uses_range: number, firstline: number, lastline: number,
      config: dict<any>, ...args: list<any>): void
  var instruction = len(args) > 0 ? args[0] : ''
  var r_firstline = redo_selection_hint >= 0 ? redo_firstline : firstline
  var r_lastline = redo_selection_hint >= 0 ? redo_lastline : lastline
  var is_selection = IsVisualSelectionRangeInner(uses_range, r_firstline, r_lastline, '')
  var selection = GetSelectionOrRange(is_selection, uses_range, r_firstline, r_lastline)
  var context = MakeContext('image', g:vim9_ai_image, config, instruction, selection, is_selection)

  RememberLastCommand('image', config, instruction, uses_range, is_selection, r_firstline, r_lastline)

  RunAIImage(context)
enddef

def RunAICompletion(context: dict<any>): void
  var command_type = context['command_type']
  var prompt = context['prompt']
  var config = vim9_ai_util.MakeConfig(context['config'])
  var config_options = config['options']
  var roles = context['roles']

  try
    if has_key(config, 'engine') && type(config['engine']) == v:t_string && config['engine'] ==# 'complete'
      throw 'complete engine is no longer supported'
    endif

    if !empty(prompt) || !empty(roles)
      echomsg 'Completing...'
      redraw

      var initial_prompt = join(get(config_options, 'initial_prompt', []), "\n")
      var chat_content = trim(initial_prompt .. "\n\n>>> user\n\n" .. prompt)
      var messages = vim9_ai_util.ParseChatMessages(chat_content)
      vim9_ai_util.DebugWrite('[' .. command_type .. '] text:' .. "\n" .. chat_content)

      var provider = config['provider']
      var append_to_eol = command_type ==# 'complete'
      var error_message = ''
      var rendered_any = false
      var insert_before_cursor = vim9_ai_util.NeedInsertBeforeCursor()
      def ChunkCb(chunk: dict<any>)
        if chunk['type'] ==# 'assistant'
          if vim9_ai_util.RenderTextChunk(chunk['content'], append_to_eol, insert_before_cursor, !rendered_any)
            rendered_any = true
          endif
          insert_before_cursor = false
        endif
      enddef
      def DoneCb()
        # nothing extra
      enddef
      def ErrCb(msg: string)
        error_message = msg
      enddef
      var job = vim9_ai_provider.ProviderRequest(provider, command_type, config_options, messages,
            {'provider': provider, 'chunk': ChunkCb, 'done': DoneCb, 'error': ErrCb})
      vim9_ai_curl.WaitForJob(job, GetRequestTimeoutMs(config_options))
      if !empty(error_message)
        vim9_ai_util.PrintInfoMessage(error_message)
        return
      endif
      if !rendered_any
        vim9_ai_util.PrintInfoMessage('Empty response received. Tip: You can try modifying the prompt and retry.')
        return
      endif
      vim9_ai_util.ClearEchoMessage()
    endif
  catch
    if v:exception =~# 'Vim:Interrupt'
      vim9_ai_util.PrintInfoMessage('Completion cancelled...')
    else
      vim9_ai_util.PrintInfoMessage(v:exception)
    endif
    vim9_ai_util.DebugWrite('[' .. command_type .. '] error: ' .. v:exception .. ' @ ' .. v:throwpoint)
  endtry
enddef

def RunAIImage(context: dict<any>): void
  var prompt = context['prompt']
  var config = context['config']
  var config_options = config['options']
  var ui = config['ui']
  var command_type = context['command_type']

  try
    if !empty(prompt)
      echomsg 'Generating...'
      vim9_ai_util.DebugWrite('[image] text:' .. "\n" .. prompt)

      var provider = config['provider']
      var response = vim9_ai_provider.ProviderRequestImage(provider, command_type, config_options, prompt)
      var info_messages: list<string> = []
      for image in response
        var path = vim9_ai_util.MakeImagePath(ui)
        vim9_ai_util.SaveB64ToFile(path, image['b64_data'])
        add(info_messages, 'Image: ' .. path)
      endfor

      vim9_ai_util.ClearEchoMessage()
      echomsg join(info_messages, "\n")
    endif
  catch
    if v:exception =~# 'Vim:Interrupt'
      vim9_ai_util.PrintInfoMessage('Generation cancelled...')
    else
      vim9_ai_util.PrintInfoMessage(v:exception)
    endif
    vim9_ai_util.DebugWrite('[' .. command_type .. '] error: ' .. v:exception .. ' @ ' .. v:throwpoint)
  endtry
enddef

def ReuseOrCreateChatWindow(config: dict<any>): void
  var open_conf = config['ui']['open_chat_command']

  if string(config['ui']['force_new_chat']) ==# '1'
    OpenChatWindow(open_conf, true)
    return
  endif

  if &filetype !=# 'aichat'
    var buffer_list_tab = tabpagebuflist(tabpagenr())

    # reuse chat in active tab
    for bufnr in buffer_list_tab
      if StartsWith(bufname(bufnr), scratch_buffer_name)
        win_gotoid(bufwinid(bufnr))
        return
      endif
    endfor

    # reuse .aichat file on the same tab
    for bufnr in buffer_list_tab
      if getbufvar(bufnr, '&filetype') ==# 'aichat'
        win_gotoid(bufwinid(bufnr))
        return
      endif
    endfor

    # open tab local buffer if present
    var tab_local_buffer_name = GetTabLocalChatBufferNumber()
    if tab_local_buffer_name != -1
      OpenChatWindow(open_conf, false)
      return
    endif

    # reuse any .aichat buffer in the session
    var open_buffer_list: list<number> = []
    for i in range(tabpagenr('$'))
      extend(open_buffer_list, tabpagebuflist(i + 1))
    endfor
    for bufnr in reverse(sort(open_buffer_list))
      if getbufvar(bufnr, '&filetype') ==# 'aichat'
        win_gotoid(win_findbuf(bufnr)[0])
        return
      endif
    endfor

    # open new chat window if no active buffer found
    OpenChatWindow(open_conf, false)
  endif
enddef

#  Undo history is cluttered when using async chat. There doesn't seem to be a
#  way to use the standard undojoin feature, therefore working around with
#  undoing and pasting changes manually.
def AIChatUndoCleanup(): void
  var bufnr = bufnr()
  var done = AIChatJobIsDone(bufnr)
  var chat_initiation_line = getbufvar(bufnr, 'vim9_ai_chat_start_last_line', -1)
  var undo_cleaned = chat_initiation_line == -1
  if !done || undo_cleaned
    return
  endif

  var current_line_num = line('.')
  # navigate to the line where it started generating answer
  exe ':' .. chat_initiation_line
  exe 'normal! j'
  # copy whole assistant message to the `d` register
  exe 'normal! "dyG'
  # undo until user message
  while line('$') > chat_initiation_line
    exe 'normal! u'
  endwhile
  # paste assistant message as a whole
  exe 'normal! "dp'
  exe ':' .. current_line_num

  setbufvar(bufnr, 'vim9_ai_chat_start_last_line', -1)
enddef

def PopulateChatOptions(provider: string, options: dict<any>, default_options: dict<any>,
      show_default: bool): void
  var lines: list<string> = ['[chat]', '', 'provider=' .. provider]
  for [key, value0] in items(options)
    var value = value0
    var default_value = get(default_options, key, '')
    if key ==# 'initial_prompt'
      value = join(value, '\n')
      if type(default_value) == v:t_list
        default_value = join(default_value, '\n')
      endif
    endif
    if !show_default && default_value == value
      continue # do not show default values
    endif
    if type(value) != v:t_string
      value = string(value)
    endif
    add(lines, 'options.' .. key .. '=' .. value)
  endfor
  add(lines, '')
  append(0, lines)
enddef

def InitializeChatWindow(context: dict<any>, config: dict<any>): void
  var lines = getline(1, '$')
  var file_content = trim(join(lines, "\n"))
  var contains_user_prompt = false
  for line in lines
    if line =~# '^>>> \(user\|exec\|include\)'
      contains_user_prompt = true
      break
    endif
  endfor

  var roles = context['roles']
  # if populate is set in config, populate once; it shouldn't re-populate after
  # chat header options are modified
  var populate = index(lines, '[chat]') == -1
        && (string(config['ui']['populate_options']) ==# '1' || string(config['ui']['populate_all_options']) ==# '1')
  # when a special `populate` role is used, force chat header re-population
  var re_populate = index(roles, 'populate') != -1 || index(roles, 'populate-all') != -1
  var is_populating_all = index(roles, 'populate-all') != -1 || string(config['ui']['populate_all_options']) ==# '1'

  if re_populate
    if index(lines, '[chat]') != -1
      var line_num = index(lines, '[chat]') + 1
      exe 'normal! ' .. line_num .. 'gg'
      exe 'normal! d}dd'
    endif
  endif

  if !contains_user_prompt
    # user role not found, put the whole file content as a user prompt
    append(0, ['>>> user', ''])
  endif

  if populate || re_populate
    exe 'normal! gg'

    var default_options = vim9_ai_util.MakeOptions(copy(g:vim9_ai_chat_default['options']))
    if is_populating_all
      # get default options from the provider if available
      var default_varname = vim9_ai_provider.ProviderDefaultOptionsVarname(config['provider'], 'chat')
      var default_provider_options: dict<any> = {}
      if !empty(default_varname)
        var varname = substitute(default_varname, '^g:', '', '')
        default_provider_options = vim9_ai_util.MakeOptions(copy(g:[varname]))
      endif
      var populated_options: dict<any> = {}
      for [key, value] in items(default_options)
        populated_options[key] = value
      endfor
      for [key, value] in items(default_provider_options)
        populated_options[key] = value
      endfor
      for [key, value] in items(config['options'])
        populated_options[key] = value
      endfor
      PopulateChatOptions(config['provider'], populated_options, {}, true)
    else
      PopulateChatOptions(config['provider'], config['options'], default_options, false)
    endif
  endif

  exe 'normal! G'
  vim9_ai_util.BreakUndoSequence()
  redraw

  # if the last role is not a user role, most likely completion was cancelled
  var last_role = ''
  for i in range(len(lines) - 1, -1, -1)
    var m = matchlist(lines[i], '^\(>>>\|<<<\) \(\w\+\)')
    if !empty(m)
      last_role = m[2]
      break
    endif
  endfor
  if !empty(last_role) && index(['user', 'include', 'exec', 'info'], last_role) == -1
    append(line('$'), ['', '>>> user', '', ''])
  endif

  if !empty(context['prompt'])
    exe 'normal! dd'
    append(line('$'), split(context['prompt'], "\n", 1))
    vim9_ai_util.BreakUndoSequence()
    exe 'normal! G'
    redraw
  endif
enddef

def AIChatJobOnChunk(entry: dict<any>, chunk: dict<any>): void
  if entry['prev_type'] != chunk['type']
    if !empty(entry['prev_type'])
      entry['buffer'] ..= "\n"
    endif
    entry['buffer'] ..= "\n<<< " .. chunk['type'] .. "\n\n"
    entry['prev_type'] = chunk['type']
  endif
  entry['buffer'] ..= chunk['content']
  AIChatJobFlushLines(entry)
enddef

def AIChatJobFlushLines(entry: dict<any>): void
  var nl = stridx(entry['buffer'], "\n")
  while nl != -1
    add(entry['lines'], nl > 0 ? entry['buffer'][: nl - 1] : '')
    entry['buffer'] = entry['buffer'][nl + 1 :]
    nl = stridx(entry['buffer'], "\n")
  endwhile
enddef

def AIChatJobFinish(entry: dict<any>): void
  if entry['cancelled'] && !empty(entry['buffer'])
    entry['buffer'] ..= "\n\nCANCELLED by user"
  endif
  add(entry['lines'], entry['buffer'])
  if entry['prev_type'] ==# 'assistant'
    add(entry['lines'], '')
    add(entry['lines'], '>>> user')
    add(entry['lines'], '')
    add(entry['lines'], '')
  endif
  entry['done'] = true
enddef

def AIChatJobOnError(entry: dict<any>, msg: string): void
  if entry['cancelled']
    AIChatJobFinish(entry)
    return
  endif
  add(entry['lines'], '')
  add(entry['lines'], '<<< error getting response: ' .. msg)
  add(entry['lines'], '')
  add(entry['lines'], '```python')
  add(entry['lines'], 'provider request failed')
  add(entry['lines'], '```')
  add(entry['lines'], '')
  AIChatJobFinish(entry)
enddef

def AIChatJobNew(context: dict<any>, messages: list<any>, options: dict<any>,
      provider: string): void
  var bufnr = context['bufnr']
  var entry = {
    'job': null,
    'lines': [],
    'buffer': '',
    'prev_type': '',
    'done': false,
    'cancelled': false,
  }
  ai_job_pool[bufnr] = entry

  def ChunkCb(chunk: dict<any>)
    AIChatJobOnChunk(entry, chunk)
  enddef
  def DoneCb()
    AIChatJobFinish(entry)
  enddef
  def ErrCb(msg: string)
    AIChatJobOnError(entry, msg)
  enddef
  entry['job'] = vim9_ai_provider.ProviderRequest(provider, 'chat', options, messages,
        {'provider': provider, 'chunk': ChunkCb, 'done': DoneCb, 'error': ErrCb})
enddef

def AIChatJobPickupLines(bufnr: number): list<string>
  if !has_key(ai_job_pool, bufnr)
    return []
  endif
  var lines = ai_job_pool[bufnr]['lines']
  ai_job_pool[bufnr]['lines'] = []
  return lines
enddef

def AIChatJobIsDone(bufnr: number): bool
  if !has_key(ai_job_pool, bufnr)
    return true
  endif
  return ai_job_pool[bufnr]['done']
enddef

def AIChatJobCancel(bufnr: number): void
  if !has_key(ai_job_pool, bufnr)
    return
  endif
  var entry = ai_job_pool[bufnr]
  if entry['done']
    return
  endif
  entry['cancelled'] = true
  if type(entry['job']) == v:t_job
    job_stop(entry['job'])
  endif
enddef

#  Start and answer the chat
export def AIChatRun(uses_range: number, firstline: number, lastline: number,
      config: dict<any>, ...args: list<any>): void
  var instruction = len(args) > 0 ? args[0] : ''
  var is_selection = uses_range != 0 && firstline == line("'<") && lastline == line("'>")
  var selection = GetSelectionOrRange(is_selection, uses_range, firstline, lastline)
  var started_from_chat = &filetype ==# 'aichat'

  var context = MakeContext('chat', g:vim9_ai_chat, config, instruction, selection, is_selection)
  var prompt = (len(args) > 0 || uses_range) ? context['prompt'] : ''
  context['prompt'] = prompt
  context['started_from_chat'] = started_from_chat

  try
    SetPaste(context['config'])
    ReuseOrCreateChatWindow(context['config'])

    var bufnr = bufnr()
    context['bufnr'] = bufnr

    if !AIChatJobIsDone(bufnr)
      echoerr 'Operation in progress, wait or stop it with :AIStopChat'
      return
    endif

    RememberLastCommand('chat', config, '', 0, false, firstline, lastline)

    if RunAIChat(context)
      if string(g:vim9_ai_async_chat) ==# '1'
        setbufvar(bufnr, 'vim9_ai_chat_start_last_line', line('$'))
        # if the user switches to a different buffer, setup an autocommand that
        # will clean undo history after returning back
        augroup AichatUndo
          au!
          autocmd BufEnter <buffer> call AIChatUndoCleanup()
        augroup END
        append(line('$'), '<<< answering')
        timer_start(0, (_timer) => AIChatWatch(bufnr, 0))
      endif
    endif
  finally
    SetNopaste(context['config'])
  endtry
enddef

def RunAIChat(context: dict<any>): bool
  var command_type = context['command_type']
  var prompt = context['prompt']
  var config = vim9_ai_util.MakeConfig(context['config'])
  var config_options = config['options']
  var roles = context['roles']
  var started_from_chat = context['started_from_chat'] == true

  InitializeChatWindow(context, config)

  var chat_config = vim9_ai_util.ParseChatHeaderConfig(getline(1, '$'))
  var options = copy(config_options)
  for [key, value] in items(chat_config['options'])
    options[key] = value
  endfor
  var provider = !empty(chat_config['provider']) ? chat_config['provider'] : config['provider']

  var initial_prompt = join(get(options, 'initial_prompt', []), "\n")
  var initial_messages = vim9_ai_util.ParseChatMessages(initial_prompt)

  var chat_content = trim(join(getline(1, '$'), "\n"))
  vim9_ai_util.DebugWrite('[' .. command_type .. '] text:' .. "\n" .. chat_content)
  var chat_messages = vim9_ai_util.ParseChatMessages(chat_content)
  var messages = initial_messages + chat_messages

  try
    var last_content = messages[-1]['content'][-1]
    # if empty :AIC is called outside of the chat, just init/switch to the chat
    # but don't trigger the request
    var should_immediately_answer = !empty(prompt) || started_from_chat
    var awaiting_response = last_content['type'] !=# 'text' || !empty(last_content['text'])
          || has_key(messages[-1], 'tool_calls')
    if awaiting_response && should_immediately_answer
      redraw
      echomsg 'Answering...'
      redraw

      if string(g:vim9_ai_async_chat) ==# '1'
        AIChatJobNew(context, messages, options, provider)
      else
        var previous_type = ''
        var error_message = ''
        var rendered_any = false
        def ChunkCb(chunk: dict<any>)
          if previous_type != chunk['type']
            vim9_ai_util.AppendTextAtCursor("\n<<< " .. chunk['type'] .. "\n\n")
            previous_type = chunk['type']
          endif
          if vim9_ai_util.RenderTextChunk(chunk['content'], true, false, !rendered_any)
            rendered_any = true
          endif
        enddef
        def DoneCb()
          # nothing extra
        enddef
        def ErrCb(msg: string)
          error_message = msg
        enddef
        var job = vim9_ai_provider.ProviderRequest(provider, command_type, options, messages,
              {'provider': provider, 'chunk': ChunkCb, 'done': DoneCb, 'error': ErrCb})
        vim9_ai_curl.WaitForJob(job, GetRequestTimeoutMs(options))
        if !empty(error_message)
          vim9_ai_util.PrintInfoMessage(error_message)
          return false
        endif
        if !rendered_any
          vim9_ai_util.PrintInfoMessage('Empty response received. Tip: You can try modifying the prompt and retry.')
          return false
        endif
        vim9_ai_util.AppendTextAtCursor("\n\n>>> user\n\n")
        redraw
        vim9_ai_util.ClearEchoMessage()
      endif
      return true
    else
      return false
    endif
  catch
    if v:exception =~# 'Vim:Interrupt'
      vim9_ai_util.PrintInfoMessage('Completion cancelled...')
    else
      vim9_ai_util.PrintInfoMessage(v:exception)
    endif
    vim9_ai_util.DebugWrite('[' .. command_type .. '] error: ' .. v:exception .. ' @ ' .. v:throwpoint)
    return false
  endtry
enddef

#  Stop current chat job
export def AIChatStopRun(): void
  if &filetype !=# 'aichat'
    echoerr 'Not in an AI chat buffer.'
    return
  endif
  var bufnr = bufnr('%')
  AIChatJobCancel(bufnr)
  AIChatUndoCleanup()
enddef

#  Function called in a timer that checks if there are new lines from AI and
#  appends them to the buffer. It ends when the AI job is finished (or stopped).
export def AIChatWatch(bufnr: number, anim_index: number): void
  var done = AIChatJobIsDone(bufnr)
  var result = AIChatJobPickupLines(bufnr)

  # if the user is scrolling over the chat while answering, do not auto-scroll
  var should_prevent_autoscroll = bufnr('%') == bufnr && line('.') != line('$')

  deletebufline(bufnr, '$')
  deletebufline(bufnr, '$')
  appendbufline(bufnr, '$', result)

  # if not done, queue timer and animate
  if !done
    timer_start(chat_redraw_interval, (_timer) => AIChatWatch(bufnr, anim_index + 1))
    appendbufline(bufnr, '$', '')
    var animations = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
    var current_animation = animations[anim_index % len(animations)]
    appendbufline(bufnr, '$', '<<< answering ' .. current_animation)
  else
    AIChatUndoCleanup()
    # clear message
    # https://neovim.discourse.group/t/how-to-clear-the-echo-message-in-the-command-line/268/3
    feedkeys(':', 'nx')
  endif

  # if the window is visible and the user is not scrolling, auto-scroll down
  var winid = bufwinid(bufnr)
  if winid != -1 && !should_prevent_autoscroll
    win_execute(winid, 'normal! G')
  endif
enddef

#  Start a new chat (deprecated)
export def AINewChatDeprecatedRun(...args: list<any>): void
  echoerr ':AINew is deprecated, use pre-configured roles `/tab`, `/below`, `/right` instead (e.g. `:AIChat /right`)'
enddef

#  Repeat last AI command
export def AIRedoRun(): void
  if last_command !=# 'image'
    undo
  endif
  redo_selection_hint = last_is_selection ? 1 : 0
  redo_firstline = last_firstline
  redo_lastline = last_lastline
  try
    if last_command ==# 'complete'
      AIRun(last_uses_range, last_firstline, last_lastline, last_config, last_instruction)
    elseif last_command ==# 'edit'
      AIEditRun(last_uses_range, last_firstline, last_lastline, last_config, last_instruction)
    elseif last_command ==# 'image'
      AIImageRun(last_uses_range, last_firstline, last_lastline, last_config, last_instruction)
    elseif last_command ==# 'chat'
      # chat does not need a prompt, all information is in the buffer already
      AIChatRun(0, last_firstline, last_lastline, last_config)
    endif
  finally
    redo_selection_hint = -1
    redo_firstline = 1
    redo_lastline = 1
  endtry
enddef

def RoleCompletion(A: string, command_type: string): list<string>
  if A !~# '^/'
    return []
  endif
  var role_list = vim9_ai_roles.LoadAiRoleNames(command_type)
  var prefixed: list<string> = []
  for role in role_list
    add(prefixed, '/' .. role)
  endfor
  var filtered: list<string> = []
  for item in prefixed
    if item =~# '^' .. A
      add(filtered, item)
    endif
  endfor
  return filtered
enddef

export def RoleCompletionComplete(A: string, L: string, P: number): list<string>
  return RoleCompletion(A, 'complete')
enddef

export def RoleCompletionImage(A: string, L: string, P: number): list<string>
  return RoleCompletion(A, 'image')
enddef

export def RoleCompletionEdit(A: string, L: string, P: number): list<string>
  return RoleCompletion(A, 'edit')
enddef

export def RoleCompletionChat(A: string, L: string, P: number): list<string>
  return RoleCompletion(A, 'chat')
enddef

export def AIUtilRolesOpen(): void
  exe 'e ' .. g:vim9_ai_roles_config_file
enddef

export def AIUtilSetDebug(is_debug: number): void
  g:vim9_ai_debug = is_debug
enddef
