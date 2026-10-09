//! Game tree construction for heads-up postflop no-limit hold'em.

use crate::cards::{card_to_string, Card};
use serde::{Deserialize, Serialize};

pub const OOP: usize = 0;
pub const IP: usize = 1;

pub const STREET_NAMES: [&str; 3] = ["flop", "turn", "river"];

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ActionKind {
    Fold,
    Check,
    Call,
    Bet,
    Raise,
    Allin,
}

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Action {
    pub kind: ActionKind,
    /// Chips added to the pot by this action.
    pub amount: f32,
    /// The actor's total street contribution after the action ("raise to").
    pub to: f32,
    /// Size as a fraction of the pot before the action (bets/raises only).
    pub pot_fraction: f32,
}

impl Action {
    pub fn label(&self) -> String {
        match self.kind {
            ActionKind::Fold => "Fold".into(),
            ActionKind::Check => "Check".into(),
            ActionKind::Call => format!("Call {}", fmt_chips(self.amount)),
            ActionKind::Bet => format!("Bet {}", fmt_chips(self.amount)),
            ActionKind::Raise => format!("Raise to {}", fmt_chips(self.to)),
            ActionKind::Allin => format!("All-in {}", fmt_chips(self.amount)),
        }
    }
}

pub fn fmt_chips(x: f32) -> String {
    if (x - x.round()).abs() < 0.005 {
        format!("{}", x.round() as i64)
    } else {
        format!("{:.2}", x).trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

#[derive(Clone, Copy, Debug)]
pub enum BetSize {
    /// Fraction of the pot (for raises: of the pot after calling).
    Pot(f32),
    AllIn,
}

pub fn parse_sizes(s: &str) -> Result<Vec<BetSize>, String> {
    let mut out = Vec::new();
    for tok in s.split(|c| c == ',' || c == ' ' || c == ';') {
        let t = tok.trim().trim_end_matches('%').to_ascii_lowercase();
        if t.is_empty() {
            continue;
        }
        if t == "a" || t == "allin" || t == "all-in" || t == "ai" {
            out.push(BetSize::AllIn);
            continue;
        }
        let v: f32 = t.parse().map_err(|_| format!("bad bet size '{tok}'"))?;
        if !(v > 0.0) {
            return Err(format!("bet size must be positive: '{tok}'"));
        }
        out.push(BetSize::Pot(v / 100.0));
    }
    Ok(out)
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct SizeSpec {
    #[serde(default)]
    pub bet: String,
    #[serde(default)]
    pub raise: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct StreetSizes {
    #[serde(default)]
    pub oop: SizeSpec,
    #[serde(default)]
    pub ip: SizeSpec,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct BetSizesConfig {
    #[serde(default)]
    pub flop: StreetSizes,
    #[serde(default)]
    pub turn: StreetSizes,
    #[serde(default)]
    pub river: StreetSizes,
}

#[derive(Clone, Debug)]
pub struct TreeConfig {
    pub starting_pot: f32,
    pub effective_stack: f32,
    /// [street][player] -> (bet sizes, raise sizes)
    pub sizes: [[(Vec<BetSize>, Vec<BetSize>); 2]; 3],
    /// A bet that commits at least this fraction of the remaining stack becomes all-in.
    pub allin_threshold: f32,
    pub add_allin: bool,
    pub raise_limit: u32,
}

impl TreeConfig {
    pub fn from_spec(
        starting_pot: f32,
        effective_stack: f32,
        spec: &BetSizesConfig,
        allin_threshold: f32,
        add_allin: bool,
        raise_limit: u32,
    ) -> Result<Self, String> {
        let p = |s: &SizeSpec| -> Result<(Vec<BetSize>, Vec<BetSize>), String> {
            Ok((parse_sizes(&s.bet)?, parse_sizes(&s.raise)?))
        };
        let st = |s: &StreetSizes| -> Result<[(Vec<BetSize>, Vec<BetSize>); 2], String> { Ok([p(&s.oop)?, p(&s.ip)?]) };
        if !(starting_pot > 0.0) {
            return Err("starting pot must be positive".into());
        }
        if !(effective_stack >= 0.0) {
            return Err("effective stack must be non-negative".into());
        }
        Ok(TreeConfig {
            starting_pot,
            effective_stack,
            sizes: [st(&spec.flop)?, st(&spec.turn)?, st(&spec.river)?],
            allin_threshold: allin_threshold.clamp(0.0, 1.0),
            add_allin,
            raise_limit,
        })
    }
}

pub struct ActionNode {
    pub player: usize,
    pub street: u8,
    pub actions: Vec<Action>,
    pub children: Vec<Node>,
    /// Cumulative regrets, layout `[action * n_hands + hand]`.
    pub regrets: Vec<f32>,
    /// Cumulative (reach-weighted) strategy, same layout.
    pub strat_sum: Vec<f32>,
    pub contrib: [f32; 2],
}

pub struct ChanceNode {
    /// Street being dealt (1 = turn, 2 = river).
    pub street: u8,
    pub cards: Vec<Card>,
    pub children: Vec<Node>,
    pub contrib: [f32; 2],
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TerminalKind {
    /// The given player folded.
    Fold(usize),
    Showdown,
}

pub struct TerminalNode {
    pub kind: TerminalKind,
    pub contrib: [f32; 2],
}

pub enum Node {
    Action(Box<ActionNode>),
    Chance(Box<ChanceNode>),
    Terminal(TerminalNode),
}

impl Node {
    pub fn contrib(&self) -> [f32; 2] {
        match self {
            Node::Action(a) => a.contrib,
            Node::Chance(c) => c.contrib,
            Node::Terminal(t) => t.contrib,
        }
    }
}

#[derive(Clone, Copy, Default, Debug, Serialize)]
pub struct TreeStats {
    pub action_nodes: u64,
    pub chance_nodes: u64,
    pub terminal_nodes: u64,
    /// Number of f32 slots needed (regrets + strategy sums).
    pub floats: u64,
}

#[derive(Clone)]
struct State {
    street: u8,
    board: Vec<Card>,
    contrib: [f32; 2],
    /// Contributions at the start of the current street.
    street_base: [f32; 2],
    to_act: usize,
    raises: u32,
}

pub struct TreeBuilder<'a> {
    pub cfg: &'a TreeConfig,
    /// Hands per player, used to size strategy arrays.
    pub n_hands: [usize; 2],
    pub allocate: bool,
    pub stats: TreeStats,
}

const EPS: f32 = 1e-4;

impl<'a> TreeBuilder<'a> {
    pub fn build(&mut self, board: &[Card]) -> Node {
        let street = (board.len() as u8).saturating_sub(3);
        let st = State {
            street,
            board: board.to_vec(),
            contrib: [0.0; 2],
            street_base: [0.0; 2],
            to_act: OOP,
            raises: 0,
        };
        self.action(st)
    }

    fn pot(&self, st: &State) -> f32 {
        self.cfg.starting_pot + st.contrib[0] + st.contrib[1]
    }

    fn legal_actions(&self, st: &State) -> Vec<Action> {
        let p = st.to_act;
        let q = 1 - p;
        let stack = self.cfg.effective_stack;
        let remaining = stack - st.contrib[p];
        let facing = st.contrib[q] - st.contrib[p];
        let pot = self.pot(st);
        let (bets, raises) = &self.cfg.sizes[st.street as usize][p];
        let street_contrib = st.contrib[p] - st.street_base[p];

        let mut out: Vec<Action> = Vec::new();
        let mut push_aggr = |out: &mut Vec<Action>, mut add: f32, raise: bool| {
            if remaining <= EPS {
                return;
            }
            if add >= remaining * self.cfg.allin_threshold || add >= remaining - EPS {
                add = remaining;
            }
            if out.iter().any(|a| (a.amount - add).abs() < 0.01 && matches!(a.kind, ActionKind::Bet | ActionKind::Raise | ActionKind::Allin)) {
                return;
            }
            let kind = if (add - remaining).abs() < EPS {
                ActionKind::Allin
            } else if raise {
                ActionKind::Raise
            } else {
                ActionKind::Bet
            };
            out.push(Action { kind, amount: add, to: street_contrib + add, pot_fraction: (add - facing.max(0.0)) / (pot + facing.max(0.0)) });
        };

        if facing <= EPS {
            out.push(Action { kind: ActionKind::Check, amount: 0.0, to: street_contrib, pot_fraction: 0.0 });
            for b in bets {
                match *b {
                    BetSize::Pot(f) => push_aggr(&mut out, (f * pot).max(1.0_f32.min(remaining)), false),
                    BetSize::AllIn => push_aggr(&mut out, remaining, false),
                }
            }
            if self.cfg.add_allin {
                push_aggr(&mut out, remaining, false);
            }
        } else {
            let call = facing.min(remaining);
            out.push(Action { kind: ActionKind::Fold, amount: 0.0, to: street_contrib, pot_fraction: 0.0 });
            out.push(Action { kind: ActionKind::Call, amount: call, to: street_contrib + call, pot_fraction: 0.0 });
            let opp_remaining = stack - st.contrib[q];
            if st.raises < self.cfg.raise_limit && remaining > facing + EPS && opp_remaining > EPS {
                let min_raise = 2.0 * facing;
                for r in raises {
                    match *r {
                        BetSize::Pot(f) => {
                            let add = facing + f * (pot + facing);
                            push_aggr(&mut out, add.max(min_raise), true)
                        }
                        BetSize::AllIn => push_aggr(&mut out, remaining, true),
                    }
                }
                if self.cfg.add_allin {
                    push_aggr(&mut out, remaining, true);
                }
            }
        }
        // order: passive first, then by size
        out.sort_by(|a, b| {
            let rank = |k: ActionKind| match k {
                ActionKind::Fold => 0,
                ActionKind::Check => 1,
                ActionKind::Call => 2,
                _ => 3,
            };
            rank(a.kind).cmp(&rank(b.kind)).then(a.amount.partial_cmp(&b.amount).unwrap())
        });
        out
    }

    fn action(&mut self, st: State) -> Node {
        let actions = self.legal_actions(&st);
        let p = st.to_act;
        let q = 1 - p;
        let mut children = Vec::with_capacity(actions.len());
        for a in &actions {
            let child = match a.kind {
                ActionKind::Fold => {
                    self.stats.terminal_nodes += 1;
                    Node::Terminal(TerminalNode { kind: TerminalKind::Fold(p), contrib: st.contrib })
                }
                ActionKind::Check => {
                    if p == OOP {
                        let mut s = st.clone();
                        s.to_act = IP;
                        self.action(s)
                    } else {
                        self.street_end(st.clone())
                    }
                }
                ActionKind::Call => {
                    let mut s = st.clone();
                    s.contrib[p] += a.amount;
                    self.street_end(s)
                }
                ActionKind::Bet | ActionKind::Raise | ActionKind::Allin => {
                    let mut s = st.clone();
                    s.contrib[p] += a.amount;
                    s.to_act = q;
                    if st.contrib[q] > st.contrib[p] + EPS {
                        s.raises += 1;
                    }
                    self.action(s)
                }
            };
            children.push(child);
        }
        self.stats.action_nodes += 1;
        let floats = (actions.len() * self.n_hands[p]) as u64 * 2;
        self.stats.floats += floats;
        let (regrets, strat_sum) = if self.allocate {
            let n = actions.len() * self.n_hands[p];
            (vec![0.0f32; n], vec![0.0f32; n])
        } else {
            (Vec::new(), Vec::new())
        };
        Node::Action(Box::new(ActionNode {
            player: p,
            street: st.street,
            actions,
            children,
            regrets,
            strat_sum,
            contrib: st.contrib,
        }))
    }

    fn street_end(&mut self, st: State) -> Node {
        if st.street >= 2 {
            self.stats.terminal_nodes += 1;
            return Node::Terminal(TerminalNode { kind: TerminalKind::Showdown, contrib: st.contrib });
        }
        let all_in = (self.cfg.effective_stack - st.contrib[0]).abs() < EPS
            || (self.cfg.effective_stack - st.contrib[1]).abs() < EPS;
        let next_street = st.street + 1;
        let cards: Vec<Card> = (0..52u8).filter(|c| !st.board.contains(c)).collect();
        let mut children = Vec::with_capacity(cards.len());
        for &c in &cards {
            let mut s = st.clone();
            s.board.push(c);
            s.street = next_street;
            s.street_base = s.contrib;
            s.to_act = OOP;
            s.raises = 0;
            children.push(if all_in { self.street_end(s) } else { self.action(s) });
        }
        self.stats.chance_nodes += 1;
        Node::Chance(Box::new(ChanceNode { street: next_street, cards, children, contrib: st.contrib }))
    }
}

pub fn cards_label(cards: &[Card]) -> String {
    cards.iter().map(|&c| card_to_string(c)).collect::<Vec<_>>().join(" ")
}
