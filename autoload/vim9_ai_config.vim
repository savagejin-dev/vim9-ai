vim9script

#  Configuration defaults and deep merging for vim9-ai.
#  This script is loaded lazily via `import autoload`. The top level statements
#  run on first load and (re)initialize the global configuration variables.

var plugin_root = expand('<sfile>:p:h:h')

#  NOTE: selection_boundary and initial_prompt are handled outside of the provider.

var initial_complete_prompt =<< trim END
>>> system

You are a general assistant.
Answer shortly, consisely and only what you are asked.
Do not provide any explanantion or comments if not requested.
If you answer in a code, do not wrap it in markdown code block.
END
var initial_chat_prompt =<< trim END
>>> system

You are a general assistant.
If you attach a code block add syntax type after ``` to enable syntax highlighting.
END

g:vim9_ai_complete_default = {
  'provider': 'openai',
  'prompt': '',
  'options': {
    'selection_boundary': '#####',
    'initial_prompt': initial_complete_prompt,
  },
  'ui': {
    'paste_mode': 1,
  },
}
g:vim9_ai_edit_default = {
  'provider': 'openai',
  'prompt': '',
  'options': {
    'selection_boundary': '#####',
    'initial_prompt': initial_complete_prompt,
  },
  'ui': {
    'paste_mode': 1,
  },
}
g:vim9_ai_chat_default = {
  'provider': 'openai',
  'prompt': '',
  'options': {
    'selection_boundary': '',
    'initial_prompt': initial_chat_prompt,
  },
  'ui': {
    'open_chat_command': 'preset_below',
    'scratch_buffer_keep_open': 0,
    'populate_options': 0,
    'populate_all_options': 0,
    'force_new_chat': 0,
    'paste_mode': 1,
  },
}
g:vim9_ai_image_default = {
  'provider': 'openai',
  'prompt': '',
  'options': {
  },
  'ui': {
    'download_dir': '',
  },
}

#  openai provider options
g:vim9_ai_openai_complete = {
  'model': 'gpt-4o',
  'endpoint_url': 'https://api.openai.com/v1/chat/completions',
  'max_tokens': 0,
  'max_completion_tokens': 0,
  'temperature': 0.1,
  'request_timeout': 20,
  'stream': 1,
  'auth_type': 'bearer',
  'token_file_path': '',
  'token_load_fn': '',
  'selection_boundary': '#####',
  'initial_prompt': initial_complete_prompt,
  'frequency_penalty': '',
  'logit_bias': '',
  'logprobs': '',
  'presence_penalty': '',
  'reasoning_effort': '',
  'seed': '',
  'stop': '',
  'top_logprobs': '',
  'top_p': '',
  'reasoning': '',
}
g:vim9_ai_openai_edit = g:vim9_ai_openai_complete
g:vim9_ai_openai_chat = {
  'model': 'gpt-4o',
  'endpoint_url': 'https://api.openai.com/v1/chat/completions',
  'max_tokens': 0,
  'max_completion_tokens': 0,
  'temperature': 1,
  'request_timeout': 20,
  'stream': 1,
  'auth_type': 'bearer',
  'token_file_path': '',
  'token_load_fn': '',
  'selection_boundary': '',
  'initial_prompt': initial_chat_prompt,
  'frequency_penalty': '',
  'logit_bias': '',
  'logprobs': '',
  'presence_penalty': '',
  'reasoning_effort': '',
  'seed': '',
  'stop': '',
  'top_logprobs': '',
  'top_p': '',
  'reasoning': '',
}
g:vim9_ai_openai_image = {
  'model': 'dall-e-3',
  'endpoint_url': 'https://api.openai.com/v1/images/generations',
  'quality': 'standard',
  'size': '1024x1024',
  'style': 'vivid',
  'request_timeout': 40,
  'auth_type': 'bearer',
  'token_file_path': '',
  'token_load_fn': '',
}

if !exists('g:vim9_ai_open_chat_presets')
  g:vim9_ai_open_chat_presets = {
    'preset_below': 'below new',
    'preset_tab': 'tabnew',
    'preset_right': 'rightbelow :55vnew | setlocal noequalalways | setlocal winfixwidth',
  }
endif

if !exists('g:vim9_ai_chat_markdown')
  g:vim9_ai_chat_markdown = 0
endif

if !exists('g:vim9_ai_debug')
  g:vim9_ai_debug = 0
endif

if !exists('g:vim9_ai_debug_log_file')
  g:vim9_ai_debug_log_file = '/tmp/vim9_ai_debug.log'
endif
if !exists('g:vim9_ai_token_file_path')
  g:vim9_ai_token_file_path = '~/.config/openai.token'
endif
if !exists('g:vim9_ai_token_load_fn')
  g:vim9_ai_token_load_fn = ''
endif
if !exists('g:vim9_ai_roles_config_file')
  g:vim9_ai_roles_config_file = plugin_root .. '/roles-example.ini'
endif
if !exists('g:vim9_ai_async_chat')
  g:vim9_ai_async_chat = 1
endif
if !exists('g:vim9_ai_proxy')
  g:vim9_ai_proxy = ''
endif


export def ExtendDeep(defaults: dict<any>, override: dict<any>): dict<any>
  var result = defaults
  for [key, value] in items(override)
    if type(get(result, key)) == v:t_dict && type(value) == v:t_dict
      ExtendDeep(result[key], value)
    else
      result[key] = value
    endif
  endfor
  return result
enddef

def MakeConfig(config_name: string): void
  var defaults = copy(g:[config_name .. '_default'])
  var override = exists('g:' .. config_name) ? g:[config_name] : {}
  g:[config_name] = ExtendDeep(defaults, override)
enddef

MakeConfig('vim9_ai_chat')
MakeConfig('vim9_ai_complete')
MakeConfig('vim9_ai_image')
MakeConfig('vim9_ai_edit')

export def Init(): void
  # Nothing to do here - calling this function triggers autoloading of this
  # file, which runs the configuration initialization statements above.
enddef
