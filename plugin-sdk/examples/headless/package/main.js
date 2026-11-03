// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
export async function activate(ctx) {
  let changes = 0;
  await ctx.services.provide('example.headless.count', '1.0.0', () => changes);
  await ctx.events.on('theme.changed', () => { changes++; });
  await ctx.slots.register({id:'status',name:'插件运行状态',type:'readerMore',icon:'info'}, () => `无页面 JavaScript 插件正在运行，主题事件 ${changes} 次`);
  ctx.onDispose(() => { changes = 0; });
}
