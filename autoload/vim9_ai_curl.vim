vim9script

#  curl based HTTP layer for vim9-ai. All network access goes through the
#  external curl executable; this file only builds arguments, starts jobs and
#  waits for them to finish.

export def CurlArgs(url: string, headers: dict<string>, body_path: string,
      request_timeout: number, extra: list<string>): list<string>
  var args = ['curl', '-sS', '--max-time', string(float2nr(request_timeout)), '-X', 'POST', url]
  for [key, value] in items(headers)
    add(args, '-H')
    add(args, key .. ': ' .. value)
  endfor
  var proxy = exists('g:vim9_ai_proxy') ? trim(g:vim9_ai_proxy) : ''
  if !empty(proxy)
    extend(args, ['--proxy', proxy])
  endif
  extend(args, extra)
  extend(args, ['-d', '@' .. body_path])
  return args
enddef

export def WriteBodyFile(body: dict<any>): string
  var path = tempname()
  writefile([json_encode(body)], path)
  return path
enddef

#  Blocks until the job finishes (or the timeout is reached). Job output
#  callbacks are processed while waiting, so streaming callbacks keep working.
export def WaitForJob(job: job, timeout_ms: number): void
  var waited = 0
  while job_status(job) ==# 'run' && waited < timeout_ms
    sleep 50m
    waited += 50
  endwhile
  if job_status(job) ==# 'run'
    job_stop(job)
  endif
enddef
