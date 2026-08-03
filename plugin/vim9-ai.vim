vim9script

#  vim9-ai: AI completion, editing, chat and image generation for Vim.
#  Pure Vim9 script - no Python required. All network traffic goes through curl.

if !has('vim9script')
  echoerr 'vim9-ai requires Vim compiled with Vim9 script support (Vim 9+)'
  finish
endif

if !has('patch-9.0.1669')
  echoerr 'vim9-ai requires Vim 9.0.1669 or newer (for "import autoload" support)'
  finish
endif

if !executable('curl')
  echoerr 'vim9-ai requires the curl executable to be available in PATH'
  finish
endif

import autoload 'vim9_ai.vim'
import autoload 'vim9_ai_provider.vim'

vim9_ai_provider.Register('openai', {
  'autoload': 'vim9_ai_provider_openai',
  'default_options': {
    'chat': 'g:vim9_ai_openai_chat',
    'complete': 'g:vim9_ai_openai_complete',
    'edit': 'g:vim9_ai_openai_edit',
    'image': 'g:vim9_ai_openai_image',
  },
})

command! -range -nargs=? -complete=customlist,vim9_ai#RoleCompletionComplete AI call vim9_ai.AIRun(<range>, <line1>, <line2>, {}, <q-args>)
command! -range -nargs=? -complete=customlist,vim9_ai#RoleCompletionEdit AIEdit call vim9_ai.AIEditRun(<range>, <line1>, <line2>, {}, <q-args>)
command! -range -nargs=? -complete=customlist,vim9_ai#RoleCompletionChat AIChat call vim9_ai.AIChatRun(<range>, <line1>, <line2>, {}, <q-args>)
command! -range -nargs=? -complete=customlist,vim9_ai#RoleCompletionImage AIImage call vim9_ai.AIImageRun(<range>, <line1>, <line2>, {}, <q-args>)
command! -nargs=? AINewChat call vim9_ai.AINewChatDeprecatedRun(<f-args>)
command! AIRedo call vim9_ai.AIRedoRun()
command! AIStopChat call vim9_ai.AIChatStopRun()
command! AIUtilRolesOpen call vim9_ai.AIUtilRolesOpen()
command! AIUtilDebugOn call vim9_ai.AIUtilSetDebug(1)
command! AIUtilDebugOff call vim9_ai.AIUtilSetDebug(0)
