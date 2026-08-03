vim9script

#  Provider registry for vim9-ai. Providers are Vim9script autoload scripts
#  that export Request() and RequestImage() functions.

g:vim9_ai_providers = {}

export def Register(name: string, options: dict<any>): void
  g:vim9_ai_providers[name] = options
enddef

export def GetProvider(provider_name: string): dict<any>
  if !has_key(g:vim9_ai_providers, provider_name)
    throw 'Provider not found: ' .. provider_name
  endif
  return g:vim9_ai_providers[provider_name]
enddef

export def ProviderDefaultOptionsVarname(provider_name: string, command_type: string): string
  var provider = GetProvider(provider_name)
  return get(get(provider, 'default_options', {}), command_type, '')
enddef

#  Starts a streaming request. The provider calls callbacks.chunk(dict) for
#  each response chunk, callbacks.done() on success and callbacks.error(msg)
#  on failure. Returns the underlying curl job.
export def ProviderRequest(provider_name: string, command_type: string,
      raw_options: dict<any>, messages: list<any>, callbacks: dict<any>): job
  var provider = GetProvider(provider_name)
  var fn = provider['autoload'] .. '#Request'
  return <job>call(fn, [provider_name, command_type, raw_options, messages, callbacks])
enddef

#  Synchronously requests an image. Returns a list of {b64_data} dictionaries.
export def ProviderRequestImage(provider_name: string, command_type: string,
      raw_options: dict<any>, prompt: string): list<any>
  var provider = GetProvider(provider_name)
  var fn = provider['autoload'] .. '#RequestImage'
  return <list<any>>call(fn, [provider_name, command_type, raw_options, prompt])
enddef
