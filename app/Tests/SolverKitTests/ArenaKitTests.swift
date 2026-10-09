@testable import ArenaKit
import LLMKit
import SolverKit
import XCTest

final class ArenaKitTests: XCTestCase {
    func cards(_ s: String) -> [Card] { Card.parseList(s)! }

    func hand(_ sb: String = "AsAh", _ bb: String = "KdKc", runout: String = "2c7d9hJs3s", stacks: [Int] = [10_000, 10_000]) -> HandState {
        HandState(config: HandConfig(stacks: stacks), hole: [cards(sb), cards(bb)], runout: cards(runout))
    }

    // MARK: Engine

    func testBlindsAndFirstAction() throws {
        let s = hand()
        XCTAssertEqual(s.pot, 150)
        XCTAssertEqual(s.stacks, [9950, 9900])
        XCTAssertEqual(s.toAct, 0, "button / small blind acts first preflop")
        let l = try XCTUnwrap(s.legalActions())
        XCTAssertEqual(l.toCall, 50)
        XCTAssertTrue(l.canFold)
        XCTAssertFalse(l.canCheck)
        XCTAssertEqual(l.minTo, 200)
        XCTAssertEqual(l.maxTo, 10_000)
    }

    func testMinRaiseRules() throws {
        var s = hand()
        XCTAssertFalse(s.isLegal(.raise(199)))
        try s.apply(.raise(250))
        XCTAssertEqual(s.toAct, 1)
        XCTAssertEqual(s.legalActions()?.minTo, 400, "min re-raise = 250 + increment 150")
        XCTAssertFalse(s.isLegal(.raise(399)))
        XCTAssertThrowsError(try s.apply(.raise(399)))
        try s.apply(.raise(700)) // increment 450
        XCTAssertEqual(s.legalActions()?.minTo, 1150)
        try s.apply(.call)
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.pot, 1400)
        XCTAssertEqual(s.toAct, 1, "big blind acts first postflop")
        XCTAssertEqual(s.legalActions()?.minTo, 100, "minimum bet is one big blind")
        try s.apply(.bet(300))
        XCTAssertEqual(s.legalActions()?.minTo, 600)
        XCTAssertThrowsError(try s.apply(.check))
    }

    func testLimpOptionAndPostflopOrder() throws {
        var s = hand()
        try s.apply(.call)
        XCTAssertEqual(s.street, .preflop)
        XCTAssertEqual(s.toAct, 1, "big blind gets the option")
        XCTAssertTrue(s.legalActions()!.canCheck)
        try s.apply(.check)
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.board.count, 3)
        XCTAssertEqual(s.toAct, 1)
        try s.apply(.check)
        XCTAssertEqual(s.toAct, 0)
        try s.apply(.check)
        XCTAssertEqual(s.street, .turn)
        try s.apply(.check); try s.apply(.check)
        try s.apply(.check); try s.apply(.check)
        let r = try XCTUnwrap(s.result)
        XCTAssertTrue(r.showdown)
        XCTAssertEqual(r.winners, [0]) // aces beat kings on 2c7d9hJs3s
        XCTAssertEqual(r.net, [100, -100])
    }

    func testFoldReturnsUncalledAndNets() throws {
        var s = hand()
        try s.apply(.fold)
        let r = try XCTUnwrap(s.result)
        XCTAssertEqual(r.net, [-50, 50])
        XCTAssertEqual(r.uncalledSeat, 1)
        XCTAssertEqual(r.uncalledAmount, 50)
        XCTAssertFalse(r.showdown)

        var t = hand()
        try t.apply(.raise(300))
        try t.apply(.call)
        try t.apply(.bet(450)) // BB bets
        try t.apply(.fold)
        XCTAssertEqual(t.result?.net, [-300, 300])
        XCTAssertEqual(t.result?.uncalledAmount, 450)
        XCTAssertEqual(t.result?.pot, 600)
    }

    func testAllInPreflopRunsOutAndComputesEV() throws {
        var s = hand()
        try s.apply(.raise(10_000))
        XCTAssertTrue(s.legalActions()!.callIsAllIn)
        XCTAssertFalse(s.legalActions()!.canRaise)
        try s.apply(.call)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.board.count, 5)
        XCTAssertEqual(s.allInStreet, .preflop)
        XCTAssertEqual(s.result?.net, [10_000, -10_000])
        s.computeAllInEV { _, _, _ in 0.8 }
        XCTAssertEqual(s.result?.allInEquity?[0] ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.result?.evNet[0] ?? 0, 0.8 * 20_000 - 10_000, accuracy: 1e-6)
        XCTAssertEqual(s.result?.evNet[1] ?? 0, 0.2 * 20_000 - 10_000, accuracy: 1e-6)
        // Real equity from the core: AA vs KK ≈ 82%.
        var t = hand()
        try t.apply(.raise(10_000)); try t.apply(.call)
        t.computeAllInEV(equity: HandState.coreEquity)
        XCTAssertEqual(t.result?.allInEquity?[0] ?? 0, 0.82, accuracy: 0.02)
    }

    func testUnequalStacksUncalledAllIn() throws {
        var s = hand(stacks: [10_000, 5_000])
        try s.apply(.raise(10_000))
        try s.apply(.call) // BB calls all-in for 5000
        let r = try XCTUnwrap(s.result)
        XCTAssertEqual(r.uncalledSeat, 0)
        XCTAssertEqual(r.uncalledAmount, 5_000)
        XCTAssertEqual(r.pot, 10_000)
        XCTAssertEqual(r.net, [5_000, -5_000])
    }

    func testIncompleteAllInRaiseCannotBeReraised() throws {
        var s = hand(stacks: [10_000, 400])
        try s.apply(.raise(300))
        let l = try XCTUnwrap(s.legalActions())
        XCTAssertEqual(l.maxTo, 400)
        XCTAssertEqual(l.minTo, 400, "min raise capped at all-in")
        XCTAssertTrue(s.isLegal(.raise(400)), "all-in for less than a full raise is allowed")
        try s.apply(.raise(400))
        let l2 = try XCTUnwrap(s.legalActions())
        XCTAssertFalse(l2.canRaise, "cannot re-raise an all-in player")
        XCTAssertEqual(l2.toCall, 100)
        try s.apply(.call)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.result?.pot, 800)
    }

    func testSplitPot() throws {
        var s = hand("2c3d", "4h5c", runout: "AsKsQsJsTs")
        try s.apply(.raise(300)); try s.apply(.call)
        for _ in 0..<6 { try s.apply(.check) }
        let r = try XCTUnwrap(s.result)
        XCTAssertEqual(r.winners, [0, 1])
        XCTAssertEqual(r.net, [0, 0])
        XCTAssertEqual(r.categories?[0], "Straight flush")
    }

    func testChipConservation() async throws {
        let m = await MatchRunner.run(config: MatchConfig(deals: 40, seed: 9, concurrency: 3), specs: [.bot(.maniac), .bot(.random)],
                                      players: [ManiacBot(), RandomBot()], save: false)
        XCTAssertEqual(m.hands.count, 80)
        for h in m.hands {
            XCTAssertEqual(h.result.net[0] + h.result.net[1], 0)
            XCTAssertLessThanOrEqual(abs(h.result.net[0]), 10_000)
            XCTAssertEqual(HandReplay.steps(h, names: ["A", "B"]).count, h.actions.count + 1, "replay reproduces every action")
        }
    }

    // MARK: Deck & duplicate

    func testDeterministicDeck() {
        let a = Deck.deal(seed: 7, index: 3), b = Deck.deal(seed: 7, index: 3), c = Deck.deal(seed: 7, index: 4)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set(a.hole.flatMap { $0 } + a.runout).count, 9)
    }

    func testDuplicateSeatSwap() async throws {
        let m = await MatchRunner.run(config: MatchConfig(deals: 6, seed: 2, concurrency: 2), specs: [.bot(.tag), .bot(.station)],
                                      players: [TightAggressiveBot(), CallingStation()], save: false)
        XCTAssertEqual(m.hands.count, 12)
        for d in 0..<6 {
            let pair = m.hands.filter { $0.deal == d }.sorted { $0.replica < $1.replica }
            XCTAssertEqual(pair.count, 2)
            XCTAssertEqual(pair[0].hole, pair[1].hole, "same cards to the same seat")
            XCTAssertEqual(pair[0].runout, pair[1].runout)
            XCTAssertEqual(pair[0].seatPlayers, [0, 1])
            XCTAssertEqual(pair[1].seatPlayers, [1, 0], "players swap seats")
            XCTAssertEqual(pair[0].number, d * 2 + 1)
        }
    }

    func testSelfPlayIsExactlyZero() async throws {
        let m = await MatchRunner.run(config: MatchConfig(deals: 30, seed: 5), specs: [.bot(.tag), .bot(.tag)],
                                      players: [TightAggressiveBot(), TightAggressiveBot()], save: false)
        let s = try XCTUnwrap(m.summary)
        XCTAssertEqual(s.units, 30)
        XCTAssertEqual(s.players[0].netBB, 0, accuracy: 1e-9)
        for u in MatchStats.units(m.hands, player: 0, duplicate: true) { XCTAssertEqual(u.net, 0, accuracy: 1e-9) }
    }

    func testTagBeatsStation() async throws {
        let m = await MatchRunner.run(config: MatchConfig(deals: 60, seed: 11), specs: [.bot(.tag), .bot(.random)],
                                      players: [TightAggressiveBot(), RandomBot()], save: false)
        XCTAssertGreaterThan(m.summary!.players[0].evBB100, 0)
    }

    // MARK: Menu

    func testPreflopMenu() throws {
        let menu = ActionMenu.build(for: hand())
        XCTAssertEqual(menu.map(\.label), ["Fold", "Call 0.5 bb", "Raise to 2.5 bb (2.5x)", "Raise to 3 bb (3x)", "Raise to 4 bb (4x)", "All-in 100 bb"])
        var s = hand()
        try s.apply(.raise(250))
        let m2 = ActionMenu.build(for: s)
        XCTAssertEqual(m2.aggressive.map(\.action.to), [630, 750, 1000, 10_000]) // 6.25 rounds to 6.3
        XCTAssertTrue(m2.allSatisfy { s.isLegal($0.action) })
    }

    func testPostflopMenuFiltersAndDedupes() throws {
        var s = hand()
        try s.apply(.raise(300)); try s.apply(.call) // pot 600
        let menu = ActionMenu.build(for: s)
        XCTAssertEqual(menu.first?.action, .check)
        XCTAssertEqual(menu.aggressive.map(\.action.to), [200, 300, 450, 600, 900, 9_700])
        XCTAssertTrue(menu.allSatisfy { s.isLegal($0.action) })

        // Short stacks: sizes at or above all-in collapse into the all-in option; min-raise bumps duplicates.
        var t = hand(stacks: [1_000, 1_000])
        try t.apply(.raise(300)); try t.apply(.call)
        try t.apply(.bet(200))
        let m2 = ActionMenu.build(for: t)
        let tos = m2.aggressive.map(\.action.to)
        XCTAssertEqual(tos, Array(Set(tos)).sorted())
        XCTAssertEqual(tos.last, 700)
        XCTAssertTrue(m2.allSatisfy { t.isLegal($0.action) })
    }

    // MARK: LLM player

    struct MockChat: ChatProvider {
        let replies: [String]
        let counter = Counter()
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var n = 0
            var prompts: [[ChatMessage]] = []
        }

        func complete(model: String, messages: [ChatMessage], options: ChatOptions) async throws -> LLMReply {
            let i: Int = counter.lock.withLock {
                counter.n += 1
                counter.prompts.append(messages)
                return counter.n - 1
            }
            return LLMReply(content: replies[min(i, replies.count - 1)], usage: ChatUsage(promptTokens: 100, completionTokens: 20, cost: 0.001), latency: 0.5)
        }
    }

    func context(_ s: HandState) -> DecisionContext {
        DecisionContext(state: s, seat: s.toAct!, menu: ActionMenu.build(for: s), handNumber: 1, rngSeed: 1)
    }

    func testParseChoice() {
        XCTAssertEqual(LLMPrompt.parseChoice("I'll raise.\n{\"action\": 3}", optionCount: 6), 3)
        XCTAssertEqual(LLMPrompt.parseChoice("```json\n{\"action\": \"2\"}\n```", optionCount: 6), 2)
        XCTAssertEqual(LLMPrompt.parseChoice("{\"action\": 1} wait no {\"action\": 4}", optionCount: 6), 4)
        XCTAssertEqual(LLMPrompt.parseChoice("action: 5", optionCount: 6), 5)
        XCTAssertEqual(LLMPrompt.parseChoice("4", optionCount: 6), 4)
        XCTAssertNil(LLMPrompt.parseChoice("{\"action\": 9}", optionCount: 6))
        XCTAssertNil(LLMPrompt.parseChoice("I fold", optionCount: 6))
        XCTAssertEqual(LLMPrompt.reasoningSnippet("Strong hand, raise.\n{\"action\": 3}"), "Strong hand, raise.")
    }

    func testLLMPlayerRetryThenSuccess() async throws {
        let chat = MockChat(replies: ["I think raising is good", "{\"action\": 3}"])
        let p = LLMPlayer(model: "test/model", client: chat)
        let ctx = context(hand())
        let d = try await p.decide(ctx)
        XCTAssertEqual(d.action, .raise(250))
        XCTAssertEqual(d.meta?.errors, 1)
        XCTAssertEqual(d.meta?.fallback, false)
        XCTAssertEqual(d.meta?.raw.count, 2)
        XCTAssertEqual(d.meta?.cost ?? 0, 0.002, accuracy: 1e-12)
        XCTAssertEqual(chat.counter.prompts.last?.count, 4, "corrective follow-up appended")
        let prompt = chat.counter.prompts[0][1].content
        XCTAssertTrue(prompt.contains("As Ah"))
        XCTAssertTrue(prompt.contains("1. Fold"))
        XCTAssertTrue(prompt.contains("3. Raise to 2.5 bb (2.5x)"))
        XCTAssertTrue(prompt.contains("BTN/SB"))
    }

    func testLLMPlayerFallsBackToCheckFold() async throws {
        let p = LLMPlayer(model: "test/model", client: MockChat(replies: ["no idea"]))
        let d = try await p.decide(context(hand()))
        XCTAssertEqual(d.action, .fold)
        XCTAssertEqual(d.meta?.fallback, true)
        XCTAssertEqual(d.meta?.errors, 2)

        var s = hand()
        try s.apply(.call)
        let d2 = try await p.decide(context(s))
        XCTAssertEqual(d2.action, .check, "defaults to check when checking is free")
    }

    func testLLMMatchCountsInvalidActions() async throws {
        let bad = LLMPlayer(model: "test/bad", client: MockChat(replies: ["hmm"]))
        let m = await MatchRunner.run(config: MatchConfig(deals: 3, seed: 1), specs: [.llm("test/bad"), .bot(.station)],
                                      players: [bad, CallingStation()], save: false)
        let s = try XCTUnwrap(m.summary)
        XCTAssertEqual(m.status, .completed)
        XCTAssertEqual(s.players[0].invalidActions, s.players[0].decisions)
        XCTAssertGreaterThan(s.players[0].cost, 0)
    }

    func testHistoryPrompt() throws {
        var s = hand()
        try s.apply(.raise(250)); try s.apply(.call); try s.apply(.bet(200))
        let h = LLMPrompt.history(s, seat: 0)
        XCTAssertTrue(h.contains("Preflop: You (BTN/SB) post 0.5, Opponent (BB) posts 1, You raise to 2.5, Opponent calls 1.5."))
        XCTAssertTrue(h.contains("Flop [2c 7d 9h]: Opponent bets 2."))
    }

    // MARK: Specs, stats, leaderboard

    func testPlayerSpecParsing() {
        XCTAssertEqual(PlayerSpec.parse("bot:tag"), .bot(.tag))
        XCTAssertEqual(PlayerSpec.parse("random"), .bot(.random))
        XCTAssertEqual(PlayerSpec.parse("openai/gpt-5@low"), .llm("openai/gpt-5", effort: "low"))
        XCTAssertEqual(PlayerSpec.parse("openai/gpt-5@low")?.id, "openai/gpt-5@low")
        XCTAssertNil(PlayerSpec.parse("bot:nope"))
    }

    func testStatsOnScriptedHand() throws {
        var s = hand()
        try s.apply(.raise(250)); try s.apply(.call) // A (seat 0) opens, B calls
        try s.apply(.check); try s.apply(.bet(200)) // B checks, A c-bets
        try s.apply(.fold)
        let rec = HandRecord(number: 1, deal: 0, replica: 0, seatPlayers: [0, 1], state: s, duration: 0)
        let a = MatchStats.player([rec], player: 0, spec: .bot(.tag), duplicate: false)
        let b = MatchStats.player([rec], player: 1, spec: .bot(.station), duplicate: false)
        XCTAssertEqual(a.vpip, 1); XCTAssertEqual(a.pfr, 1); XCTAssertEqual(a.cbet, 1)
        XCTAssertEqual(b.vpip, 1); XCTAssertEqual(b.pfr, 0); XCTAssertEqual(b.foldToCbet, 1)
        XCTAssertEqual(b.wtsd, 0)
        XCTAssertEqual(a.netBB, 2.5, accuracy: 1e-9)
        let text = HandHistoryFormatter.format(rec, match: MatchRecord(config: .init(), players: [.bot(.tag), .bot(.station)]))
        XCTAssertTrue(text.contains("*** FLOP *** [2c 7d 9h]"))
        XCTAssertTrue(text.contains("Uncalled bet (2) returned to bot:tag"))
    }

    func testRateAndCI() {
        let units = [ResultUnit(deal: 0, hands: 2, net: 2, evNet: 2), ResultUnit(deal: 1, hands: 2, net: -1, evNet: 0)]
        let r = MatchStats.rate(units)
        XCTAssertEqual(r.bb100, 25, accuracy: 1e-9)
        // per-hand rates 100 and -50 → sd 106.07 → se 75 → ci 147
        XCTAssertEqual(r.ci95 ?? 0, 1.96 * 75, accuracy: 1e-6)
        XCTAssertEqual(r.evBB100, 50, accuracy: 1e-9)
    }

    func testBradleyTerry() {
        let even = BradleyTerry.fit(players: 2, results: [PairwiseResult(i: 0, j: 1, score: 5, games: 10)])
        XCTAssertEqual(even[0], even[1], accuracy: 1e-6)
        XCTAssertEqual(even[0], 1500, accuracy: 1e-6)
        let r = BradleyTerry.fit(players: 3, results: [PairwiseResult(i: 0, j: 1, score: 8, games: 10),
                                                       PairwiseResult(i: 1, j: 2, score: 8, games: 10)], prior: 0.01)
        XCTAssertGreaterThan(r[0], r[1])
        XCTAssertGreaterThan(r[1], r[2])
        XCTAssertEqual(BradleyTerry.expected(r[0], r[1]), 0.8, accuracy: 0.05)
        let undefeated = BradleyTerry.fit(players: 2, results: [PairwiseResult(i: 0, j: 1, score: 10, games: 10)])
        XCTAssertTrue(undefeated.allSatisfy(\.isFinite))
    }

    func testLeaderboardAggregates() async throws {
        let m1 = await MatchRunner.run(config: MatchConfig(deals: 20, seed: 1), specs: [.bot(.tag), .bot(.random)],
                                       players: [TightAggressiveBot(), RandomBot()], save: false)
        let m2 = await MatchRunner.run(config: MatchConfig(deals: 20, seed: 2), specs: [.bot(.random), .bot(.tag)],
                                       players: [RandomBot(), TightAggressiveBot()], save: false)
        let self1 = await MatchRunner.run(config: MatchConfig(deals: 5, seed: 3), specs: [.bot(.tag), .bot(.tag)],
                                          players: [TightAggressiveBot(), TightAggressiveBot()], save: false)
        let board = Leaderboard.compute([m1, m2, self1])
        XCTAssertEqual(board.count, 2)
        let tag = board.first { $0.id == "bot:tag" }!, rnd = board.first { $0.id == "bot:random" }!
        XCTAssertEqual(tag.matches, 2, "self-play excluded")
        XCTAssertEqual(tag.units, 40)
        XCTAssertEqual(tag.netBB, -rnd.netBB, accuracy: 1e-9)
        XCTAssertEqual(tag.wins, rnd.losses)
    }
}
