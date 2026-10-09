//! Command-line driver: `solve <config.json> [iterations] [target%]`.

use gto_core::solver::{GameConfig, Solver};
use std::sync::atomic::AtomicBool;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = args.get(1).expect("usage: solve <config.json> [iterations] [target%]");
    let iters: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(500);
    let target: f32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0.5);
    let cfg: GameConfig = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let t0 = std::time::Instant::now();
    let mut s = Solver::new(&cfg).unwrap_or_else(|e| panic!("{e}"));
    let e = s.estimate.clone();
    println!(
        "tree: {} action / {} chance / {} terminal nodes, hands {:?}, ~{:.2} GB, built in {:.2}s",
        e.stats.action_nodes,
        e.stats.chance_nodes,
        e.stats.terminal_nodes,
        e.hands,
        e.memory_bytes as f64 / 1e9,
        t0.elapsed().as_secs_f64()
    );
    let stop = AtomicBool::new(false);
    let p = s.solve(iters, target, 10, &stop, |p| {
        println!("iter {:>5}  exploitability {:>7.3}% pot  {:>7.2}s", p.iteration, p.exploitability, p.elapsed)
    });
    println!("done: {} iterations, {:.3}% pot, {:.2}s", p.iteration, p.exploitability, p.elapsed);
    let info = s.query(&[]).unwrap();
    for (i, a) in info.actions.iter().enumerate() {
        let v = &info.players[info.player.unwrap()];
        let num: f32 = v.hands.iter().map(|h| h.reach * h.strategy[i]).sum();
        let den: f32 = v.hands.iter().map(|h| h.reach).sum();
        println!("  {:<16} {:>5.1}%", a.label, 100.0 * num / den);
    }
    for p in 0..2 {
        let v = &info.players[p];
        let num: f64 = v.hands.iter().map(|h| (h.ev * h.reach) as f64).sum();
        let eq: f64 = v.hands.iter().map(|h| (h.equity * h.reach) as f64).sum();
        let den: f64 = v.hands.iter().map(|h| h.reach as f64).sum();
        println!("  {}: EV {:.3}  equity {:.2}%", if p == 0 { "OOP" } else { "IP" }, num / den, 100.0 * eq / den);
    }
}
