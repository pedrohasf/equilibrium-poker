import Foundation

/// Post-hoc players built from existing runs' stored answers — no API calls. Each produces a
/// normal `BenchmarkRun` (kind `.derived`, with `DerivedInfo`) scored like any other run, so the
/// argmax and mixed-strategy metrics apply unchanged.
///
/// * **ensemble** — weighted average of the sources' probability vectors (sources that answered a
///   decision invalidly are skipped for it; all invalid → invalid). Cost/tokens are summed (an
///   ensemble pays for every member), latency is the slowest member's.
/// * **temper** — p^τ renormalised: τ > 1 sharpens towards the argmax, τ < 1 flattens; the argmax,
///   and so the argmax metrics, never change. τ = ∞ is the one-hot argmax.
/// * **guardrail** (hybrid, not a pure model) — when facing a bet and the heuristic equity
///   (`EquityTools`, preflop or action-narrowed villain range) is at least the price plus `margin`,
///   the fold probability is moved to call.
public enum Synth {
    // MARK: Pure math (unit-tested)

    /// Weighted average of probability vectors (each normalised first). nil if nothing is usable.
    public static func average(_ vectors: [[Double]], weights: [Double]? = nil) -> [Double]? {
        let w = weights ?? vectors.map { _ in 1 }
        guard let n = vectors.first?.count, vectors.allSatisfy({ $0.count == n }), w.count == vectors.count else { return nil }
        var acc = [Double](repeating: 0, count: n)
        var total = 0.0
        for (v, wi) in zip(vectors, w) where wi > 0 {
            guard let p = Scoring.normalized(v) else { continue }
            for i in 0..<n { acc[i] += wi * p[i] }
            total += wi
        }
        guard total > 0 else { return nil }
        return acc.map { $0 / total }
    }

    /// p^τ renormalised. τ = .infinity → one-hot on the argmax (ties: first); τ = 0 → uniform over the support.
    public static func temper(_ p: [Double], tau: Double) -> [Double] {
        guard let q = Scoring.normalized(p) else { return p }
        if tau.isInfinite {
            let i = q.indices.max { q[$0] < q[$1] } ?? 0
            return q.indices.map { $0 == i ? 1 : 0 }
        }
        // Work in log space relative to the max to avoid underflow at large τ.
        let mx = q.max() ?? 1
        let r = q.map { $0 > 0 ? Foundation.exp(tau * Foundation.log($0 / mx)) : 0 }
        return Scoring.normalized(r) ?? q
    }

    /// Fold guard: if `equity ≥ potOdds + margin`, move all fold probability to call.
    public static func foldGuard(_ p: [Double], decision d: Decision, equity: Double, margin: Double) -> (p: [Double], fired: Bool) {
        guard d.facingBet, let fold = d.actions.firstIndex(where: { $0.kind == .fold }),
              let call = d.actions.firstIndex(where: { $0.kind == .call }), p.count == d.actions.count,
              equity >= DecisionStateBuilder.potOdds(d) + margin, p[fold] > 0 else { return (p, false) }
        var q = p
        q[call] += q[fold]
        q[fold] = 0
        return (q, true)
    }

    /// Argmax-only sources (bots) become one-hot distributions so derived runs are scored as mixed strategies.
    static func oneHot(_ r: DecisionResult, _ d: Decision?) -> [Double]? {
        guard let d, let c = r.choice, d.actions.indices.contains(c) else { return nil }
        return d.actions.indices.map { $0 == c ? 1 : 0 }
    }

    static func argmax(_ v: [Double]) -> Int { v.indices.max { v[$0] < v[$1] } ?? 0 }

    // MARK: Runs

    static func makeRun(suite: BenchmarkSuite, key: String, name: String, info: DerivedInfo, results: [DecisionResult]) -> BenchmarkRun {
        var run = BenchmarkRun(suiteId: suite.id, model: "derived:\(key)", displayName: name, kind: .derived)
        run.derived = info
        run.results = results
        return run
    }

    static func shortName(_ r: BenchmarkRun) -> String {
        let base = r.kind == .baseline ? r.displayName : String(r.displayName.split(separator: "/").last ?? Substring(r.displayName))
        if let v = r.variantId, r.kind == .decisionModel { return "\(base) [\(v)]" }
        return base
    }

    static func slug(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }.reduce(into: "") { $0.append($1) }
    }

    /// Weighted ensemble of runs (see type docs).
    public static func ensemble(_ runs: [BenchmarkRun], weights: [Double]? = nil, suite: BenchmarkSuite, name: String? = nil) throws -> BenchmarkRun {
        guard runs.count >= 2 else { throw BenchError("An ensemble needs at least two runs") }
        let w = weights ?? runs.map { _ in 1 }
        guard w.count == runs.count else { throw BenchError("--weights must have one weight per run") }
        let maps = runs.map { r in Dictionary(r.results.map { ($0.decisionId, $0) }, uniquingKeysWith: { _, b in b }) }
        var out: [DecisionResult] = []
        for d in suite.decisions {
            let rs = maps.map { $0[d.id] }
            guard rs.allSatisfy({ $0 != nil }) else { continue }
            var vecs: [[Double]] = [], ws: [Double] = []
            for (i, r) in rs.enumerated() {
                guard let r, r.isValid else { continue }
                let p = r.actionProbabilities ?? r.choice.map { c in d.actions.indices.map { $0 == c ? 1.0 : 0 } }
                if let p, p.count == d.actions.count { vecs.append(p); ws.append(w[i]) }
            }
            let all = rs.compactMap { $0 }
            var x = DecisionResult(decisionId: d.id, choice: nil, latency: all.map(\.latency).max() ?? 0,
                                   promptTokens: all.reduce(0) { $0 + $1.promptTokens },
                                   completionTokens: all.reduce(0) { $0 + $1.completionTokens }, cost: all.reduce(0) { $0 + $1.cost })
            if let avg = average(vecs, weights: ws) {
                x.choice = argmax(avg)
                x.actionProbabilities = avg
                x.parts = zip(runs, rs).map { run, r in AnswerPart(id: run.id, choice: r?.choice, probabilities: r?.actionProbabilities) }
            } else {
                x.error = "Every ensemble member answered invalidly"
            }
            out.append(x)
        }
        let names = runs.map(shortName)
        let wText = weights.map { ws in " weights " + ws.map { String(format: "%g", $0) }.joined(separator: ":") } ?? ""
        let label = name ?? "ensemble(\(names.joined(separator: " + ")))\(wText)"
        let info = DerivedInfo(method: "ensemble", sources: runs.map(\.id),
                               parameters: Dictionary(uniqueKeysWithValues: w.enumerated().map { ("w\($0.offset)", $0.element) }),
                               description: "Average of the members' action probabilities\(wText); argmax of the average is the action.")
        return makeRun(suite: suite, key: "ens-" + slug(names.joined(separator: "+") + wText), name: label, info: info, results: out)
    }

    /// p^τ for every answer of `run`.
    public static func temper(_ run: BenchmarkRun, tau: Double, suite: BenchmarkSuite) -> BenchmarkRun {
        let tauText = tau.isInfinite ? "inf" : String(format: "%g", tau)
        let byId = Dictionary(suite.decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let results = run.results.map { r -> DecisionResult in
            var x = r
            if let p = r.actionProbabilities ?? oneHot(r, byId[r.decisionId]) { x.actionProbabilities = temper(p, tau: tau) }
            x.parts = nil
            return x
        }
        let info = DerivedInfo(method: "temper", sources: [run.id], parameters: ["tau": tau.isInfinite ? 1e9 : tau],
                               description: "Probabilities raised to τ = \(tauText) and renormalised (τ > 1 sharpens, < 1 flattens).")
        return makeRun(suite: suite, key: "temper\(tauText)-" + slug(shortName(run)), name: "\(shortName(run)) τ=\(tauText)",
                       info: info, results: results)
    }

    /// Fold guard on `run` (hybrid). `narrowed` picks the action-narrowed equity, else preflop-range equity.
    public static func guardrail(_ run: BenchmarkRun, margin: Double, narrowed: Bool, suite: BenchmarkSuite) -> (BenchmarkRun, fired: Int) {
        let byId = Dictionary(suite.decisions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var fired = 0
        let results = run.results.map { r -> DecisionResult in
            var x = r
            x.actionProbabilities = r.actionProbabilities ?? oneHot(r, byId[r.decisionId])
            guard let d = byId[r.decisionId], r.isValid, d.facingBet, let f = EquityTools.facts(d),
                  let p = x.actionProbabilities else { return x }
            let g = foldGuard(p, decision: d, equity: narrowed ? f.equityNarrowed : f.equityPreflop, margin: margin)
            guard g.fired else { return x }
            x.actionProbabilities = g.p
            if let c = r.choice, d.actions[c].kind == .fold { x.choice = d.actions.firstIndex { $0.kind == .call }; fired += 1 }
            return x
        }
        let which = narrowed ? "narrowed" : "preflop"
        let info = DerivedInfo(method: "guardrail", sources: [run.id], parameters: ["margin": margin, "narrowed": narrowed ? 1 : 0],
                               description: "HYBRID (not a pure model): fold probability moved to call when heuristic equity vs the villain's "
                                   + "\(which) range ≥ price + \(BB.pct(margin)).", hybrid: true)
        let out = makeRun(suite: suite, key: "guard-\(which)\(Int((margin * 100).rounded()))-" + slug(shortName(run)),
                          name: "\(shortName(run)) +foldguard(\(which) +\(BB.pct(margin))) [hybrid]", info: info, results: results)
        return (out, fired)
    }
}
