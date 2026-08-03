vim9script

#  Role (.ini) parsing and role configuration loading for vim9-ai.

var plugin_root = expand('<sfile>:p:h:h')

const DEFAULT_ROLE_NAME = 'default'

#  Minimal INI parser matching the subset used by Python's configparser for
#  role files: sections, `key = value` entries, indented continuation lines and
#  `#`/`;` comments. Option keys are lowercased like configparser does.
def ParseIni(content: list<string>): dict<dict<any>>
  var result: dict<dict<any>> = {}
  var current: dict<any> = {}
  var last_key = ''
  for line0 in content
    var line = line0
    if line =~# '^\s*[#;]'
      continue
    endif
    if line =~# '^\s*\[.*\]\s*$'
      var name = substitute(line, '^\s*\[\s*\(.\{-}\)\s*\]\s*$', '\1', '')
      current = {}
      result[name] = current
      last_key = ''
      continue
    endif
    if line =~# '^\s*$'
      last_key = ''
      continue
    endif
    if line =~# '^\s' && !empty(last_key)
      # continuation line of a multi-line value
      current[last_key] ..= "\n" .. trim(line)
      continue
    endif
    var eq = stridx(line, '=')
    if eq == -1
      eq = stridx(line, ':')
    endif
    if eq == -1
      continue
    endif
    var key = tolower(trim(line[: eq - 1]))
    var value = trim(line[eq + 1 :])
    current[key] = value
    last_key = key
  endfor
  return result
enddef

export def ReadRoleFiles(): dict<dict<any>>
  var default_roles_config_path = plugin_root .. '/roles-default.ini'
  var roles_config_path = expand(g:vim9_ai_roles_config_file)
  if !filereadable(roles_config_path)
    throw 'Role config file does not exist: ' .. roles_config_path
  endif
  var result: dict<dict<any>> = {}
  var defaults = ParseIni(readfile(default_roles_config_path))
  var custom = ParseIni(readfile(roles_config_path))
  for [name, section] in items(defaults)
    result[name] = section
  endfor
  for [name, section] in items(custom)
    result[name] = section
  endfor
  return result
enddef

export def EnhanceRolesWithCustomFunction(roles: dict<dict<any>>): dict<dict<any>>
  if exists('g:vim9_ai_roles_config_function')
    var roles_config_function = g:vim9_ai_roles_config_function
    if !exists('*' .. roles_config_function)
      throw 'Role config function does not exist: ' .. roles_config_function
    endif
    var extra = call(roles_config_function, [])
    if type(extra) == v:t_dict
      for [name, section] in items(extra)
        roles[name] = section
      endfor
    endif
  endif
  return roles
enddef

#  Converts dotted keys (e.g. "options.temperature") into nested dictionaries.
def ParseRoleSection(role: dict<any>): dict<any>
  var result: dict<any> = {}
  for key in keys(role)
    var parts = split(key, '\.')
    var obj = result
    var last = len(parts) - 1
    for i in range(last)
      var part = parts[i]
      if !has_key(obj, part)
        obj[part] = {}
      endif
      obj = obj[part]
    endfor
    obj[parts[last]] = role[key]
  endfor
  return result
enddef

def IsDeprecatedRoleSyntax(roles: dict<dict<any>>, role: string): bool
  var deprecated_sections = ['options', 'options-complete', 'options-edit', 'options-chat',
        'ui', 'ui-complete', 'ui-edit', 'ui-chat']
  for section in deprecated_sections
    if has_key(roles, role .. '.' .. section)
      return true
    endif
  endfor
  return false
enddef

def LoadRolesWithDeprecatedSyntax(roles: dict<dict<any>>, role: string): dict<any>
  var prompt = has_key(roles, role) && has_key(roles[role], 'prompt') ? roles[role]['prompt'] : ''
  return {
    'role_default': {
      'prompt': prompt,
      'options': get(roles, role .. '.options', {}),
      'ui': get(roles, role .. '.ui', {}),
    },
    'role_complete': {
      'prompt': prompt,
      'options': get(roles, role .. '.options-complete', {}),
      'ui': get(roles, role .. '.ui-complete', {}),
    },
    'role_edit': {
      'prompt': prompt,
      'options': get(roles, role .. '.options-edit', {}),
      'ui': get(roles, role .. '.ui-edit', {}),
    },
    'role_chat': {
      'prompt': prompt,
      'options': get(roles, role .. '.options-chat', {}),
      'ui': get(roles, role .. '.ui-chat', {}),
    },
  }
enddef

export def LoadRoleConfig(role: string): dict<any>
  var roles = ReadRoleFiles()
  EnhanceRolesWithCustomFunction(roles)
  var postfixes = ['', '.complete', '.edit', '.chat', '.image']
  var found = false
  for postfix in postfixes
    if has_key(roles, role .. postfix)
      found = true
      break
    endif
  endfor
  if !found
    throw 'Role `' .. role .. '` not found'
  endif
  if IsDeprecatedRoleSyntax(roles, role)
    return LoadRolesWithDeprecatedSyntax(roles, role)
  endif
  return {
    'role_default': ParseRoleSection(get(roles, role, {})),
    'role_complete': ParseRoleSection(get(roles, role .. '.complete', {})),
    'role_edit': ParseRoleSection(get(roles, role .. '.edit', {})),
    'role_chat': ParseRoleSection(get(roles, role .. '.chat', {})),
    'role_image': ParseRoleSection(get(roles, role .. '.image', {})),
  }
enddef

export def LoadAiRoleNames(command_type: string): list<string>
  var roles = ReadRoleFiles()
  EnhanceRolesWithCustomFunction(roles)
  var role_names: dict<bool> = {}
  for name in keys(roles)
    var parts = split(name, '\.')
    if command_type ==# 'image'
      # image roles have to be explicitly defined
      if len(parts) > 1 && parts[-1] ==# command_type
        role_names[parts[0]] = true
      endif
    else
      if len(parts) == 1 || parts[-1] ==# command_type
        role_names[parts[0]] = true
      endif
    endif
  endfor
  var result: list<string> = []
  for name in keys(role_names)
    if name !=# DEFAULT_ROLE_NAME
      add(result, name)
    endif
  endfor
  sort(result)
  return result
enddef
