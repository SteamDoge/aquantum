// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
/** Browser snapshots retain the actual rendered old/new page, including images. */
export const pageEffectsSupported = () => typeof document.startViewTransition === 'function'
let active
export async function pageEffect(effect, backwards, update) {
  if (!pageEffectsSupported() || !['cover', 'curl'].includes(effect) ||
      matchMedia('(prefers-reduced-motion: reduce)').matches) return update()
  active?.skipTransition()
  document.documentElement.dataset.pageEffect = effect
  document.documentElement.dataset.pageBackwards = String(backwards)
  const transition = document.startViewTransition(update)
  active = transition
  try { await transition.finished }
  finally {
    if (active === transition) {
      active = null
      delete document.documentElement.dataset.pageEffect
      delete document.documentElement.dataset.pageBackwards
    }
  }
}
