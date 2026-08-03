vim9script

#  OpenAI compatible provider implementation for vim9-ai.
#  All HTTP traffic goes through the external curl executable.

import autoload 'vim9_ai_curl.vim'
import autoload 'vim9_ai_util.vim'

def ConvertOption(options: dict<any>, name: string, Converter: func(string): any): void
  if !has_key(options, name)
    return
  endif
  var value = options[name]
  if type(value) != v:t_string || empty(value)
    return
  endif
  try
    options[name] = Converter(value)
  catch
    throw 'Invalid value for option ''' .. name .. ''': ' .. value .. '. Error: ' .. v:exception
  endtry
enddef

def ParseRawOptions(command_type: string, raw_options: dict<any>): dict<any>
  var varname = 'vim9_ai_openai_' .. command_type
  var default_options = exists('g:' .. varname) ? g:[varname] : {}
  var options: dict<any> = {}
  for [key, value] in items(default_options)
    options[key] = value
  endfor
  for [key, value] in items(raw_options)
    options[key] = value
  endfor

  var enable_auth = get(options, 'enable_auth', '')
  if type(enable_auth) == v:t_string && enable_auth ==# '0'
    throw '`enable_auth = 0` option is no longer supported. use `auth_type = none` instead'
  endif

  ConvertOption(options, 'request_timeout', (s) => str2float(s))

  if command_type !=# 'image'
    ConvertOption(options, 'stream', (s) => str2nr(s) != 0)
    ConvertOption(options, 'max_tokens', (s) => str2nr(s))
    ConvertOption(options, 'max_completion_tokens', (s) => str2nr(s))
    ConvertOption(options, 'temperature', (s) => str2float(s))
    ConvertOption(options, 'frequency_penalty', (s) => str2float(s))
    ConvertOption(options, 'presence_penalty', (s) => str2float(s))
    ConvertOption(options, 'top_p', (s) => str2float(s))
    ConvertOption(options, 'seed', (s) => str2nr(s))
    ConvertOption(options, 'top_logprobs', (s) => str2nr(s))
    ConvertOption(options, 'logprobs', (s) => str2nr(s) != 0)
    ConvertOption(options, 'stop', (s) => json_decode(s))
    ConvertOption(options, 'logit_bias', (s) => json_decode(s))
    # reasoning_effort is a string, no conversion needed
    # openrouter reasoning parameter
    ConvertOption(options, 'reasoning', (s) => json_decode(s))
  endif
  return options
enddef

def MakeOpenAiOptions(options: dict<any>): dict<any>
  var result = {'model': options['model']}
  var option_keys = ['stream', 'temperature', 'max_tokens', 'max_completion_tokens',
        'web_search_options', 'frequency_penalty', 'logit_bias', 'logprobs',
        'presence_penalty', 'reasoning_effort', 'seed', 'stop', 'top_logprobs',
        'top_p', 'reasoning']
  for key in option_keys
    if !has_key(options, key)
      continue
    endif
    var value = options[key]
    if type(value) == v:t_string && empty(value)
      continue
    endif
    # "stream" and "logprobs" are boolean API parameters. Normalize them to a
    # real boolean so strict OpenAI-compatible endpoints do not reject the
    # request ("stream: 1" instead of "stream: true").
    if key ==# 'stream' || key ==# 'logprobs'
      if type(value) == v:t_bool
        result[key] = value
      elseif type(value) == v:t_string
        result[key] = str2nr(value) != 0
      else
        result[key] = value != 0
      endif
      continue
    endif
    # Backward compatibility: empty string "" used to exclude these params
    if key ==# 'temperature' && type(value) != v:t_string && value == -1
      continue
    endif
    if key ==# 'max_tokens' && type(value) != v:t_string && value == 0
      continue
    endif
    if key ==# 'max_completion_tokens' && type(value) != v:t_string && value == 0
      continue
    endif
    result[key] = value
  endfor
  return result
enddef

#  Some providers (e.g. api.deepseek.com, api.groq.com) expect a flat content
#  field for system and assistant messages.
def FlattenMessages(messages: list<any>): list<any>
  var result: list<any> = []
  for message in messages
    var m = copy(message)
    if index(['system', 'assistant'], m['role']) != -1
      var texts: list<string> = []
      for content in m['content']
        add(texts, content['text'])
      endfor
      m['content'] = join(texts, "\n")
    endif
    add(result, m)
  endfor
  return result
enddef

def LoadApiKeyWithOrg(options: dict<any>): list<any>
  var raw_api_key = vim9_ai_util.LoadApiKey('OPENAI_API_KEY',
        get(options, 'token_file_path', ''),
        get(options, 'token_load_fn', ''))
  # The text is in the format of "<api key>,<org id>" and the
  # <org id> part is optional
  var elements = split(raw_api_key, ',')
  var api_key = trim(elements[0])
  var org_id = ''
  if len(elements) > 1
    org_id = trim(elements[1])
  endif
  return [api_key, org_id]
enddef

def BuildHeaders(http_options: dict<any>): dict<string>
  var headers: dict<string> = {
    'Content-Type': 'application/json',
    'User-Agent': 'VimAI',
  }
  var auth_type = http_options['auth_type']
  if auth_type ==# 'bearer'
    var key_org = LoadApiKeyWithOrg(http_options)
    headers['Authorization'] = 'Bearer ' .. key_org[0]
    if !empty(key_org[1])
      headers['OpenAI-Organization'] = key_org[1]
    endif
  elseif auth_type ==# 'api-key'
    var key_org = LoadApiKeyWithOrg(http_options)
    headers['api-key'] = key_org[0]
  endif
  return headers
enddef

def MakeHttpOptions(options: dict<any>): dict<any>
  var request_timeout = get(options, 'request_timeout', 20)
  if request_timeout <= 0
    request_timeout = 20
  endif
  return {
    'request_timeout': request_timeout,
    'auth_type': get(options, 'auth_type', 'bearer'),
    'token_file_path': get(options, 'token_file_path', ''),
    'token_load_fn': get(options, 'token_load_fn', ''),
  }
enddef

#  Maps a response JSON object to a {type, content} chunk.
def MapChunk(resp: dict<any>, is_stream: bool): dict<any>
  var choice_key = is_stream ? 'delta' : 'message'
  var choices = get(resp, 'choices', [{}])
  var delta = get(choices[0], choice_key, {})
  if has_key(delta, 'reasoning_content') && !empty(delta['reasoning_content'])
    # deepseek reasoning_content
    return {'type': 'thinking', 'content': delta['reasoning_content']}
  elseif has_key(delta, 'reasoning') && !empty(delta['reasoning'])
    # openrouter reasoning
    return {'type': 'thinking', 'content': delta['reasoning']}
  elseif has_key(delta, 'content') && !empty(delta['content'])
    return {'type': 'assistant', 'content': delta['content']}
  endif
  return {}
enddef

def ParseErrorBody(raw: string): string
  try
    var parsed = json_decode(raw)
    if type(parsed) == v:t_dict
      return get(get(parsed, 'error', {}), 'message', '')
    endif
  catch
    # not a JSON body, fall through
  endtry
  return ''
enddef

def FormatHttpError(provider_name: string, state: dict<any>): string
  var msg = provider_name .. ': HTTPError ' .. state['http_code']
  var error_message = ParseErrorBody(state['raw'])
  if !empty(error_message)
    msg ..= ': ' .. error_message
  endif
  return msg
enddef

def ReadStderr(state: dict<any>): string
  var path = state['stderr_path']
  if empty(path) || !filereadable(path)
    return ''
  endif
  return trim(join(readfile(path), ' '))
enddef

def ParseHttpCode(state: dict<any>): number
  var path = state['header_path']
  if empty(path) || !filereadable(path)
    return 0
  endif
  var header_lines = readfile(path)
  for header_line in header_lines
    var m = matchlist(header_line, '^HTTP/\S\+\s\+\(\d\{3}\)')
    if !empty(m)
      return str2nr(m[1])
    endif
  endfor
  return 0
enddef

def CleanupTmpFiles(state: dict<any>): void
  for path in [state['body_path'], state['stderr_path'], state['header_path']]
    if !empty(path)
      try
        delete(path)
      catch
      endtry
    endif
  endfor
enddef

#  Starts a streaming or non-streaming chat completion request. Returns the
#  curl job. callbacks: {chunk, done, error} where chunk is func(dict),
#  done is func() and error is func(string).
export def Request(provider_name: string, command_type: string, raw_options: dict<any>,
      messages: list<any>, callbacks: dict<any>): job
  var options = ParseRawOptions(command_type, raw_options)
  var openai_options = MakeOpenAiOptions(options)
  var request: dict<any> = {'messages': FlattenMessages(messages)}
  for [key, value] in items(openai_options)
    request[key] = value
  endfor
  vim9_ai_util.DebugWrite('openai: [' .. command_type .. '] request: ' .. string(request))
  var url = options['endpoint_url']
  var http_options = MakeHttpOptions(options)
  var headers = BuildHeaders(http_options)
  var stream_value = get(openai_options, 'stream', 0)
  var stream = type(stream_value) == v:t_bool ? stream_value : (stream_value != 0)

  var body_path = vim9_ai_curl.WriteBodyFile(request)
  var stderr_path = tempname()
  var header_path = tempname()
  var extra = ['--stderr', stderr_path, '-D', header_path]
  if stream
    add(extra, '-N')
  endif
  var args = vim9_ai_curl.CurlArgs(url, headers, body_path, http_options['request_timeout'], extra)

  var state = {
    'pending': '',
    'raw': '',
    'http_code': 0,
    'status': 0,
    'body_path': body_path,
    'stderr_path': stderr_path,
    'header_path': header_path,
  }

  def OutCb(ch: channel, data: string)
    state['raw'] ..= data .. "\n"
    if stream
      state['pending'] ..= data
      var nl = stridx(state['pending'], "\n")
      while nl != -1
        var line = state['pending'][: nl - 1]
        state['pending'] = state['pending'][nl + 1 :]
        ProcessSseLine(state, callbacks, line)
        nl = stridx(state['pending'], "\n")
      endwhile
    endif
  enddef

  def ExitCb(job: job, status: number)
    state['status'] = status
    state['http_code'] = ParseHttpCode(state)
    if stream && !empty(state['pending'])
      ProcessSseLine(state, callbacks, state['pending'])
    endif
    var error_msg = ''
    if state['http_code'] >= 400
      error_msg = FormatHttpError(provider_name, state)
    elseif status == 28
      error_msg = 'Request timeout...'
    elseif status != 0
      var stderr_text = ReadStderr(state)
      error_msg = 'URLError: ' .. (!empty(stderr_text) ? stderr_text : 'curl exited with status ' .. status)
    endif
    if !stream && empty(error_msg)
      try
        var resp = json_decode(state['raw'])
        if type(resp) == v:t_dict
          var chunk = MapChunk(resp, false)
          if !empty(chunk)
            call callbacks['chunk'](chunk)
          endif
        endif
      catch
        error_msg = 'URLError: invalid JSON response: ' .. v:exception
      endtry
    endif
    CleanupTmpFiles(state)
    if !empty(error_msg)
      call callbacks['error'](error_msg)
    else
      call callbacks['done']()
    endif
  enddef

  return job_start(args, {'out_cb': OutCb, 'exit_cb': ExitCb, 'out_mode': 'raw'})
enddef

def ProcessSseLine(state: dict<any>, callbacks: dict<any>, line: string): void
  if line !~# '^data: '
    return
  endif
  var payload = substitute(line[6 :], '\r$', '', '')
  if trim(payload) ==# '[DONE]'
    return
  endif
  try
    var obj = json_decode(payload)
    if type(obj) == v:t_dict
      var chunk = MapChunk(obj, true)
      if !empty(chunk)
        call callbacks['chunk'](chunk)
      endif
    endif
  catch
    # ignore malformed SSE lines
  endtry
enddef

#  Synchronously requests an image and returns a list of {b64_data} dicts.
export def RequestImage(provider_name: string, command_type: string,
      raw_options: dict<any>, prompt: string): list<any>
  var options = ParseRawOptions(command_type, raw_options)
  var request = {
    'prompt': prompt,
    'model': options['model'],
    'quality': options['quality'],
    'size': options['size'],
    'style': options['style'],
    'response_format': 'b64_json',
  }
  vim9_ai_util.DebugWrite('openai: [' .. command_type .. '] request: ' .. string(request))
  var http_options = MakeHttpOptions(options)
  var headers = BuildHeaders(http_options)
  var body_path = vim9_ai_curl.WriteBodyFile(request)
  var stderr_path = tempname()
  var header_path = tempname()
  var args = vim9_ai_curl.CurlArgs(options['endpoint_url'], headers, body_path,
        http_options['request_timeout'], ['--stderr', stderr_path, '-D', header_path])

  var state = {'raw': '', 'http_code': 0, 'status': 0, 'body_path': body_path,
        'stderr_path': stderr_path, 'header_path': header_path}
  def OutCb(ch: channel, data: string)
    state['raw'] ..= data
  enddef
  def ExitCb(job: job, status: number)
    state['status'] = status
  enddef
  var job = job_start(args, {'out_cb': OutCb, 'exit_cb': ExitCb, 'out_mode': 'raw'})
  vim9_ai_curl.WaitForJob(job, float2nr(http_options['request_timeout']) * 1000 + 30000)
  state['http_code'] = ParseHttpCode(state)
  var error_msg = ''
  if state['http_code'] >= 400
    error_msg = FormatHttpError(provider_name, state)
  elseif state['status'] == 28
    error_msg = 'Request timeout...'
  elseif state['status'] != 0
    var stderr_text = ReadStderr(state)
    error_msg = 'URLError: ' .. (!empty(stderr_text) ? stderr_text : 'curl exited with status ' .. state['status'])
  endif
  try
    delete(body_path)
    delete(stderr_path)
    delete(header_path)
  catch
  endtry
  if !empty(error_msg)
    throw error_msg
  endif
  var resp = json_decode(state['raw'])
  var b64_data = resp['data'][0]['b64_json']
  return [{'b64_data': b64_data}]
enddef
