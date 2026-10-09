//! Range parsing in the common PioSolver / TexasSolver text format:
//! `AA,KK:0.5,AKs,AQo:0.25,T9s+,99-66,A5s-A2s,AsKh`.

use crate::cards::{card_from_str, combo_index, combos, rank, rank_from_char, suit, NUM_COMBOS};

/// Weight per combo, indexed by `combo_index`.
pub type RangeWeights = Vec<f32>;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Pair,
    Suited,
    Offsuit,
    Any,
}

fn set_class(w: &mut [f32], hi: u8, lo: u8, kind: Kind, weight: f32) {
    for (i, c) in combos().iter().enumerate() {
        let (r0, r1) = (rank(c[0]), rank(c[1]));
        let (a, b) = if r0 >= r1 { (r0, r1) } else { (r1, r0) };
        if a != hi || b != lo {
            continue;
        }
        let suited = suit(c[0]) == suit(c[1]);
        let ok = match kind {
            Kind::Pair => hi == lo,
            Kind::Suited => suited,
            Kind::Offsuit => !suited,
            Kind::Any => true,
        };
        if ok {
            w[i] = weight;
        }
    }
}

struct Class {
    hi: u8,
    lo: u8,
    kind: Kind,
}

fn parse_class(s: &str) -> Result<Class, String> {
    let ch: Vec<char> = s.chars().collect();
    if ch.len() < 2 || ch.len() > 3 {
        return Err(format!("bad hand class '{s}'"));
    }
    let r0 = rank_from_char(ch[0]).ok_or_else(|| format!("bad rank in '{s}'"))?;
    let r1 = rank_from_char(ch[1]).ok_or_else(|| format!("bad rank in '{s}'"))?;
    let (hi, lo) = if r0 >= r1 { (r0, r1) } else { (r1, r0) };
    let kind = if hi == lo {
        if ch.len() == 3 {
            return Err(format!("pairs cannot be suited/offsuit: '{s}'"));
        }
        Kind::Pair
    } else if ch.len() == 3 {
        match ch[2].to_ascii_lowercase() {
            's' => Kind::Suited,
            'o' => Kind::Offsuit,
            _ => return Err(format!("bad suffix in '{s}'")),
        }
    } else {
        Kind::Any
    };
    Ok(Class { hi, lo, kind })
}

pub fn parse_range(text: &str) -> Result<RangeWeights, String> {
    let mut w = vec![0.0f32; NUM_COMBOS];
    for raw in text.split(|c| c == ',' || c == '\n' || c == ' ') {
        let tok = raw.trim();
        if tok.is_empty() {
            continue;
        }
        let (body, weight) = match tok.split_once(':') {
            Some((b, wt)) => (
                b.trim(),
                wt.trim().parse::<f32>().map_err(|_| format!("bad weight in '{tok}'"))?.clamp(0.0, 1.0),
            ),
            None => (tok, 1.0),
        };

        // Specific combo, e.g. "AsKh".
        if body.len() == 4 && body.chars().nth(1).map_or(false, |c| "cdhsCDHS".contains(c)) {
            let a = card_from_str(&body[0..2])?;
            let b = card_from_str(&body[2..4])?;
            if a == b {
                return Err(format!("bad combo '{body}'"));
            }
            w[combo_index(a, b)] = weight;
            continue;
        }

        if let Some(base) = body.strip_suffix('+') {
            let c = parse_class(base)?;
            if c.kind == Kind::Pair {
                for r in c.hi..13 {
                    set_class(&mut w, r, r, Kind::Pair, weight);
                }
            } else {
                for lo in c.lo..c.hi {
                    set_class(&mut w, c.hi, lo, c.kind, weight);
                }
            }
            continue;
        }

        if let Some((a, b)) = body.split_once('-') {
            let ca = parse_class(a.trim())?;
            let cb = parse_class(b.trim())?;
            if ca.kind == Kind::Pair && cb.kind == Kind::Pair {
                let (lo, hi) = (ca.hi.min(cb.hi), ca.hi.max(cb.hi));
                for r in lo..=hi {
                    set_class(&mut w, r, r, Kind::Pair, weight);
                }
            } else if ca.hi == cb.hi && ca.kind == cb.kind {
                let (lo, hi) = (ca.lo.min(cb.lo), ca.lo.max(cb.lo));
                for k in lo..=hi {
                    set_class(&mut w, ca.hi, k, ca.kind, weight);
                }
            } else {
                return Err(format!("unsupported span '{body}'"));
            }
            continue;
        }

        let c = parse_class(body)?;
        set_class(&mut w, c.hi, c.lo, c.kind, weight);
    }
    Ok(w)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn count(w: &[f32]) -> f32 {
        w.iter().sum()
    }

    #[test]
    fn parse() {
        assert_eq!(count(&parse_range("AA").unwrap()), 6.0);
        assert_eq!(count(&parse_range("AKs").unwrap()), 4.0);
        assert_eq!(count(&parse_range("AKo").unwrap()), 12.0);
        assert_eq!(count(&parse_range("AK").unwrap()), 16.0);
        assert_eq!(count(&parse_range("QQ+").unwrap()), 18.0);
        assert_eq!(count(&parse_range("A2s+").unwrap()), 48.0);
        assert_eq!(count(&parse_range("99-66").unwrap()), 24.0);
        assert_eq!(count(&parse_range("A5s-A2s").unwrap()), 16.0);
        assert_eq!(count(&parse_range("AA:0.5,AsKh").unwrap()), 4.0);
        assert!(parse_range("AAs").is_err());
    }
}
