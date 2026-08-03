vim9script

#  Prompt building and configuration merging for vim9-ai.

import autoload 'vim9_ai_roles.vim'

def MergeDeepRecursive(target: dict<any>, source: dict<any>): void
  for [key, value] in items(source)
    if type(value) == v:t_dict
      if has_key(target, key) && type(target[key]) == v:t_dict
        MergeDeepRecursive(target[key], value)
      else
        var child: dict<any> = {}
        target[key] = child
        MergeDeepRecursive(child, value)
      endif
    else
      target[key] = value
    endif
  endfor
enddef

def MergeDeep(objects: list<any>): dict<any>
  var result: dict<any> = {}
  for obj in objects
    if type(obj) == v:t_dict
      MergeDeepRecursive(result, obj)
    endif
  endfor
  return result
enddef

def ParseRoleNames(prompt: string): list<string>
  var words = split(prompt)
  var leading_count = 0
  for word in words
    if word !~# '^/'
      break
    endif
    leading_count += 1
  endfor
  var trailing_count = 0
  for i in range(len(words) - 1, leading_count, -1)
    if words[i] !~# '^/'
      break
    endif
    trailing_count += 1
  endfor
  var trailing_start = trailing_count > 0 ? len(words) - trailing_count : len(words)
  var roles: list<string> = []
  for i in range(leading_count)
    add(roles, words[i][1 :])
  endfor
  for i in range(trailing_start, len(words) - 1)
    add(roles, words[i][1 :])
  endfor
  return roles
enddef

def ParsePromptAndRoleConfig(user_instruction: string, command_type: string): list<any>
  var instruction = trim(user_instruction)
  var words = split(instruction)
  var roles = ParseRoleNames(instruction)
  var leading_count = 0
  for word in words
    if word !~# '^/'
      break
    endif
    leading_count += 1
  endfor
  var trailing_count = len(roles) - leading_count
  var trailing_start = len(words) - trailing_count
  var user_prompt = join(words[leading_count : trailing_start], ' ')
  var role_results: list<any> = []
  for role in ['default'] + roles
    add(role_results, vim9_ai_roles.LoadRoleConfig(role))
  endfor
  var parsed_role = MergeDeep(role_results)
  var config = MergeDeep([
    get(parsed_role, 'role_default', {}),
    get(parsed_role, 'role_' .. command_type, {}),
  ])
  return [user_prompt, config, roles]
enddef

def MakeSelectionBoundary(user_selection: string, selection_boundary: string): list<string>
  if selection_boundary !=# '```'
    return [selection_boundary, selection_boundary]
  endif
  var filetype = &filetype
  if !empty(filetype) && filetype !=# 'aichat'
    return [selection_boundary .. filetype, selection_boundary]
  endif
  return [selection_boundary, selection_boundary]
enddef

def MakeSelectionPrompt(user_selection: string, user_prompt: string, config_prompt: string,
      selection_boundary: string): string
  if empty(user_prompt) && empty(config_prompt)
    return user_selection
  elseif !empty(user_selection)
    if !empty(selection_boundary) && stridx(user_selection, selection_boundary) == -1
      var boundaries = MakeSelectionBoundary(user_selection, selection_boundary)
      return boundaries[0] .. "\n" .. user_selection .. "\n" .. boundaries[1]
    else
      return user_selection
    endif
  endif
  return ''
enddef

def MakePrompt(config_prompt: string, user_prompt: string, user_selection: string,
      selection_boundary: string): string
  var prompt_text = trim(user_prompt)
  var delimiter = !empty(prompt_text) && !empty(user_selection) ? ":\n" : ''
  var selection = MakeSelectionPrompt(user_selection, prompt_text, config_prompt, selection_boundary)
  var prompt = prompt_text .. delimiter .. selection
  if empty(config_prompt)
    return prompt
  endif
  delimiter = prompt =~# '^:' ? '' : ":\n"
  return config_prompt .. delimiter .. prompt
enddef

export def MakeAiContext(params: dict<any>): dict<any>
  var config_default = params['config_default']
  var config_extension = params['config_extension']
  var user_instruction = params['user_instruction']
  var user_selection = params['user_selection']
  var command_type = params['command_type']

  var parsed = ParsePromptAndRoleConfig(user_instruction, command_type)
  var user_prompt = parsed[0]
  var role_config = parsed[1]
  var roles = parsed[2]
  var final_config = MergeDeep([config_default, config_extension, role_config])
  var selection_boundary = get(get(final_config, 'options', {}), 'selection_boundary', '')
  var config_prompt = get(final_config, 'prompt', '')
  var prompt = MakePrompt(config_prompt, user_prompt, user_selection, selection_boundary)

  return {
    'command_type': command_type,
    'config': final_config,
    'prompt': prompt,
    'roles': roles,
  }
enddef
