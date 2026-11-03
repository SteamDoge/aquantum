// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';

String webPluginDocument(String origin, bool dark, String entry) {
  final encoded = jsonEncode(origin).replaceAll('<', r'\u003c');
  return '''<!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src ${Uri.parse(origin).origin}; object-src 'none'; base-uri 'none'; form-action 'none'"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,iframe{margin:0;border:0;width:100%;height:100%;overflow:hidden;color-scheme:${dark ? 'dark' : 'light'}}</style><iframe id="plugin" sandbox="allow-scripts allow-same-origin"></iframe><script>
  const frame=document.getElementById('plugin');
  window.aqReply=value=>frame.contentWindow.postMessage(value,'*');
  addEventListener('message',event=>{if(event.source!==frame.contentWindow||event.origin!==new URL($encoded).origin)return; const value=JSON.stringify(event.data); if(window.chrome?.webview)window.chrome.webview.postMessage(value);else window.AQuantum.postMessage(value);});
  frame.src=$encoded+${jsonEncode(entry)};
  </script>''';
}

const pluginClientScript = r'''
(()=>{
let sequence=0;const pending=new Map();
window.aq={call(method,args={}){return new Promise((resolve,reject)=>{const id=++sequence;const timer=setTimeout(()=>{pending.delete(id);reject(Error('宿主请求超时'));},60000);pending.set(id,{resolve,reject,timer});parent.postMessage({id,method,args},'*');});},encode(text){return btoa(String.fromCharCode(...new TextEncoder().encode(text)));},decode(data){return new TextDecoder().decode(Uint8Array.from(atob(data),c=>c.charCodeAt(0)));}};
addEventListener('DOMContentLoaded',()=>aq.call('runtime.ready').catch(()=>{}),{once:true});
addEventListener('error',event=>aq.call('runtime.error',{message:String(event.message).slice(0,2000)}).catch(()=>{}));
addEventListener('unhandledrejection',event=>aq.call('runtime.error',{message:String(event.reason).slice(0,2000)}).catch(()=>{}));
addEventListener('message',event=>{if(event.source!==parent)return;const value=event.data;if(value?.kind==='theme'){const theme=value.value;document.documentElement.style.colorScheme=theme.brightness==='dark'?'dark':'light';document.documentElement.dataset.aqTheme=theme.brightness;for(const [key,color] of Object.entries(theme.colors??{}))document.documentElement.style.setProperty('--'+key,color);dispatchEvent(new CustomEvent('aq-theme',{detail:theme}));return;}const entry=pending.get(value?.id);if(!entry)return;pending.delete(value.id);clearTimeout(entry.timer);value.error?entry.reject(Error(value.error)):entry.resolve(value.value);});
})();
''';
