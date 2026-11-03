// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! One QuickJS actor per plugin. Only JSON crosses the boundary; no OS loaders.
use rquickjs::{
    CatchResultExt, Context, Module, Runtime,
    loader::{BuiltinLoader, BuiltinResolver},
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

type Reply = mpsc::SyncSender<Result<Value, String>>;
enum Command {
    Run(Value, Reply),
    Stop,
}
static ACTORS: OnceLock<Mutex<HashMap<u64, mpsc::SyncSender<Command>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
struct ActorRegistration(u64);
impl Drop for ActorRegistration {
    fn drop(&mut self) {
        if let Some(registry) = ACTORS.get()
            && let Ok(mut actors) = registry.lock()
        {
            actors.remove(&self.0);
        }
    }
}
const PRELUDE: &str = include_str!("../../../plugin-sdk/runtime.js");

struct Engine {
    context: Context,
    runtime: Runtime,
    deadline: std::sync::Arc<Mutex<Instant>>,
}
impl Engine {
    fn new(sources: &Value, entry: &str) -> Result<Self, String> {
        let runtime = Runtime::new().map_err(|e| e.to_string())?;
        runtime.set_memory_limit(64 * 1024 * 1024);
        runtime.set_max_stack_size(512 * 1024);
        let deadline = std::sync::Arc::new(Mutex::new(Instant::now() + Duration::from_millis(200)));
        let timer = deadline.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            timer.lock().map_or(true, |d| Instant::now() >= *d)
        })));
        let mut resolver = BuiltinResolver::default();
        let mut loader = BuiltinLoader::default();
        let sources = sources.as_object().ok_or("Missing JS sources")?;
        if sources.len() > 512 || !sources.contains_key(entry) {
            return Err("Invalid JS entry or source count".into());
        }
        for (name, source) in sources {
            if !name.ends_with(".js") && !name.ends_with(".mjs") {
                return Err("Only JS source modules are accepted".into());
            }
            let source = source.as_str().ok_or("Invalid JS source")?;
            resolver.add_module(name.clone());
            loader.add_module(name.clone(), source.as_bytes().to_vec());
        }
        runtime.set_loader(resolver, loader);
        let context = Context::full(&runtime).map_err(|e| e.to_string())?;
        context.with(|ctx| {
            ctx.eval::<(), _>(PRELUDE)
                .catch(&ctx)
                .map_err(|e| e.to_string())?;
            let source = format!(
                "import * as plugin from {}; globalThis.__aqLoad(plugin.default ?? plugin);",
                serde_json::to_string(entry).unwrap()
            );
            Module::evaluate(ctx.clone(), "__host_entry__.mjs", source)
                .catch(&ctx)
                .map_err(|e| e.to_string())?;
            Ok::<(), String>(())
        })?;
        let engine = Self {
            context,
            runtime,
            deadline,
        };
        engine.jobs()?;
        if !engine
            .context
            .with(|ctx| ctx.eval::<bool, _>("__aqLoaded"))
            .map_err(|e| e.to_string())?
        {
            return Err(
                "Plugin module failed to initialize or exports no activate function".into(),
            );
        }
        Ok(engine)
    }
    fn jobs(&self) -> Result<(), String> {
        for _ in 0..2048 {
            if Instant::now() >= *self.deadline.lock().map_err(|_| "Runtime lock")? {
                return Err("Plugin execution time limit exceeded".into());
            }
            match self.runtime.execute_pending_job() {
                Ok(false) => return Ok(()),
                Ok(true) => (),
                Err(e) => return Err(e.to_string()),
            }
        }
        Err("Plugin microtask limit exceeded".into())
    }
    fn run(&self, command: &Value) -> Result<Value, String> {
        *self.deadline.lock().map_err(|_| "Runtime lock")? =
            Instant::now() + Duration::from_millis(100);
        if !command.is_null() {
            let input = serde_json::to_string(&command.to_string()).map_err(|e| e.to_string())?;
            self.context.with(|ctx| {
                ctx.eval::<(), _>(format!("__aqDispatch({input})"))
                    .catch(&ctx)
                    .map_err(|e| e.to_string())
            })?;
        }
        self.jobs()?;
        self.context.with(|ctx| {
            let output = ctx
                .eval::<String, _>("__aqDrain()")
                .catch(&ctx)
                .map_err(|e| e.to_string())?;
            if output.len() > 24 * 1024 * 1024 {
                return Err("Plugin output limit exceeded".into());
            }
            serde_json::from_str(&output).map_err(|e| e.to_string())
        })
    }
}

pub(crate) fn invoke(request: &Value) -> Result<Value, String> {
    let actors = ACTORS.get_or_init(Default::default);
    match request["operation"].as_str().unwrap_or("") {
        "create" => {
            let id = NEXT.fetch_add(1, Ordering::Relaxed);
            let (sender, receiver) = mpsc::sync_channel(8);
            let (ready, status) = mpsc::sync_channel(1);
            let sources = request["sources"].clone();
            let entry = request["entry"]
                .as_str()
                .ok_or("Missing JS entry")?
                .to_owned();
            {
                let mut registry = actors.lock().map_err(|_| "Runtime registry lock")?;
                if registry.len() >= 16 {
                    return Err("At most sixteen active plugins".into());
                }
                registry.insert(id, sender);
            }
            let registration = ActorRegistration(id);
            let spawned = std::thread::Builder::new()
                .name(format!("aq-plugin-{id}"))
                .stack_size(2 * 1024 * 1024)
                .spawn(move || {
                    let _registration = ActorRegistration(id);
                    let engine = match Engine::new(&sources, &entry) {
                        Ok(engine) => {
                            let _ = ready.send(Ok(()));
                            engine
                        }
                        Err(error) => {
                            let _ = ready.send(Err(error));
                            return;
                        }
                    };
                    while let Ok(Command::Run(value, reply)) = receiver.recv() {
                        let result = engine.run(&value);
                        let fatal = result.is_err();
                        if fatal {
                            drop(ActorRegistration(id));
                        }
                        let _ = reply.send(result);
                        if fatal {
                            break;
                        }
                    }
                });
            spawned.map_err(|e| e.to_string())?;
            status
                .recv_timeout(Duration::from_secs(3))
                .map_err(|_| "Runtime initialization timeout")??;
            std::mem::forget(registration);
            Ok(json!({"handle": id}))
        }
        "destroy" => {
            if let Some(sender) = actors
                .lock()
                .map_err(|_| "Runtime registry lock")?
                .remove(&request["handle"].as_u64().ok_or("Invalid runtime handle")?)
            {
                let _ = sender.try_send(Command::Stop);
            }
            Ok(Value::Null)
        }
        "dispatch" => {
            let id = request["handle"].as_u64().ok_or("Invalid runtime handle")?;
            let sender = actors
                .lock()
                .map_err(|_| "Runtime registry lock")?
                .get(&id)
                .cloned()
                .ok_or("Runtime revoked")?;
            let (reply, result) = mpsc::sync_channel(1);
            match sender.try_send(Command::Run(request["command"].clone(), reply)) {
                Ok(()) => {}
                Err(mpsc::TrySendError::Full(_)) => return Err("Runtime queue full".into()),
                Err(mpsc::TrySendError::Disconnected(_)) => {
                    drop(ActorRegistration(id));
                    return Err("Runtime stopped".into());
                }
            }
            result
                .recv_timeout(Duration::from_secs(2))
                .map_err(|_| "Runtime dispatch timeout")?
        }
        _ => Err("Unknown runtime operation".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fatal_actors_release_their_capacity_without_host_destroy() {
        for _ in 0..20 {
            let created = invoke(&json!({"operation":"create", "entry":"main.js",
                "sources":{"main.js":"export function activate(){while(true){}}"}}))
            .unwrap();
            let handle = created["handle"].as_u64().unwrap();
            assert!(
                invoke(&json!({"operation":"dispatch","handle":handle,
                "command":{"kind":"activate","id":1}}))
                .is_err()
            );
            assert!(!ACTORS.get().unwrap().lock().unwrap().contains_key(&handle));
        }
    }
    #[test]
    fn real_js_modules_promises_and_no_ambient_os() {
        let engine = Engine::new(&json!({"main.js":"import {answer} from './helper.js'; export async function activate(ctx) { await ctx.logger.info(String(answer)); return [typeof fetch,typeof require,typeof process,typeof WebAssembly]; }", "helper.js":"export const answer=42;"}), "main.js").unwrap();
        let messages = engine.run(&json!({"kind":"activate","id":1})).unwrap();
        assert_eq!(messages[0]["method"], "logger.write");
        assert_eq!(messages[0]["args"]["message"], "42");
        let result = engine
            .run(&json!({"kind":"reply","id":messages[0]["id"],"value":null}))
            .unwrap();
        assert_eq!(
            result[0]["value"],
            json!(["undefined", "undefined", "undefined", "undefined"])
        );
    }
    #[test]
    fn infinite_loop_is_interrupted() {
        let engine = Engine::new(
            &json!({"main.js":"export function activate(){while(true){}}"}),
            "main.js",
        )
        .unwrap();
        let started = Instant::now();
        assert!(engine.run(&json!({"kind":"activate","id":1})).is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn unknown_import_cannot_load_host_file() {
        assert!(
            Engine::new(
                &json!({"main.js":"import * as os from 'std'; export default os;"}),
                "main.js"
            )
            .is_err()
        );
    }
    #[test]
    fn module_error_and_missing_activate_are_not_success() {
        assert!(
            Engine::new(
                &json!({"main.js":"throw Error('module failed'); export function activate(){}"}),
                "main.js"
            )
            .is_err()
        );
        assert!(Engine::new(&json!({"main.js":"export const version=1;"}), "main.js").is_err());
    }
    #[test]
    fn asynchronous_infinite_loop_is_interrupted() {
        let engine = Engine::new(&json!({"main.js":"export async function activate(){await Promise.resolve(); while(true){}}"}), "main.js").unwrap();
        assert!(engine.run(&json!({"kind":"activate","id":1})).is_err());
    }
}
