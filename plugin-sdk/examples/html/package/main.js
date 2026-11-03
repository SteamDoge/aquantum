// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
export async function activate(ctx) {
  await ctx.slots.register({id:'home',name:'HTML文件工具',type:'page',icon:'book',html:'index.html'});
}
