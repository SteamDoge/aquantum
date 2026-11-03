// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import { pageEffectsSupported } from './page_effects.js'
// Flutter <-> foliate-js bridge.
//
// This module is the only code that talks to the host, and the host is the only
// authority on what may be read: the page never opens a file, a URL or the
// network by itself. The host hands it the managed bytes, and every reply is
// either `{ok:true,result}` or an error.
//
// Wire format (identical in both directions):
//   host -> page : JSON string `{"seq":<n>,"method":"<name>","args":{...}}`
//   page -> host : JSON string `{"seq":<n>,"ok":true|false,...}`
//                 resolve -> {ok:true,result:<value>}
//                 reject  -> {ok:false,error:"<message>"}
//                 notify  -> {event:"<name>",detail:{...}}  (no seq)
import { makeBook } from '../foliate/view.js'
import { protectBook } from './book_security.js'
import { makeManagedComic, imageReply } from './managed_comic.js'

const host = document.getElementById('host')
const notice = document.getElementById('notice')

/** The custom element and the book it currently shows. */
let view
let loaded = null
let documentIndices = new WeakMap()

/** The last preferences the shell sent, kept so a reopen starts styled. */
let lastStyle = {}

/** Bytes travel as base64: a 30 MB book must not become an array literal. */
function fromBase64(text) {
  const raw = atob(text)
  const bytes = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
  return bytes
}

/** @returns {boolean} whether a native bridge accepted the message. */
function post(payload) {
  const text = JSON.stringify(payload)
  if (globalThis.webkit?.messageHandlers?.aqReader) {
    globalThis.webkit.messageHandlers.aqReader.postMessage(text)
    return true
  }
  if (globalThis.chrome?.webview?.postMessage) {
    globalThis.chrome.webview.postMessage(text)
    return true
  }
  if (globalThis.AqNative?.post) {
    globalThis.AqNative.post(text)
    return true
  }
  return false
}

function notify(event, detail) {
  post({ event, detail })
}

function fail(message) {
  notice.textContent = message
  notice.dataset.visible = '1'
}

function clearNotice() {
  notice.dataset.visible = '0'
  notice.textContent = ''
}

/** Bytes -> a File with the original name, because foliate sniffs the suffix. */
function toFile(bytes, name, format) {
  return new File([bytes], name || fallbackName(format), { type: mimetypeOf(format) })
}

function fallbackName(format) {
  const suffix = { Epub: 'epub', Mobi: 'mobi', Azw3: 'azw3', Fb2: 'fb2', Comic: 'cbz' }[format] ?? 'epub'
  return `book.${suffix}`
}

function mimetypeOf(format) {
  if (format === 'Epub') return 'application/epub+zip'
  if (format === 'Fb2') return 'application/x-fictionbook+xml'
  if (format === 'Comic') return 'application/vnd.comicbook+zip'
  return 'application/octet-stream'
}

/** The book's table of contents as a flat outline the Flutter shell renders. */
function outlineOf(book) {
  const rows = []
  const walk = (items, level) => {
    for (const item of items ?? []) {
      if (rows.length >= 2000 || level > 64) return
      const href = item.href
      if (typeof href === 'string' && href) {
        rows.push({ href, title: String(item.label ?? '').trim() || `第 ${rows.length + 1} 节`, level })
        if (rows.length >= 2000) return
      }
      walk(item.subitems, level + 1)
    }
  }
  walk(book.toc, 1)
  return rows
}

function locationOf(detail) {
  // Locations are fixed-size runs of text across the whole book, so the run
  // on screen over the total is the share of the book the reader sees.
  const location = detail?.location
  const viewport = location && Number.isFinite(location.total) && location.total > 0 &&
    Number.isFinite(location.current) && Number.isFinite(location.next)
    ? Math.min(1, Math.max(0, (location.next - location.current + 1) / location.total))
    : null
  return {
    anchor: typeof detail?.cfi === 'string' ? detail.cfi : '',
    fraction: typeof detail?.fraction === 'number' && Number.isFinite(detail.fraction)
      ? Math.min(1, Math.max(0, detail.fraction))
      : null,
    label: typeof detail?.tocItem?.label === 'string' ? detail.tocItem.label : '',
    tocHref: typeof detail?.tocItem?.href === 'string' ? detail.tocItem.href : '',
    section: detail?.section?.current ?? null,
    viewport,
    atStart: typeof view?.renderer?.atStart === 'boolean' ? view.renderer.atStart : null,
    atEnd: typeof view?.renderer?.atEnd === 'boolean' ? view.renderer.atEnd : null,
  }
}

function report(detail) {
  if (!loaded) return
  loaded.current = locationOf(detail)
  notify('relocate', loaded.current)
}

/** `anchor` wins over `fraction`; `null` means "show the beginning". */
function pageStart(anchor, fraction) {
  if (typeof anchor === 'string' && anchor.trim()) return anchor.trim()
  if (typeof fraction === 'number' && Number.isFinite(fraction)) {
    return Math.min(1, Math.max(0, fraction))
  }
  return null
}

/** The CFI under a host-reported point, so a tap navigates like a page turn. */
function cfiAt(x, y) {
  for (const { index, doc, frameElement } of view?.renderer?.getContents?.() ?? []) {
    if (!doc) continue
    const box = frameElement?.getBoundingClientRect?.() ?? { left: 0, top: 0 }
    const left = x - box.left, top = y - box.top
    const range = doc.caretRangeFromPoint?.(left, top)
      ?? (doc.caretPositionFromPoint ? (() => {
        const position = doc.caretPositionFromPoint(left, top)
        if (!position) return null
        const created = doc.createRange()
        created.setStart(position.offsetNode, position.offset)
        created.collapse(true)
        return created
      })() : null)
    if (!range) continue
    const resolvedIndex = Number.isInteger(index) ? index : documentIndices.get(doc)
    if (!Number.isInteger(resolvedIndex)) continue
    const cfi = view.getCFI(resolvedIndex, range)
    if (typeof cfi === 'string' && cfi) return cfi
  }
  return ''
}

const methods = {
  async open({ bytes, name, format, anchor, fraction, images }) {
    clearNotice()
    const file = images ? null : toFile(fromBase64(bytes), name, format)
    if (view) {
      const previous = view.book
      view.close()
      previous?.destroy?.()
      view.remove()
      view = null
    }
    host.replaceChildren()
    view = document.createElement('foliate-view')
    host.append(view)

    view.addEventListener('relocate', event => report(event.detail))
    view.addEventListener('error', event => {
      fail(`无法打开这本书：${event.detail?.message ?? '未知错误'}`)
    })
    // A link inside the book may leave the book. The shell decides, because
    // only it can open a real browser; the page never navigates away.
    view.addEventListener('external-link', event => {
      event.preventDefault()
      notify('external-link', { href: event.detail?.href_ ?? event.detail?.href ?? '' })
    })

    documentIndices = new WeakMap()
    view.addEventListener('load', event => wireInput(event.detail.doc, event.detail.index))
    const book = protectBook(images
      ? makeManagedComic(images, name, notify)
      : await makeBook(file))
    await view.open(book)
    loaded = {
      book,
      title: bookTitle(book),
      outline: outlineOf(book),
      // `pre-paginated` means fixed layout; anything else is reflowable.
      paginated: book.rendition?.layout !== 'pre-paginated',
      vertical: book.dir === 'rtl',
      current: { anchor: '', fraction: 0, label: '', section: 0 },
    }
    wireContinuousMetrics(view)

    const start = pageStart(anchor, fraction)
    applyRendererStyle(lastStyle)
    view.renderer?.setStyles?.(styleSheet(lastStyle, !loaded.paginated))
    await view.init({ lastLocation: typeof start === 'number' ? { fraction: start } : start, showTextStart: start == null })
    // Saved styles are staged before open and applied as each section loads.
    // Repeat for renderers that need the initialized document before styling.
    view.renderer?.setStyles?.(styleSheet(lastStyle, !loaded.paginated))
    if (view.lastLocation) loaded.current = locationOf(view.lastLocation)

    return {
      pageEffects: pageEffectsSupported(),
      title: loaded.title,
      outline: loaded.outline,
      paginated: loaded.paginated,
      vertical: loaded.vertical,
      location: loaded.current,
    }
  },

  async goTo({ anchor, fraction, page }) {
    if (!view) throw new Error('尚未打开文档')
    const start = pageStart(anchor, fraction)
    if (Number.isInteger(page)) await view.goTo(page)
    else if (typeof start === 'string') await view.goTo(start)
    else if (typeof start === 'number') await view.goToFraction(start)
    return { location: loaded.current }
  },

  async point({ x, y }) {
    if (!view) throw new Error('尚未打开文档')
    const anchor = cfiAt(Number(x), Number(y))
    if (anchor) await view.goTo(anchor)
    return { anchor }
  },

  async turn({ delta }) {
    if (!view) throw new Error('尚未打开文档')
    const step = delta < 0 ? -1 : 1
    for (let i = 0; i < Math.min(Math.abs(delta), 8); i++) {
      if (step < 0) await view.prev()
      else await view.next()
    }
    return { location: loaded.current }
  },

  /** The selection's CFI, or the current location when nothing is selected. */
  async anchor() {
    if (!view) throw new Error('尚未打开文档')
    for (const { index, doc } of view.renderer?.getContents?.() ?? []) {
      const selection = doc?.defaultView?.getSelection?.()
      if (!selection || selection.isCollapsed || !selection.rangeCount) continue
      const resolvedIndex = Number.isInteger(index) ? index : documentIndices.get(doc)
      if (!Number.isInteger(resolvedIndex)) continue
      const cfi = view.getCFI(resolvedIndex, selection.getRangeAt(0))
      if (typeof cfi === 'string' && cfi) return { anchor: cfi }
    }
    return { anchor: loaded.current.anchor }
  },

  /**
   * Applies the shell's display preferences to the book's own documents.
   *
   * The engine's stylesheet is written through the renderer's `setStyles`, so
   * it lands in every loaded section and survives a section change. Fixed
   * layout keeps its page canvas, so only the theme reaches it.
   */
  async style(style) {
    lastStyle = { ...style }
    if (!view || !loaded) return {}
    applyRendererStyle(style)
    const styles = styleSheet(style, !loaded.paginated)
    view.renderer?.setStyles?.(styles)
    document.documentElement.dataset.theme = ['dark', 'charcoal', 'navy', 'brown'].includes(style.theme) ? 'dark' : 'light'
    document.documentElement.style.setProperty('--aq-background', backgroundOf(style.theme))
    return {}
  },

  image: imageReply,

  /** Walks the book and answers once, so one request carries the whole list. */
  async search({ query, limit }) {
    if (!view) throw new Error('尚未打开文档')
    const text = String(query ?? '').trim()
    if (!text) return { hits: [] }
    const max = Math.min(Math.max(Number(limit) || 200, 1), 500)
    const hits = []
    view.clearSearch()
    for await (const result of view.search({ query: text, matchWholeWords: false })) {
      if (result === 'done') break
      for (const item of result.subitems ?? []) {
        if (hits.length >= max) break
        notify('search-progress', { progress: result.progress ?? null })
        const excerpt = item.excerpt
        hits.push({
          anchor: item.cfi,
          label: String(result.label ?? ''),
          excerpt: excerpt
            ? `${excerpt.pre ?? ''}${excerpt.match ?? ''}${excerpt.post ?? ''}`.trim()
            : '',
        })
      }
      if (hits.length >= max) break
    }
    return { hits }
  },

  async close() {
    try {
      const book = view?.book
      view?.close?.()
      book?.destroy?.()
      view?.remove()
    } finally {
      view = null
      loaded = null
      host.replaceChildren()
      clearNotice()
    }
    return {}
  },
}

/** The engine owns scrolling and animation; Flutter owns the fixed toolbar. */
function applyRendererStyle(style) {
  const renderer = view?.renderer
  if (!renderer) return
  if (loaded?.paginated) {
    renderer.setAttribute('flow', style.continuous ? 'scrolled' : 'paginated')
    renderer.toggleAttribute('animated', !!style.animation)
    renderer.setAttribute('page-effect', style.turnEffect ?? 'slide')
    renderer.style.filter = ''
    if (Number.isFinite(style.margin)) renderer.setAttribute('margin', `${style.margin}px`)
  } else {
    renderer.setAttribute('zoom', style.fit === 'width' ? 'fit-width' : 'fit-page')
    // The shell owns visible progress chrome; keep fixed-page panning while
    // suppressing the browser's extra scrollbar tracks.
    renderer.style.scrollbarWidth = 'none'
  }
}

/** Scrollbar feedback is frame-paced; precise CFI relocation remains debounced. */
function wireContinuousMetrics(currentView) {
  const renderer = currentView.renderer
  let pending = false
  renderer?.addEventListener('scroll', () => {
    if (pending || !renderer.scrolled) return
    pending = true
    requestAnimationFrame(() => {
      pending = false
      if (view !== currentView || !loaded?.paginated || !renderer.scrolled) return
      const index = renderer.getContents?.()[0]?.index
      const fractions = currentView.getSectionFractions()
      const start = fractions[index], end = fractions[index + 1]
      const length = renderer.viewSize
      if (!Number.isFinite(start) || !Number.isFinite(end) || !(length > 0)) return
      const weight = end - start
      notify('scroll-metrics', {
        fraction: Math.min(1, Math.max(0, start + weight * renderer.start / length)),
        viewport: Math.min(1, Math.max(0, weight * renderer.size / length)),
      })
    })
  })
}

/**
 * Top-to-bottom reading crosses chapters by scrolling. The engine lays out one
 * section at a time, so a scroll that keeps pushing past a section's end (or
 * start) moves on to the next (or previous) one: the reader never has to tap
 * to leave a chapter. Paged reading is untouched.
 */
function wireContinuousCrossing(doc) {
  const renderer = () => view?.renderer
  const scrolled = () => !!loaded?.paginated && !!renderer()?.scrolled
  const atEnd = () => { const r = renderer(); return !!r && r.viewSize - r.end <= 2 }
  const atStart = () => { const r = renderer(); return !!r && r.start <= 1 }
  let push = 0, edgeY = null, crossing = false
  const cross = dir => {
    if (crossing || !view) return
    crossing = true
    push = 0
    edgeY = null
    Promise.resolve(dir > 0 ? view.next() : view.prev())
      .catch(() => {})
      .finally(() => setTimeout(() => { crossing = false }, 350))
  }
  doc.addEventListener('wheel', event => {
    if (!scrolled() || crossing) return
    if (event.deltaY > 0 && atEnd()) {
      push = Math.max(0, push) + event.deltaY
      if (push > 160) cross(1)
    } else if (event.deltaY < 0 && atStart()) {
      push = Math.min(0, push) + event.deltaY
      if (push < -160) cross(-1)
    } else push = 0
  }, { passive: true })
  doc.addEventListener('touchstart', () => { edgeY = null }, { passive: true })
  doc.addEventListener('touchmove', event => {
    if (!scrolled() || crossing) return
    const y = event.touches[0]?.clientY
    if (typeof y !== 'number') return
    const end = atEnd(), start = atStart()
    if (!end && !start) { edgeY = null; return }
    // Measured from where the finger was when the edge was reached, so the
    // scroll that got there does not count as a push past it.
    if (edgeY == null) { edgeY = y; return }
    const pushed = edgeY - y
    if (end && pushed > 90) cross(1)
    else if (start && pushed < -90) cross(-1)
  }, { passive: true })
}

function wireInput(doc, index) {
  if (!doc) return
  if (Number.isInteger(index)) documentIndices.set(doc, index)
  wireContinuousCrossing(doc)
  let down
  doc.addEventListener('pointerdown', event => {
    down = event.isPrimary && event.button === 0
      ? { x: event.clientX, y: event.clientY, time: performance.now() } : null
  })
  doc.addEventListener('pointermove', event => {
    if (down && Math.hypot(event.clientX - down.x, event.clientY - down.y) > 8) down.moved = true
  })
  doc.addEventListener('pointercancel', () => { down = null })
  doc.addEventListener('pointerup', event => {
    const start = down
    down = null
    if (start?.moved && loaded && !loaded.paginated) {
      const dx = event.clientX - start.x, dy = event.clientY - start.y
      if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy) * 1.5 && performance.now() - start.time < 700) {
        notify('surface-turn', { delta: (dx < 0 ? 1 : -1) * (loaded.vertical ? -1 : 1) })
      }
      return
    }
    if (!start || start.moved || performance.now() - start.time > 300 ||
        event.target.closest('a,button,input,select,textarea,summary') ||
        !doc.getSelection()?.isCollapsed) return
    const frame = doc.defaultView.frameElement
    const rect = frame?.getBoundingClientRect()
    const scaleX = rect ? rect.width / frame.clientWidth : 1
    const scaleY = rect ? rect.height / frame.clientHeight : 1
    const x = (rect?.left ?? 0) + event.clientX * scaleX
    const y = (rect?.top ?? 0) + event.clientY * scaleY
    notify('surface-tap', { x: x / innerWidth, y: y / innerHeight })
  })
}

/** The reading surface colour the current theme asks for. */
function backgroundOf(theme) {
  if (theme === 'dark') return '#111111'
  if (theme === 'charcoal') return '#262626'
  if (theme === 'navy') return '#1c2833'
  if (theme === 'brown') return '#382f2a'
  if (theme === 'grey') return '#eeeeee'
  if (theme === 'paper') return '#f1e8ce'
  if (theme === 'blue') return '#dce6ee'
  if (theme === 'green') return '#dbe6d6'
  return '#ffffff'
}
/**
 * The stylesheet injected into every section of a reflowable book.
 *
 * Only values the shell actually sent are emitted, so a missing key leaves the
 * book's own typography alone instead of overwriting it with a guess. A fixed
 * layout book keeps its publisher page, so it only receives the colour.
 */
function styleSheet(style, fixedLayout) {
  const rules = [`html, body { background: ${backgroundOf(style.theme)}; }`]
  if (!fixedLayout) {
    const text = style.theme === 'paper' ? '#3a3327' : ['dark', 'charcoal', 'navy', 'brown'].includes(style.theme) ? '#d7d9dc' : '#1b1c1e'
    rules.push(
      `html, body, p, li, dd, dt, blockquote { color: ${text} !important; }`,
      'body { margin: 0 !important; padding: 0 !important;',
      '  -webkit-text-size-adjust: 100%; text-size-adjust: 100%;',
      '  font-size: var(--aq-font-size) !important;',
      '  line-height: var(--aq-line-height) !important;',
      '  font-family: var(--aq-font) !important; }',
      'p, li, dd, dt, blockquote {',
      '  font-size: var(--aq-font-size) !important;',
      '  line-height: var(--aq-line-height) !important;',
      '  margin-block: 0 var(--aq-paragraph-gap) !important; }',
    )
    if (Number.isFinite(style.fontSize)) {
      rules.push(`html { --aq-font-size: ${style.fontSize}px; }`)
    }
    if (Number.isFinite(style.lineHeight)) {
      rules.push(`html { --aq-line-height: ${style.lineHeight}; }`)
    }
    if (Number.isFinite(style.paragraphGap)) {
      rules.push(`html { --aq-paragraph-gap: ${style.paragraphGap}px; }`)
    }
    rules.push(
      `html { --aq-font: ${style.fontFamily === 'system' ? 'system-ui, sans-serif' : 'Georgia, "Noto Serif", serif'}; }`,
    )
    rules.push(
      `html { --aq-ink: ${text}; }`,
      'a { color: inherit; }',
      'img, svg, video { max-width: 100% !important; height: auto !important; }',
      '::selection { background: rgba(120, 150, 220, .35); }',
    )
  }
  return rules.join('\n')
}

function bookTitle(book) {
  const title = book?.metadata?.title
  if (typeof title === 'string' && title.trim()) return title.trim()
  if (title && typeof title === 'object') {
    const value = title['zh'] ?? Object.values(title)[0]
    if (typeof value === 'string' && value.trim()) return value.trim()
  }
  return ''
}

/** Entry point the host calls with one JSON string. Never throws to the host. */
function receive(text) {
  let message
  try {
    message = typeof text === 'string' ? JSON.parse(text) : text
  } catch {
    return
  }
  if (!message || typeof message !== 'object') return
  const seq = message.seq
  if (seq == null) return
  const handler = methods[message.method]
  if (!handler) {
    post({ seq, ok: false, error: `未知文档操作：${message.method}` })
    return
  }
  handler(message.args ?? {})
    .then(result => post({ seq, ok: true, result: result ?? {} }))
    .catch(error => post({ seq, ok: false, error: String(error?.message ?? error) }))
}

wireInput(document)

// The host may push a request as a script event before this module runs.
globalThis.addEventListener('aq-message', event => receive(event.detail))
// WebView2 postWebMessage arrives on its own bridge, not as a DOM event.
globalThis.chrome?.webview?.addEventListener('message', event => receive(event.data))
globalThis.AqReader = { receive }

// Keep retrying briefly: on Windows the WebView2 bridge exists before this
// module evaluates, while a platform installer may appear a little later.
;(function announce(attempt = 0) {
  if (post({ event: 'ready', detail: {} })) return
  if (attempt < 20) setTimeout(() => announce(attempt + 1), 150)
})()
