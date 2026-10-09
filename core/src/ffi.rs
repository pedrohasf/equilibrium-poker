//! C ABI consumed by the Swift app. All structured data crosses the boundary
//! as UTF-8 JSON; every returned `char*` must be released with `gto_string_free`.

use crate::cards::{parse_cards, Card};
use crate::solver::{estimate, GameConfig, Progress, Solver, Step};
use serde_json::{json, Value};
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

pub struct SolverHandle {
    solver: Mutex<Solver>,
    stop: AtomicBool,
}

fn out(v: Value) -> *mut c_char {
    CString::new(v.to_string()).unwrap_or_default().into_raw()
}

fn err(msg: impl Into<String>) -> *mut c_char {
    out(json!({ "ok": false, "error": msg.into() }))
}

unsafe fn input<'a>(s: *const c_char) -> Result<&'a str, String> {
    if s.is_null() {
        return Err("null input".into());
    }
    CStr::from_ptr(s).to_str().map_err(|e| e.to_string())
}

fn guarded(f: impl FnOnce() -> Result<Value, String>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => out(v),
        Ok(Err(e)) => err(e),
        Err(_) => err("internal solver panic"),
    }
}

#[no_mangle]
pub extern "C" fn gto_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

#[no_mangle]
pub extern "C" fn gto_version() -> *mut c_char {
    out(json!({ "ok": true, "version": env!("CARGO_PKG_VERSION") }))
}

/// Builds the tree without allocating strategy storage and reports its size.
#[no_mangle]
pub unsafe extern "C" fn gto_estimate(config_json: *const c_char) -> *mut c_char {
    guarded(|| {
        let cfg: GameConfig = serde_json::from_str(input(config_json)?).map_err(|e| e.to_string())?;
        let (_, _, est) = estimate(&cfg)?;
        Ok(json!({ "ok": true, "estimate": est }))
    })
}

/// Returns null on failure and writes an error JSON into `error_out` (if non-null).
#[no_mangle]
pub unsafe extern "C" fn gto_solver_create(config_json: *const c_char, error_out: *mut *mut c_char) -> *mut SolverHandle {
    let res = catch_unwind(AssertUnwindSafe(|| -> Result<Solver, String> {
        let cfg: GameConfig = serde_json::from_str(input(config_json)?).map_err(|e| e.to_string())?;
        Solver::new(&cfg)
    }));
    match res {
        Ok(Ok(s)) => Box::into_raw(Box::new(SolverHandle { solver: Mutex::new(s), stop: AtomicBool::new(false) })),
        Ok(Err(e)) => {
            if !error_out.is_null() {
                *error_out = err(e);
            }
            std::ptr::null_mut()
        }
        Err(_) => {
            if !error_out.is_null() {
                *error_out = err("internal solver panic");
            }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn gto_solver_free(h: *mut SolverHandle) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

#[no_mangle]
pub unsafe extern "C" fn gto_solver_info(h: *const SolverHandle) -> *mut c_char {
    guarded(|| {
        let h = h.as_ref().ok_or("null solver")?;
        let s = h.solver.lock().map_err(|_| "poisoned")?;
        Ok(json!({ "ok": true, "estimate": s.estimate, "progress": s.progress() }))
    })
}

pub type ProgressCallback = Option<extern "C" fn(ctx: *mut c_void, iteration: u32, exploitability: f32, elapsed: f64)>;

/// Blocks until finished. Safe to call `gto_solver_stop` from another thread.
#[no_mangle]
pub unsafe extern "C" fn gto_solver_solve(
    h: *const SolverHandle,
    max_iterations: u32,
    target_exploitability: f32,
    check_every: u32,
    callback: ProgressCallback,
    ctx: *mut c_void,
) -> *mut c_char {
    guarded(|| {
        let h = h.as_ref().ok_or("null solver")?;
        h.stop.store(false, Ordering::SeqCst);
        let mut s = h.solver.lock().map_err(|_| "poisoned")?;
        let p: Progress = s.solve(max_iterations, target_exploitability, check_every, &h.stop, |p| {
            if let Some(cb) = callback {
                cb(ctx, p.iteration, p.exploitability, p.elapsed);
            }
        });
        Ok(json!({ "ok": true, "progress": p }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn gto_solver_stop(h: *const SolverHandle) {
    if let Some(h) = h.as_ref() {
        h.stop.store(true, Ordering::SeqCst);
    }
}

/// `path_json` is an array mixing action indices (numbers) and dealt cards ("Kh").
#[no_mangle]
pub unsafe extern "C" fn gto_solver_query(h: *const SolverHandle, path_json: *const c_char) -> *mut c_char {
    guarded(|| {
        let h = h.as_ref().ok_or("null solver")?;
        let raw: Vec<Value> = serde_json::from_str(input(path_json)?).map_err(|e| e.to_string())?;
        let mut path = Vec::with_capacity(raw.len());
        for v in raw {
            match v {
                Value::Number(n) => path.push(Step::Action(n.as_u64().ok_or("bad action index")? as usize)),
                Value::String(s) => path.push(Step::Card(crate::cards::card_from_str(&s)?)),
                _ => return Err("bad path element".into()),
            }
        }
        let s = h.solver.lock().map_err(|_| "poisoned")?;
        let info = s.query(&path)?;
        Ok(json!({ "ok": true, "node": info }))
    })
}

/// Parses a range string into 1326 weights (combo index order) plus its combo labels.
#[no_mangle]
pub unsafe extern "C" fn gto_parse_range(range: *const c_char) -> *mut c_char {
    guarded(|| {
        let w = crate::range::parse_range(input(range)?)?;
        Ok(json!({ "ok": true, "weights": w }))
    })
}

/// Evaluates 5-7 card hands: input `{"hands": ["AsKs QhJhTh 2c 3d", ...]}`.
#[no_mangle]
pub unsafe extern "C" fn gto_evaluate(req: *const c_char) -> *mut c_char {
    guarded(|| {
        let v: Value = serde_json::from_str(input(req)?).map_err(|e| e.to_string())?;
        let hands = v["hands"].as_array().ok_or("missing hands")?;
        let mut vals = Vec::new();
        for h in hands {
            let cards: Vec<Card> = parse_cards(h.as_str().ok_or("hand must be a string")?)?;
            if !(5..=7).contains(&cards.len()) {
                return Err("hands must have 5-7 cards".into());
            }
            let e = crate::eval::eval(&cards);
            vals.push(json!({ "value": e, "category": crate::eval::CATEGORY_NAMES[crate::eval::category(e) as usize] }));
        }
        Ok(json!({ "ok": true, "results": vals }))
    })
}

/// Monte-Carlo equity of a hand vs a range: `{"hand":"AsKs","board":"Qh2c3d","range":"QQ+,AK","samples":20000}`.
#[no_mangle]
pub unsafe extern "C" fn gto_equity(req: *const c_char) -> *mut c_char {
    guarded(|| {
        let v: Value = serde_json::from_str(input(req)?).map_err(|e| e.to_string())?;
        let hand = parse_cards(v["hand"].as_str().ok_or("missing hand")?)?;
        let board = parse_cards(v["board"].as_str().unwrap_or(""))?;
        let range = crate::range::parse_range(v["range"].as_str().unwrap_or("random"))
            .or_else(|_| crate::range::parse_range("22+,A2+,K2+,Q2+,J2+,T2+,92+,82+,72+,62+,52+,42+,32"))?;
        let samples = v["samples"].as_u64().unwrap_or(20000) as usize;
        let eq = crate::equity::monte_carlo(&hand, &board, &range, samples)?;
        Ok(json!({ "ok": true, "equity": eq }))
    })
}

// ------------------------------------------------------------------ preflop

pub struct PreflopHandle {
    solver: Mutex<crate::preflop::PreflopSolver>,
    stop: AtomicBool,
}

/// Creates a heads-up preflop solver (see `preflop::PreflopConfig`). Null on failure.
#[no_mangle]
pub unsafe extern "C" fn gto_preflop_create(config_json: *const c_char, error_out: *mut *mut c_char) -> *mut PreflopHandle {
    let res = catch_unwind(AssertUnwindSafe(|| -> Result<crate::preflop::PreflopSolver, String> {
        let cfg: crate::preflop::PreflopConfig = serde_json::from_str(input(config_json)?).map_err(|e| e.to_string())?;
        crate::preflop::PreflopSolver::new(cfg)
    }));
    match res {
        Ok(Ok(s)) => Box::into_raw(Box::new(PreflopHandle { solver: Mutex::new(s), stop: AtomicBool::new(false) })),
        Ok(Err(e)) => {
            if !error_out.is_null() {
                *error_out = err(e);
            }
            std::ptr::null_mut()
        }
        Err(_) => {
            if !error_out.is_null() {
                *error_out = err("internal solver panic");
            }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn gto_preflop_free(h: *mut PreflopHandle) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

/// Exploitability in the progress callback / result is in milli-big-blinds per hand.
#[no_mangle]
pub unsafe extern "C" fn gto_preflop_solve(
    h: *const PreflopHandle,
    max_iterations: u32,
    target_mbb: f32,
    check_every: u32,
    callback: ProgressCallback,
    ctx: *mut c_void,
) -> *mut c_char {
    guarded(|| {
        let h = h.as_ref().ok_or("null solver")?;
        h.stop.store(false, Ordering::SeqCst);
        let mut s = h.solver.lock().map_err(|_| "poisoned")?;
        let p = s.solve(max_iterations, target_mbb, check_every, &h.stop, |p| {
            if let Some(cb) = callback {
                cb(ctx, p.iteration, p.exploitability, p.elapsed);
            }
        });
        Ok(json!({ "ok": true, "progress": p, "nodes": s.nodes }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn gto_preflop_stop(h: *const PreflopHandle) {
    if let Some(h) = h.as_ref() {
        h.stop.store(true, Ordering::SeqCst);
    }
}

/// `path_json`: array of action indices. Returns the same node shape as `gto_solver_query`.
#[no_mangle]
pub unsafe extern "C" fn gto_preflop_query(h: *const PreflopHandle, path_json: *const c_char) -> *mut c_char {
    guarded(|| {
        let h = h.as_ref().ok_or("null solver")?;
        let path: Vec<usize> = serde_json::from_str(input(path_json)?).map_err(|e| e.to_string())?;
        let s = h.solver.lock().map_err(|_| "poisoned")?;
        Ok(json!({ "ok": true, "node": s.query(&path)? }))
    })
}
