//! jq's case-insensitive `test` on a literal (the archive search): Oniguruma
//! compares Unicode full case foldings, and a match may not split the folding
//! of one text character ("s" does not match inside "ß", "ss" does).

#[path = "casefold_table.rs"]
mod table;

fn fold(ch: char) -> Option<&'static str> {
    table::FOLDS
        .binary_search_by(|(c, _)| c.cmp(&ch))
        .ok()
        .map(|i| table::FOLDS[i].1)
}

/// The full case folding of `text`.
pub fn folded(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match fold(ch) {
            Some(f) => out.push_str(f),
            None => out.push(ch),
        }
    }
    out
}

/// Whether `text` contains `needle` (already folded) case-insensitively,
/// starting and ending on character boundaries of `text`.
pub fn contains(text: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    let mut haystack = String::with_capacity(text.len());
    // Byte offsets in `haystack` where a character of `text` starts.
    let mut bounds = Vec::with_capacity(text.len() + 1);
    for ch in text.chars() {
        bounds.push(haystack.len());
        match fold(ch) {
            Some(f) => haystack.push_str(f),
            None => haystack.push(ch),
        }
    }
    bounds.push(haystack.len());
    let mut from = 0;
    while let Some(found) = haystack[from..].find(needle) {
        let start = from + found;
        let end = start + needle.len();
        if bounds.binary_search(&start).is_ok() && bounds.binary_search(&end).is_ok() {
            return true;
        }
        from = start + haystack[start..].chars().next().map_or(1, char::len_utf8);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(query: &str, text: &str) -> bool {
        contains(text, &folded(query))
    }

    #[test]
    fn folds_like_oniguruma() {
        for (query, text) in [
            ("école", "ÉCOLE ouverte"),
            ("strasse", "Straße"),
            ("straße", "STRASSE"),
            ("s", "ſ"),
            ("k", "K"),
            ("σ", "Σ"),
            ("ς", "Σ"),
            ("σ", "ς"),
            ("ǆ", "ǅ"),
            ("ﬀ", "ff"),
            ("ff", "ﬀ"),
            ("ß", "ẞ"),
            ("ss", "ß"),
            ("fi", "ﬁ"),
            ("sß", "sss"),
            ("ßs", "sss"),
            ("aßb", "assb"),
            ("FIREFOX DOWN", "Firefox Download"),
        ] {
            assert!(matches(query, text), "{query} in {text}");
        }
        for (query, text) in [
            ("s", "ß"),
            ("sx", "ßx"),
            ("xs", "xß"),
            ("f", "ﬀ"),
            ("ﬀ", "f"),
            ("i", "ﬁ"),
            ("a.b", "axb"),
        ] {
            assert!(!matches(query, text), "{query} not in {text}");
        }
    }
}
