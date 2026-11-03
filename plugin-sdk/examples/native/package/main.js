// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
export async function activate(ctx) {
  let count = await ctx.storage.get('count') ?? 0;
  const ui = () => ({schemaVersion:1,type:'column',children:[{id:'title',type:'text',token:'title',text:'原生插件清单'},{id:'count',type:'text',text:`已完成 ${count} 项`},{id:'increment',type:'button',text:'完成一项',event:'increment'}]});
  await ctx.slots.register({id:'home',name:'原生计数清单',type:'page',icon:'notes',ui:ui()}, async ({event}) => {
    if (event === 'increment') { count++; await ctx.storage.set('count',count); await ctx.slots.update('home',ui()); }
  });
}
