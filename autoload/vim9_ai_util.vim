vim9script

#  Utility functions for vim9-ai.
#  Text rendering, chat content parsing, token loading, base64 helpers and
#  platform command execution. No Python, no legacy Vim script.

export def DebugWrite(text: string): void
  if !exists('g:vim9_ai_debug') || string(g:vim9_ai_debug) !=# '1'
    return
  endif
  var path = exists('g:vim9_ai_debug_log_file') ? expand(g:vim9_ai_debug_log_file) : '/tmp/vim9_ai_debug.log'
  try
    writefile(['[' .. strftime('%Y-%m-%d %H:%M:%S') .. '] ' .. text], path, 'a')
  catch
    # debug logging must never break the plugin
  endtry
enddef

def LoadTokenFromFile(path: string): string
  if empty(path)
    return ''
  endif
  var expanded = expand(path)
  if !filereadable(expanded)
    return ''
  endif
  return trim(join(readfile(expanded), "\n"))
enddef

def LoadTokenFromFn(expression: string): string
  if empty(expression)
    return ''
  endif
  var token = eval(expression)
  return type(token) == v:t_string ? trim(token) : ''
enddef

export def LoadApiKey(env_variable_name: string, token_file_path: string, token_load_fn: string): string
  var api_key = ''
  # token_file_path -> token_load_fn -> env variable -> global token_file_path -> global token_load_fn
  try
    api_key = LoadTokenFromFile(token_file_path)
  catch
    api_key = ''
  endtry
  if !empty(api_key)
    return api_key
  endif
  try
    api_key = LoadTokenFromFn(token_load_fn)
  catch
    api_key = ''
  endtry
  if !empty(api_key)
    return api_key
  endif
  var env_token = getenv(env_variable_name)
  if type(env_token) == v:t_string && !empty(env_token)
    return trim(env_token)
  endif
  try
    api_key = LoadTokenFromFile(exists('g:vim9_ai_token_file_path') ? g:vim9_ai_token_file_path : '')
  catch
    api_key = ''
  endtry
  if !empty(api_key)
    return api_key
  endif
  try
    api_key = LoadTokenFromFn(exists('g:vim9_ai_token_load_fn') ? g:vim9_ai_token_load_fn : '')
  catch
    api_key = ''
  endtry
  if !empty(api_key)
    return api_key
  endif
  throw 'Missing API key'
enddef

#  When running AIEdit on a selection and the cursor ends on the first column,
#  it needs to be decided whether to append (a) or insert (i) to prevent
#  misalignment. Example: helloxxx<Esc>hhhvb:AIE translate<CR> -
#  expected Holaxxx, not xHolaxx
export def NeedInsertBeforeCursor(): bool
  return getpos("'<")[2] == 1
enddef

export def MakeOptions(options: dict<any>): dict<any>
  # initial prompt can be both a string and a list of strings, normalize it to a list
  if has_key(options, 'initial_prompt') && type(options['initial_prompt']) == v:t_string
    options['initial_prompt'] = split(options['initial_prompt'], "\n", 1)
  endif
  return options
enddef

export def MakeConfig(config: dict<any>): dict<any>
  if type(get(config, 'options', {})) == v:t_dict
    MakeOptions(config['options'])
  endif
  return config
enddef

export def BreakUndoSequence(): void
  # breaks the undo sequence (https://vi.stackexchange.com/a/29087)
  &undolevels = &undolevels
enddef

export def PrintInfoMessage(msg: string): void
  redraw
  echohl ErrorMsg
  echomsg msg
  echohl None
enddef

export def ClearEchoMessage(): void
  # clears the "Completing..." message from the status line
  # feedkeys(':', 'nx') temporarily disabled for diagnosis
enddef

#  Inserts {text} at the current cursor position without leaving Normal mode.
#  append_to_eol: append at the end of the current line.
#  insert_before_cursor: insert before the character under the cursor.
def InsertTextAtCursor(text: string, append_to_eol: bool, insert_before_cursor: bool): void
  if empty(text)
    return
  endif
  var lnum = line('.')
  var col = col('.')
  var cur_line = getline(lnum)
  var parts = split(text, "\n", 1)
  var first = parts[0]
  var rest = parts[1 :]
  var idx = append_to_eol ? len(cur_line) : (insert_before_cursor ? col - 1 : col)
  var prefix = idx > 0 ? cur_line[: idx - 1] : ''
  var new_line = prefix .. first .. cur_line[idx :]
  call setline(lnum, new_line)
  if !empty(rest)
    call append(lnum, rest)
  endif
  var last_line = !empty(rest) ? rest[-1] : new_line
  call cursor(lnum + len(rest), len(last_line) + 1)
enddef

export def AppendTextAtCursor(text: string): void
  InsertTextAtCursor(text, true, false)
enddef

export def RenderTextChunk(text0: string, append_to_eol: bool, insert_before_cursor: bool,
      strip_leading: bool): bool
  # Renders a single response chunk at the cursor. Returns true when any text
  # was inserted (used to detect empty responses and leading-whitespace trim).
  var text = text0
  if strip_leading
    # trim newlines from the beginning
    text = substitute(text, '^\s\+', '', '')
  endif
  if empty(text)
    return false
  endif
  InsertTextAtCursor(text, append_to_eol, insert_before_cursor)
  undojoin
  redraw
  return true
enddef

export def RenderTextChunks(chunks: list<string>, append_to_eol: bool): void
  var generating_text = false
  var full_text = ''
  var insert_before_cursor = NeedInsertBeforeCursor()
  for chunk_text in chunks
    var text = chunk_text
    var rendered = RenderTextChunk(text, append_to_eol, insert_before_cursor, !generating_text)
    insert_before_cursor = false
    if rendered
      generating_text = true
      full_text ..= text
    endif
  endfor
  if empty(trim(full_text))
    throw 'Empty response received. Tip: You can try modifying the prompt and retry.'
  endif
enddef

export def IsImagePath(path: string): bool
  var parts = split(path, '\.')
  var ext = len(parts) > 0 ? tolower(parts[-1]) : ''
  return index(['jpg', 'jpeg', 'png', 'gif'], ext) != -1
enddef

export def ParseIncludePaths(path: string): list<string>
  if empty(path)
    return []
  endif
  var expanded = expand(path)
  var expanded_paths = [expanded]
  if stridx(expanded, '*') != -1
    expanded_paths = glob(expanded, 0, 1)
  endif
  var result: list<string> = []
  for p in expanded_paths
    if !isdirectory(p)
      add(result, p)
    endif
  endfor
  return result
enddef

export def MakeTextFileMessage(path: string): dict<any>
  var file_content_start = '==> ' .. path .. ' <==' .. "\n"
  var file_content_end = "\n==> END OF FILE <=="
  var content = file_content_start .. 'Binary file, cannot display' .. file_content_end
  try
    var joined = join(readfile(path, 'b'), "\n")
    if stridx(joined, "\x00") == -1 && stridx(joined, "\xff") == -1
      content = file_content_start .. trim(joined) .. file_content_end
    endif
  catch
    # binary or unreadable file, use the fallback message
  endtry
  return {'type': 'text', 'text': content}
enddef

export def MakeExecOutputMessage(cmd: string): dict<any>
  var output = RunCommand(cmd, 5000)
  return {'type': 'text', 'text': '==> ' .. cmd .. ' <==' .. "\n" .. output}
enddef

export def MakeImageMessage(path: string): dict<any>
  var parts = split(path, '\.')
  var ext = len(parts) > 0 ? parts[-1] : ''
  var b64_image = readblob(path)->base64_encode()
  return {'type': 'image_url', 'image_url': {'url': 'data:image/' .. ext .. ';base64,' .. b64_image}}
enddef

export def MakeImagePath(ui: dict<any>): string
  var download_dir = get(ui, 'download_dir', '')
  if empty(download_dir)
    download_dir = getcwd()
  endif
  var timestamp = strftime('%Y%m%dT%H%M%SZ')
  var filename = 'vim9_ai_' .. timestamp .. '.png'
  return download_dir .. (download_dir =~# '[/\\]$' ? '' : '/') .. filename
enddef

export def SaveB64ToFile(path: string, b64_data: string): void
  base64_decode(b64_data)->writefile(path, 'b')
enddef

#  Runs a shell command with a timeout and returns its stdout.
def RunCommand(cmd: string, timeout_ms: number): string
  var output: list<string> = []
  def OutCb(ch: channel, data: string)
    add(output, data)
  enddef
  var argv = has('win32') ? ['cmd.exe', '/c', cmd] : ['sh', '-c', cmd]
  var job = job_start(argv, {'out_cb': OutCb})
  var waited = 0
  while job_status(job) ==# 'run' && waited < timeout_ms
    sleep 50m
    waited += 50
  endwhile
  if job_status(job) ==# 'run'
    job_stop(job)
  endif
  return join(output, '')
enddef

#  Parses the chat buffer into OpenAI messages.
export def ParseChatMessages(chat_content: string): list<dict<any>>
  var lines = split(chat_content, "\n", 1)
  var messages: list<dict<any>> = []
  var current_type = ''
  for line in lines
    if line ==# '>>> system'
      add(messages, {'role': 'system', 'content': [{'type': 'text', 'text': ''}]})
      current_type = 'system'
    elseif line ==# '<<< thinking'
      # thinking messages are omitted from the request
      current_type = 'thinking'
    elseif line ==# '<<< assistant'
      add(messages, {'role': 'assistant', 'content': [{'type': 'text', 'text': ''}]})
      current_type = 'assistant'
    elseif line ==# '>>> user'
      if !empty(messages) && messages[-1]['role'] ==# 'user'
        add(messages[-1]['content'], {'type': 'text', 'text': ''})
      else
        add(messages, {'role': 'user', 'content': [{'type': 'text', 'text': ''}]})
      endif
      current_type = 'user'
    elseif line ==# '<<< tool_call'
      add(messages, {'role': 'assistant', 'content': [{'type': 'text', 'text': ''}], 'tool_calls': []})
      current_type = 'tool_call'
    elseif line ==# '<<< tool_response'
      add(messages, {'role': 'tool', 'content': [{'type': 'text', 'text': ''}]})
      current_type = 'tool_response'
    elseif line ==# '<<< info'
      # can be used to ask the user for confirmation (by running :AIChat again)
      current_type = 'info'
    elseif line ==# '>>> include'
      if empty(messages) || messages[-1]['role'] !=# 'user'
        add(messages, {'role': 'user', 'content': []})
      endif
      current_type = 'include'
    elseif line ==# '>>> exec'
      if empty(messages) || messages[-1]['role'] !=# 'user'
        add(messages, {'role': 'user', 'content': []})
      endif
      current_type = 'exec'
    else
      if empty(messages)
        continue
      endif
      if current_type ==# 'assistant' || current_type ==# 'system' || current_type ==# 'user'
        messages[-1]['content'][-1]['text'] ..= "\n" .. line
      elseif current_type ==# 'include'
        var paths = ParseIncludePaths(line)
        for path in paths
          var content = IsImagePath(path) ? MakeImageMessage(path) : MakeTextFileMessage(path)
          add(messages[-1]['content'], content)
        endfor
      elseif current_type ==# 'exec'
        var cmd = trim(line)
        if !empty(cmd)
          add(messages[-1]['content'], MakeExecOutputMessage(cmd))
        endif
      elseif current_type ==# 'tool_call' || current_type ==# 'tool_response'
        var payload = trim(line)
        if !empty(payload)
          messages[-1] = json_decode(payload)
        endif
      elseif current_type ==# 'info'
        # nothing
      endif
    endif
  endfor
  # strip newlines from the text content as it causes empty responses
  for message in messages
    for content in message['content']
      if content['type'] ==# 'text'
        content['text'] = trim(content['text'])
      endif
    endfor
  endfor
  return messages
enddef

export def ParseChatHeaderConfig(lines: list<string>): dict<any>
  var config: dict<any> = {'provider': '', 'options': {}, 'ui': {}}
  if index(lines, '[chat-options]') != -1
    throw '[chat-options] is deprecated, use new [chat] syntax'
  endif
  if index(lines, '[chat]') == -1
    return config
  endif
  try
    var options_index = index(lines, '[chat]')
    for i in range(options_index + 1, len(lines) - 1)
      var line = trim(lines[i])
      if line =~# '^#'
        continue
      endif
      if empty(line)
        break
      endif
      var eq = stridx(line, '=')
      if eq == -1
        throw 'invalid entry'
      endif
      var key = trim(line[: eq - 1])
      var value = trim(line[eq + 1 :])
      if key ==# 'provider'
        config['provider'] = value
      else
        var dot = stridx(key, '.')
        if dot == -1
          throw 'invalid entry'
        endif
        var base = key[: dot - 1]
        var option_key = key[dot + 1 :]
        if option_key ==# 'initial_prompt'
          config[base][option_key] = split(value, '\\n', 1)
        else
          config[base][option_key] = value
        endif
      endif
    endfor
  catch
    throw 'Invalid [chat] config'
  endtry
  return config
enddef
