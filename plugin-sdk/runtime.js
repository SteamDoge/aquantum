// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
// Trusted runtime prelude. No filesystem, network, Node, DOM or native bridge.
(() => {
  'use strict';
  let sequence = 0, outbox = [], plugin;
  const pending = new Map(), callbacks = new Map(), disposers = [];
  const send = value => {
    if (outbox.length >= 128) throw Error('Plugin message queue limit');
    outbox.push(value);
  };
  const call = (method, args = {}) => new Promise((resolve, reject) => {
    if (pending.size >= 64) return reject(Error('Plugin request limit'));
    const id = ++sequence;
    pending.set(id, {resolve, reject});
    send({kind: 'host', id, method, args});
  });
  const callback = fn => {
    if (typeof fn !== 'function' || callbacks.size >= 256) throw Error('Invalid callback');
    const id = `callback.${++sequence}`;
    callbacks.set(id, fn);
    return id;
  };
  const register = (method, definition, fn) => {
    const handler = fn ? callback(fn) : undefined;
    return call(method, {...definition, handler});
  };
  const ctx = Object.freeze({
    navigation: Object.freeze({register: (d, fn) => register('slots.register', {...d, type: 'page'}, fn)}),
    slots: Object.freeze({register: (d, fn) => register('slots.register', d, fn),
      update: (id, ui) => call('slots.update', {id, ui}),
      remove: id => call('slots.remove', {id})}),
    events: Object.freeze({on: (name, fn) => register('events.on', {name}, fn),
      hook: (name, fn, priority = 0) => register('events.hook', {name, priority}, fn),
      emit: (name, data) => call('events.emit', {name, data})}),
    services: Object.freeze({provide: (name, version, fn) => register('services.provide', {name, version}, fn),
      discover: () => call('services.discover'),
      call: (name, args, options = {}) => call('services.call', {name, args, ...options})}),
    storage: Object.freeze({get: key => call('data.get', {key}),
      set: (key, value) => call('data.set', {key, value})}),
    settings: Object.freeze({get: key => call('settings.get', {key}),
      set: (key, value) => call('settings.set', {key, value})}),
    secrets: Object.freeze({get: key => call('secrets.get', {key}), set: (key, value) => call('secrets.set', {key, value}), remove: key => call('secrets.remove', {key})}),
    clipboard: Object.freeze({read: () => call('clipboard.read'), write: text => call('clipboard.write', {text})}),
    files: Object.freeze({list: (path = '') => call('files.list', {path}),
      read: name => call('storage.read', {name}), write: (name, data) => call('storage.write', {name, data}),
      mkdir: name => call('files.mkdir', {name}), remove: name => call('files.remove', {name}),
      rename: (name, target) => call('files.rename', {name, target}),
      download: (url, name) => call('download.save', {url, name}),
      open: name => call('files.open', {name}), import: name => call('library.import', {name})}),
    external: Object.freeze({pick: () => call('external.pick'), export: name => call('files.export', {name})}),
    network: Object.freeze({get: url => call('network.get', {url})}),
    reader: Object.freeze({current: () => call('reader.current')}),
    library: Object.freeze({list: () => call('library.list'), import: name => call('library.import', {name})}),
    statistics: Object.freeze({read: () => call('statistics.read')}),
    ui: Object.freeze({show: message => call('ui.show', {message}),
      theme: () => call('ui.theme'), open: id => call('ui.open', {id})}),
    tasks: Object.freeze({run: (fn, options = {}) => register('tasks.run', options, fn),
      cancel: id => call('tasks.cancel', {id})}),
    logger: Object.freeze({info: message => call('logger.write', {level: 'info', message: String(message)}),
      error: message => call('logger.write', {level: 'error', message: String(message)})}),
    onDispose: fn => { if (typeof fn !== 'function' || disposers.length >= 128) throw Error('Invalid disposer'); disposers.push(fn); },
    call,
  });
  Object.defineProperty(globalThis, '__aqLoaded', {get: () => typeof plugin?.activate === 'function'});
  Object.defineProperty(globalThis, '__aqLoad', {value: value => { plugin = value; }});
  Object.defineProperty(globalThis, '__aqDrain', {value: () => {
    const result = JSON.stringify(outbox); outbox = []; return result;
  }});
  Object.defineProperty(globalThis, '__aqDispatch', {value: encoded => {
    const command = JSON.parse(encoded);
    if (command.kind === 'reply') {
      const entry = pending.get(command.id);
      if (entry) { pending.delete(command.id); command.error ? entry.reject(Error(command.error)) : entry.resolve(command.value); }
      return;
    }
    let fn;
    if (command.kind === 'activate') fn = () => plugin?.activate?.(ctx);
    else if (command.kind === 'deactivate') fn = async () => {
      await plugin?.deactivate?.(ctx);
      for (const dispose of disposers.reverse()) await dispose();
      callbacks.clear(); pending.clear();
    };
    else if (command.kind === 'lifecycle') fn = () => plugin?.[command.name]?.(ctx);
    else fn = () => {
      const handler = callbacks.get(command.handler);
      if (!handler) throw Error('Plugin callback revoked');
      return handler(command.payload, ctx);
    };
    let value;
    try { value = fn(); }
    catch (error) { send({kind: 'result', id: command.id, error: String(error?.stack ?? error).slice(0, 4000)}); return; }
    Promise.resolve(value).then(value => send({kind: 'result', id: command.id, value: value ?? null}),
      error => send({kind: 'result', id: command.id, error: String(error?.stack ?? error).slice(0, 4000)}));
  }});
})();
