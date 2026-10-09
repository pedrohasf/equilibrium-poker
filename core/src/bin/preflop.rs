//! `preflop <stack> [ante] [pushfold]` — solves heads-up preflop and prints frequencies.

use gto_core::preflop::{PreflopConfig, PreflopSolver};
use std::sync::atomic::AtomicBool;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let stack: f32 = a.get(1).and_then(|s| s.parse().ok()).unwrap_or(100.0);
    let ante: f32 = a.get(2).and_then(|s| s.parse().ok()).unwrap_or(0.0);
    let cfg = if a.iter().any(|x| x == "pushfold") {
        PreflopConfig::push_fold(stack, ante)
    } else {
        let mut c: PreflopConfig = serde_json::from_value(serde_json::json!({ "stack": stack, "ante": ante })).unwrap();
        if stack <= 30.0 {
            c.open_sizes = vec![2.0];
            c.threebet = vec![3.0];
        }
        c
    };
    let t = std::time::Instant::now();
    let mut s = PreflopSolver::new(cfg).unwrap();
    let p = s.solve(4000, 2.0, 100, &AtomicBool::new(false), |_| {});
    println!("{} nodes · {} iterations · {:.2} mbb/hand exploitability · {:.2}s", s.nodes, p.iteration, p.exploitability, t.elapsed().as_secs_f64());
    let show = |path: &[usize]| {
        let n = s.query(path).unwrap();
        let pl = n.player.unwrap();
        let hs = &n.players[pl].hands;
        let tot: f32 = hs.iter().map(|h| h.reach).sum();
        print!("{:?} {} to act:", n.history, if pl == 0 { "SB" } else { "BB" });
        for (i, a) in n.actions.iter().enumerate() {
            print!("  {} {:.1}%", a.label, 100.0 * hs.iter().map(|h| h.reach * h.strategy[i]).sum::<f32>() / tot);
        }
        println!();
    };
    show(&[]);
    let root = s.query(&[]).unwrap();
    for (i, a) in root.actions.iter().enumerate() {
        if a.label != "Fold" {
            if let Ok(n) = s.query(&[i]) {
                if n.player.is_some() {
                    show(&[i]);
                }
            }
        }
    }
}
