vim9script

# Vim9 script smoke tests for vim9-ai.
# Run with:  vim -es -u NONE --cmd 'set rtp^=<repo root>' --cmd 'set loadplugins'
#            -c 'source tests/run_tests.vim' -c 'qall!'
# Exits non-zero when any assertion fails.

import autoload 'vim9_ai_config.vim'
import autoload 'vim9_ai_context.vim'
import autoload 'vim9_ai_roles.vim'
import autoload 'vim9_ai_util.vim'
import autoload 'vim9_ai_provider.vim'

vim9_ai_config.Init()

var results_path = expand('<sfile>:p:h') .. '/results.txt'

# 1. configuration is initialized
assert_equal('openai', get(g:vim9_ai_complete, 'provider', ''))
assert_true(exists('g:vim9_ai_openai_chat'))
assert_true(exists('g:vim9_ai_open_chat_presets'))

# 2. provider registry
vim9_ai_provider.Register('openai', {'autoload': 'vim9_ai_provider_openai', 'default_options': {}})
assert_true(has_key(g:vim9_ai_providers, 'openai'))

# 3. roles: grammar role from roles-example.ini
var grammar = vim9_ai_roles.LoadRoleConfig('grammar')
assert_equal('fix spelling and grammar', get(get(grammar, 'role_default', {}), 'prompt', ''))

# 4. role name completion
var chat_roles = vim9_ai_roles.LoadAiRoleNames('chat')
assert_true(index(chat_roles, 'grammar') != -1)
assert_true(index(chat_roles, 'tab') != -1)
var image_roles = vim9_ai_roles.LoadAiRoleNames('image')
assert_true(index(image_roles, 'hd') != -1)
assert_true(index(image_roles, 'grammar') == -1)

# 5. role ini parsing with dotted keys and continuation lines
var refactor = vim9_ai_roles.LoadRoleConfig('refactor')
var refactor_options = get(get(refactor, 'role_default', {}), 'options', {})
assert_equal('0.4', get(refactor_options, 'temperature', ''))
assert_true(get(get(refactor, 'role_default', {}), 'prompt', '') =~# 'Clean Code expert')
assert_equal('gpt-4', get(get(get(refactor, 'role_complete', {}), 'options', {}), 'model', ''))

# 6. context / prompt building
var ctx = vim9_ai_context.MakeAiContext({
  'config_default': g:vim9_ai_complete,
  'config_extension': {},
  'user_instruction': '/grammar fix this',
  'user_selection': 'hello world',
  'is_selection': true,
  'command_type': 'complete',
})
assert_equal('grammar', join(ctx['roles'], ','))
assert_true(ctx['prompt'] =~# 'fix spelling and grammar')
assert_true(ctx['prompt'] =~# '#####')

# 7. chat message parsing
var msgs = vim9_ai_util.ParseChatMessages(">>> system\n\nYou are helpful\n\n>>> user\n\nhello\n\n<<< assistant\n\nhi there")
assert_equal(3, len(msgs))
assert_equal('system', msgs[0]['role'])
assert_equal('You are helpful', msgs[0]['content'][0]['text'])
assert_equal('user', msgs[1]['role'])
assert_equal('assistant', msgs[2]['role'])

# 8. chat header config parsing
var hdr = vim9_ai_util.ParseChatHeaderConfig(['[chat]', 'provider = openai', 'options.model = gpt-4', '', '>>> user', '', 'hi'])
assert_equal('openai', hdr['provider'])
assert_equal('gpt-4', hdr['options']['model'])

# 9. deprecated [chat-options] syntax raises
var deprecated_raised = false
try
  vim9_ai_util.ParseChatHeaderConfig(['[chat-options]'])
catch
  deprecated_raised = true
endtry
assert_true(deprecated_raised)

# 10. command definitions
var commands = ['AI', 'AIEdit', 'AIChat', 'AIImage', 'AINewChat', 'AIRedo', 'AIStopChat',
      'AIUtilRolesOpen', 'AIUtilDebugOn', 'AIUtilDebugOff']
for cmd in commands
  assert_true(exists(':' .. cmd) == 2, 'command :' .. cmd .. ' is defined')
endfor

# 11. RenderTextChunks inserts text at the cursor
setline(1, ['hello'])
append(1, '')
cursor(2, 1)
vim9_ai_util.RenderTextChunks(['Hello ', 'world'], true)
assert_equal('Hello world', getline(2))

if !empty(v:errors)
  writefile(['FAILED:'] + v:errors, results_path)
  cquit
endif
writefile(['PASSED'], results_path)
