//! Card primitives. A card is `rank * 4 + suit`, rank 0 = deuce .. 12 = ace,
//! suit 0..4 = c, d, h, s. A two-card combo is indexed 0..1326.

pub type Card = u8;

pub const RANK_CHARS: &[u8; 13] = b"23456789TJQKA";
pub const SUIT_CHARS: &[u8; 4] = b"cdhs";
pub const NUM_COMBOS: usize = 1326;

#[inline]
pub fn rank(c: Card) -> u8 {
    c >> 2
}

#[inline]
pub fn suit(c: Card) -> u8 {
    c & 3
}

pub fn rank_from_char(ch: char) -> Option<u8> {
    let up = ch.to_ascii_uppercase() as u8;
    RANK_CHARS.iter().position(|&r| r == up).map(|p| p as u8)
}

pub fn suit_from_char(ch: char) -> Option<u8> {
    let lo = ch.to_ascii_lowercase() as u8;
    SUIT_CHARS.iter().position(|&s| s == lo).map(|p| p as u8)
}

pub fn card_from_str(s: &str) -> Result<Card, String> {
    let mut it = s.chars();
    match (it.next(), it.next(), it.next()) {
        (Some(r), Some(su), None) => {
            let r = rank_from_char(r).ok_or_else(|| format!("bad rank in card '{s}'"))?;
            let su = suit_from_char(su).ok_or_else(|| format!("bad suit in card '{s}'"))?;
            Ok(r * 4 + su)
        }
        _ => Err(format!("bad card '{s}'")),
    }
}

pub fn card_to_string(c: Card) -> String {
    let mut s = String::with_capacity(2);
    s.push(RANK_CHARS[rank(c) as usize] as char);
    s.push(SUIT_CHARS[suit(c) as usize] as char);
    s
}

/// Parses "QsJh2h", "Qs Jh 2h" or "Qs,Jh,2h".
pub fn parse_cards(s: &str) -> Result<Vec<Card>, String> {
    let cleaned: String = s.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if cleaned.len() % 2 != 0 {
        return Err(format!("bad card list '{s}'"));
    }
    let mut out = Vec::with_capacity(cleaned.len() / 2);
    for i in (0..cleaned.len()).step_by(2) {
        let c = card_from_str(&cleaned[i..i + 2])?;
        if out.contains(&c) {
            return Err(format!("duplicate card '{}'", card_to_string(c)));
        }
        out.push(c);
    }
    Ok(out)
}

#[inline]
pub fn combo_index(a: Card, b: Card) -> usize {
    let (lo, hi) = if a < b { (a as usize, b as usize) } else { (b as usize, a as usize) };
    hi * (hi - 1) / 2 + lo
}

/// All 1326 combos in index order; `combos()[combo_index(a, b)] == [min, max]`.
pub fn combos() -> &'static [[Card; 2]; NUM_COMBOS] {
    use std::sync::OnceLock;
    static TABLE: OnceLock<[[Card; 2]; NUM_COMBOS]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut t = [[0u8; 2]; NUM_COMBOS];
        for hi in 1..52u8 {
            for lo in 0..hi {
                t[combo_index(lo, hi)] = [lo, hi];
            }
        }
        t
    })
}

/// Canonical display string, higher card first ("AsKd").
pub fn combo_to_string(c: [Card; 2]) -> String {
    let (a, b) = if c[0] > c[1] { (c[0], c[1]) } else { (c[1], c[0]) };
    card_to_string(a) + &card_to_string(b)
}

#[inline]
pub fn mask_of(cards: &[Card]) -> u64 {
    cards.iter().fold(0u64, |m, &c| m | (1u64 << c))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        for c in 0..52u8 {
            assert_eq!(card_from_str(&card_to_string(c)).unwrap(), c);
        }
        let t = combos();
        for (i, c) in t.iter().enumerate() {
            assert_eq!(combo_index(c[0], c[1]), i);
            assert!(c[0] < c[1]);
        }
        assert_eq!(parse_cards("Qs Jh 2h").unwrap().len(), 3);
        assert!(parse_cards("QsQs").is_err());
    }
}
