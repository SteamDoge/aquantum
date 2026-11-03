// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type Handler = (payload: Json, ctx: PluginContext) => Json | void | Promise<Json | void>;
export interface UiNode {
  schemaVersion?: 1;
  type: 'page' | 'column' | 'row' | 'text' | 'button' | 'card' | 'list' | 'grid' | 'textField' | 'switch' | 'slider' | 'progress' | 'icon' | 'tabs' | 'menu' | 'fileList' | 'error' | 'loading';
  id?: string; text?: string; label?: string; event?: string; value?: Json;
  min?: number; max?: number; columns?: number; token?: 'title'; children?: UiNode[];
}
export interface Slot {
  id: string; name: string;
  type: 'page' | 'settings' | 'dashboard' | 'format' | 'readerMore' | 'readerToolbar' | 'textSelection' | 'fileMenu' | 'projectMenu' | 'search' | 'libraryAction' | 'fileAction';
  icon?: 'extension' | 'book' | 'info' | 'notes' | 'search' | 'translate';
  navigation?: boolean; ui?: UiNode; html?: string;
  pages?: ('home' | 'statistics')[];
  surface?: 'document' | 'text' | 'markdown' | 'fixed_page' | 'image_page';
}
export interface PluginContext {
  call(method: string, args?: Record<string, Json>): Promise<Json>;
  navigation: { register(definition: Omit<Slot, 'type'>, handler?: Handler): Promise<void> };
  slots: { register(definition: Slot, handler?: Handler): Promise<void>; update(id: string, ui: UiNode): Promise<void>; remove(id: string): Promise<void> };
  events: { on(name: string, handler: Handler): Promise<void>; hook(name: string, handler: Handler, priority?: number): Promise<void>; emit(name: string, data: Json): Promise<Json> };
  services: { provide(name: string, version: string, handler: Handler): Promise<void>; discover(): Promise<Json>; call(name: string, args: Json, options?: {version?: string}): Promise<Json> };
  storage: {get(key: string): Promise<Json>; set(key: string, value: Json): Promise<void>};
  settings: PluginContext['storage'];
  secrets: {get(key: string): Promise<string | null>; set(key: string, value: string): Promise<void>; remove(key: string): Promise<void>};
  clipboard: {read(): Promise<string | null>; write(text: string): Promise<void>};
  files: {list(path?: string): Promise<Json>; read(name: string): Promise<string | null>; write(name: string, base64: string): Promise<Json>; mkdir(name: string): Promise<void>; remove(name: string): Promise<void>; rename(name: string, target: string): Promise<void>; download(url: string, name: string): Promise<Json>; open(name: string): Promise<Json>; import(name: string): Promise<Json>};
  external: {pick(): Promise<{name: string; data: string} | null>; export(name: string): Promise<{saved: boolean}>};
  network: {get(url: string): Promise<{data: string; bytes: number}>};
  reader: {current(): Promise<Json>};
  library: {list(): Promise<Json>; import(name: string): Promise<Json>};
  statistics: {read(): Promise<{todayMs:number; yearMs:number; yearBooks:number; completedBooks:number; streak:number; fileCount:number; projectCount:number}>};
  ui: {show(message: string): Promise<void>; theme(): Promise<Json>; open(id: string): Promise<void>};
  tasks: {run(handler: Handler, options?: Record<string, Json>): Promise<string>; cancel(id: string): Promise<void>};
  logger: {info(message: string): Promise<void>; error(message: string): Promise<void>};
  onDispose(disposer: () => void | Promise<void>): void;
}
export interface Plugin {
  activate(ctx: PluginContext): void | Promise<void>;
  deactivate?(ctx: PluginContext): void | Promise<void>;
  suspend?(ctx: PluginContext): void | Promise<void>;
  resume?(ctx: PluginContext): void | Promise<void>;
}
