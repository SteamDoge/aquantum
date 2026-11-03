// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
// Apply the host's non-executable document policy before a section enters an
// iframe. The upstream files stay byte-for-byte pinned to their own revision.
export function protectBook(book) {
  const destroy = book.destroy?.bind(book)
  const urls = new Map()
  for (const section of book.sections) {
    const load = section.load?.bind(section)
    const unload = section.unload?.bind(section)
    let currentSource
    section.load = async () => {
      const original = await load()
      const src = typeof original === 'string' ? original : original?.src
      if (!src?.startsWith('blob:')) throw new Error('正文必须来自受管副本')
      if (!urls.has(src)) {
        const response = await fetch(src)
        if (!response.ok) throw new Error('正文片段无法读取')
        const text = await response.text()
        let mime = response.headers.get('content-type')?.split(';')[0].trim() === 'application/xhtml+xml'
          ? 'application/xhtml+xml' : 'text/html'
        let doc = new DOMParser().parseFromString(text, mime)
        if (mime !== 'text/html' && doc.querySelector('parsererror')) {
          mime = 'text/html'
          doc = new DOMParser().parseFromString(text, mime)
        }
        doc.querySelectorAll('script, iframe, object, embed, base, meta[http-equiv]').forEach(el => el.remove())
        for (const element of doc.querySelectorAll('*')) {
          for (const attribute of [...element.attributes]) {
            if (/^on/i.test(attribute.name) ||
                (/^(href|src|action|xlink:href)$/i.test(attribute.name) && /^\s*javascript:/i.test(attribute.value))) {
              element.removeAttribute(attribute.name)
            }
          }
        }
        const policy = doc.createElementNS('http://www.w3.org/1999/xhtml', 'meta')
        policy.setAttribute('http-equiv', 'Content-Security-Policy')
        policy.setAttribute('content', "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' blob:; img-src blob: data:; font-src blob: data:; media-src blob: data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'")
        let head = doc.querySelector('head')
        if (!head) {
          head = doc.createElementNS('http://www.w3.org/1999/xhtml', 'head')
          doc.documentElement.prepend(head)
        }
        head.prepend(policy)
        const serialized = mime === 'text/html' ? '<!DOCTYPE html>' + doc.documentElement.outerHTML
          : new XMLSerializer().serializeToString(doc)
        urls.set(src, URL.createObjectURL(new Blob([serialized], { type: mime })))
      }
      while (urls.size > 8) {
        const oldest = urls.keys().next().value
        URL.revokeObjectURL(urls.get(oldest))
        urls.delete(oldest)
      }
      currentSource = src
      const safe = urls.get(src)
      return typeof original === 'string' ? safe : { ...original, src: safe }
    }
    section.unload = () => {
      // The original URL belongs to this section. Release only this wrapper's
      // derived bytes; the upstream loader retains its own resource policy.
      if (currentSource) { URL.revokeObjectURL(urls.get(currentSource)); urls.delete(currentSource); currentSource = null }
      unload?.()
    }
  }
  book.destroy = () => {
    for (const url of urls.values()) URL.revokeObjectURL(url)
    urls.clear()
    destroy?.()
  }
  return book
}
