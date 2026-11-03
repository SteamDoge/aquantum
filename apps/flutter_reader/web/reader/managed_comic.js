// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
// The core already unpacked CBZ into managed image pages. Its current page
// order and stable IDs take precedence over the original archive's filenames.
const pending = new Map()
export function imageReply({ id, data, error }) {
  const request = pending.get(id)
  if (!request) return {}
  pending.delete(id)
  clearTimeout(request.timer)
  if (error) request.reject(new Error(error))
  else if (typeof data !== 'string' || !/^data:image\/(png|jpeg|gif|webp);base64,/.test(data)) request.reject(new Error('图片载荷无效'))
  else request.resolve(data)
  return {}
}
export function makeManagedComic(ids, title, notify) {
  if (!ids.length || ids.length > 10000 || new Set(ids).size !== ids.length) throw new Error('漫画页面清单无效')
  const urls = new Map()
  const book = {
    metadata: { title },
    rendition: { layout: 'pre-paginated', spread: 'none' },
    toc: ids.map((id, index) => ({ href: id, label: `第 ${index + 1} 页` })),
    resolveHref: href => {
      const index = ids.indexOf(href)
      if (index < 0) throw new Error('页面不存在')
      return { index }
    },
    splitTOCHref: href => [href, null],
    getTOCFragment: doc => doc.documentElement,
    destroy: () => {
      for (const request of pending.values()) { clearTimeout(request.timer); request.reject(new Error('文档已关闭')) }
      pending.clear()
      for (const url of urls.values()) URL.revokeObjectURL(url)
      urls.clear()
    },
  }
  book.sections = ids.map(id => ({
    id, size: 1,
    load: async () => {
      if (urls.has(id)) return urls.get(id)
      const data = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('图片读取超时')) }, 25000)
        pending.set(id, { resolve, reject, timer })
        notify('image-request', { id })
      })
      const image = new Image()
      image.src = data
      await image.decode()
      const html = `<!DOCTYPE html><html><head><meta name="viewport" content="width=${image.naturalWidth},height=${image.naturalHeight}"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden}img{display:block;width:100%;height:100%;object-fit:contain}</style></head><body><img src="${data}"></body></html>`
      const url = URL.createObjectURL(new Blob([html], { type: 'text/html' }))
      urls.set(id, url)
      while (urls.size > 3) {
        const oldest = urls.keys().next().value
        URL.revokeObjectURL(urls.get(oldest))
        urls.delete(oldest)
      }
      return url
    },
    unload: () => { URL.revokeObjectURL(urls.get(id)); urls.delete(id) },
  }))
  return book
}
