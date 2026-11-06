//! The JSON model the store has always used, so archive bytes do not change.
//!
//! The Bash store read and wrote JSON through jq 1.8 and the 4.5 reader
//! through Python's `json`. Both are reproduced here, not approximated:
//!
//! - numbers keep their literal; jq prints a literal in decNumber's canonical
//!   form (`1.50` stays, `1e2` becomes `1E+2`, `0017` from `tonumber` is `17`),
//!   Python prints ints as written and floats with `repr`;
//! - objects keep their key order, a repeated key keeps its first position and
//!   its last value (jq and Python agree);
//! - jq prints non-ASCII raw and escapes control characters and DEL; Python's
//!   `ensure_ascii` escapes everything outside `' '..='~'`;
//! - jq's total order (null < false < true < numbers < strings < arrays <
//!   objects) for its comparisons and sorts;
//! - invalid UTF-8 in jq input becomes U+FFFD, as jq does; Python input must
//!   be valid UTF-8.
//!
//! Not reproduced: jq's and Python's non-standard `NaN`/`Infinity` literals
//! (rejected as invalid JSON) and lone UTF-16 surrogates (U+FFFD).

use std::cmp::Ordering;
use std::fmt::Write as _;

/// jq's parser stack limit (Python's reader had none; stock rows are flat).
const MAX_DEPTH: usize = 10_000;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Num(Num),
    Str(String),
    Arr(Vec<Value>),
    Obj(Obj),
}

/// A number as its JSON literal (always valid JSON number grammar).
#[derive(Clone, Debug, PartialEq)]
pub struct Num(pub String);

/// An object in insertion order.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Obj(pub Vec<(String, Value)>);

/// A jq runtime error (the program stops for this input).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JqError;

pub type Jq<T> = Result<T, JqError>;

impl Obj {
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    /// Sets `key`: in place when present, else appended (jq and Python).
    pub fn insert(&mut self, key: impl Into<String>, value: Value) {
        let key = key.into();
        match self.0.iter_mut().find(|(k, _)| *k == key) {
            Some(slot) => slot.1 = value,
            None => self.0.push((key, value)),
        }
    }

    pub fn remove(&mut self, key: &str) {
        self.0.retain(|(k, _)| k != key);
    }
}

impl Num {
    pub fn int(value: i128) -> Num {
        Num(value.to_string())
    }

    pub fn f64(&self) -> f64 {
        self.0.parse().unwrap_or(0.0)
    }

    /// Written without a fraction or exponent (a Python `int`).
    pub fn is_int(&self) -> bool {
        !self.0.contains(['.', 'e', 'E'])
    }

    /// jq 1.8: the literal in decNumber's to-scientific-string form.
    pub fn jq(&self) -> String {
        canonical(&self.0)
    }

    /// Python's `json.dumps`: ints as written (`-0` is `0`), floats by `repr`.
    pub fn python(&self) -> String {
        if self.is_int() {
            if self.0 == "-0" {
                "0".into()
            } else {
                self.0.clone()
            }
        } else {
            python_float(self.f64())
        }
    }
}

/// decNumber's canonical text for a numeric literal (sign, digits, optional
/// fraction, optional exponent; a leading `+`, `.5` and `5.` as `tonumber`
/// accepts them). None when it is not a number.
fn split_number(text: &str) -> Option<(bool, String, i64)> {
    let b = text.as_bytes();
    let mut i = 0;
    let negative = match b.first() {
        Some(b'-') => {
            i = 1;
            true
        }
        Some(b'+') => {
            i = 1;
            false
        }
        _ => false,
    };
    let mut digits = String::new();
    let mut fraction = 0i64;
    let mut seen = false;
    while i < b.len() && b[i].is_ascii_digit() {
        digits.push(b[i] as char);
        i += 1;
        seen = true;
    }
    if i < b.len() && b[i] == b'.' {
        i += 1;
        while i < b.len() && b[i].is_ascii_digit() {
            digits.push(b[i] as char);
            fraction += 1;
            i += 1;
            seen = true;
        }
    }
    if !seen {
        return None;
    }
    let mut exponent = 0i64;
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        let mut sign = 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            if b[i] == b'-' {
                sign = -1;
            }
            i += 1;
        }
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            exponent = exponent
                .saturating_mul(10)
                .saturating_add((b[i] - b'0') as i64);
            i += 1;
        }
        if i == start {
            return None;
        }
        exponent *= sign;
    }
    if i != b.len() {
        return None;
    }
    let digits = digits.trim_start_matches('0');
    let digits = if digits.is_empty() {
        "0".to_string()
    } else {
        digits.to_string()
    };
    Some((negative, digits, exponent.saturating_sub(fraction)))
}

fn canonical(text: &str) -> String {
    let Some((negative, c, e)) = split_number(text) else {
        return text.to_string();
    };
    let mut out = String::new();
    if negative {
        out.push('-');
    }
    let adjusted = e + c.len() as i64 - 1;
    if e <= 0 && adjusted >= -6 {
        if e == 0 {
            out.push_str(&c);
        } else {
            let point = -e as usize;
            if c.len() > point {
                out.push_str(&c[..c.len() - point]);
                out.push('.');
                out.push_str(&c[c.len() - point..]);
            } else {
                out.push_str("0.");
                out.extend(std::iter::repeat_n('0', point - c.len()));
                out.push_str(&c);
            }
        }
    } else {
        out.push_str(&c[..1]);
        if c.len() > 1 {
            out.push('.');
            out.push_str(&c[1..]);
        }
        out.push('E');
        out.push(if adjusted >= 0 { '+' } else { '-' });
        let _ = write!(out, "{}", adjusted.unsigned_abs());
    }
    out
}

/// jq's `tonumber` on a string: the canonical literal, or an error.
pub fn tonumber(text: &str) -> Jq<Num> {
    split_number(text).ok_or(JqError)?;
    Ok(Num(canonical(text)))
}

/// Python's `repr(float)` (and `json.dumps` of a float).
pub fn python_float(value: f64) -> String {
    if value.is_nan() {
        return "NaN".into();
    }
    if value.is_infinite() {
        return if value > 0.0 {
            "Infinity".into()
        } else {
            "-Infinity".into()
        };
    }
    // Shortest round-trip digits, as Python's repr uses.
    let sci = format!("{:e}", value.abs());
    let (mantissa, exponent) = sci.split_once('e').unwrap_or((&sci, "0"));
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let exponent: i64 = exponent.parse().unwrap_or(0);
    let point = exponent + 1;
    let mut out = String::new();
    if value.is_sign_negative() {
        out.push('-');
    }
    if -4 < point && point <= 16 {
        if point <= 0 {
            out.push_str("0.");
            out.extend(std::iter::repeat_n('0', (-point) as usize));
            out.push_str(&digits);
        } else if point as usize >= digits.len() {
            out.push_str(&digits);
            out.extend(std::iter::repeat_n('0', point as usize - digits.len()));
            out.push_str(".0");
        } else {
            out.push_str(&digits[..point as usize]);
            out.push('.');
            out.push_str(&digits[point as usize..]);
        }
    } else {
        out.push_str(&digits[..1]);
        if digits.len() > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        let _ = write!(
            out,
            "e{}{:02}",
            if exponent < 0 { '-' } else { '+' },
            exponent.unsigned_abs()
        );
    }
    out
}

// ------------------------------------------------------------------ parsing

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Dialect {
    /// jq: invalid UTF-8 inside strings becomes U+FFFD, a leading BOM is skipped.
    Jq,
    /// Python's `json.loads(bytes)`: the input must be valid UTF-8 (a BOM is skipped).
    Python,
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
    depth: usize,
    dialect: Dialect,
}

fn is_space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | b'\r')
}

impl Parser<'_> {
    fn space(&mut self) {
        while self.i < self.b.len() && is_space(self.b[self.i]) {
            self.i += 1;
        }
    }

    fn value(&mut self) -> Result<Value, ()> {
        self.space();
        let Some(&byte) = self.b.get(self.i) else {
            return Err(());
        };
        match byte {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => self.string().map(Value::Str),
            b't' => self.word("true", Value::Bool(true)),
            b'f' => self.word("false", Value::Bool(false)),
            b'n' => self.word("null", Value::Null),
            b'-' | b'0'..=b'9' => self.number(),
            b'+' | b'.' if self.dialect == Dialect::Jq => self.number(),
            _ => Err(()),
        }
    }

    fn word(&mut self, word: &str, value: Value) -> Result<Value, ()> {
        if !self.b[self.i..].starts_with(word.as_bytes()) {
            return Err(());
        }
        self.i += word.len();
        self.token_end()?;
        Ok(value)
    }

    /// A bare token (literal or number) must not run into another one.
    fn token_end(&self) -> Result<(), ()> {
        match self.b.get(self.i) {
            Some(byte)
                if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+' | b'_') =>
            {
                Err(())
            }
            _ => Ok(()),
        }
    }

    fn number(&mut self) -> Result<Value, ()> {
        let start = self.i;
        let b = self.b;
        let mut i = self.i;
        if self.dialect == Dialect::Jq {
            // jq's lexer: `01`, `1.`, `.5`, `+1` and `1.e5` are numbers too.
            while i < b.len()
                && (b[i].is_ascii_digit() || matches!(b[i], b'+' | b'-' | b'.' | b'e' | b'E'))
            {
                i += 1;
            }
            let text = std::str::from_utf8(&b[start..i]).map_err(|_| ())?;
            split_number(text).ok_or(())?;
            self.i = i;
            self.token_end()?;
            return Ok(Value::Num(Num(text.to_string())));
        }
        if b.get(i) == Some(&b'-') {
            i += 1;
        }
        match b.get(i) {
            Some(b'0') => i += 1,
            Some(b'1'..=b'9') => {
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
            }
            _ => return Err(()),
        }
        if b.get(i) == Some(&b'.') {
            i += 1;
            let digits = i;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            if i == digits {
                return Err(());
            }
        }
        if matches!(b.get(i), Some(b'e' | b'E')) {
            i += 1;
            if matches!(b.get(i), Some(b'+' | b'-')) {
                i += 1;
            }
            let digits = i;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            if i == digits {
                return Err(());
            }
        }
        self.i = i;
        self.token_end()?;
        Ok(Value::Num(Num(
            String::from_utf8_lossy(&b[start..i]).into_owned()
        )))
    }

    fn hex4(&mut self) -> Result<u32, ()> {
        let digits = self.b.get(self.i..self.i + 4).ok_or(())?;
        let text = std::str::from_utf8(digits).map_err(|_| ())?;
        let value = u32::from_str_radix(text, 16).map_err(|_| ())?;
        if !digits.iter().all(u8::is_ascii_hexdigit) {
            return Err(());
        }
        self.i += 4;
        Ok(value)
    }

    fn string(&mut self) -> Result<String, ()> {
        self.i += 1;
        let mut bytes = Vec::new();
        loop {
            let Some(&byte) = self.b.get(self.i) else {
                return Err(());
            };
            self.i += 1;
            match byte {
                b'"' => break,
                b'\\' => {
                    let escape = *self.b.get(self.i).ok_or(())?;
                    self.i += 1;
                    let ch = match escape {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let unit = self.hex4()?;
                            if (0xd800..0xdc00).contains(&unit) {
                                // A high surrogate needs its low half (jq refuses otherwise).
                                if self.b.get(self.i..self.i + 2) != Some(b"\\u") {
                                    return Err(());
                                }
                                self.i += 2;
                                let low = self.hex4()?;
                                if !(0xdc00..0xe000).contains(&low) {
                                    return Err(());
                                }
                                char::from_u32(0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00))
                                    .ok_or(())?
                            } else {
                                char::from_u32(unit).unwrap_or('\u{fffd}')
                            }
                        }
                        _ => return Err(()),
                    };
                    let mut buf = [0u8; 4];
                    bytes.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                0..=0x1f => return Err(()),
                _ => bytes.push(byte),
            }
        }
        Ok(match String::from_utf8(bytes) {
            Ok(text) => text,
            Err(error) => String::from_utf8_lossy(error.as_bytes()).into_owned(),
        })
    }

    /// jq refuses to open a container once its stack (open containers plus
    /// object keys awaiting their value) holds `MAX_DEPTH` entries.
    fn enter(&mut self) -> Result<(), ()> {
        if self.depth >= MAX_DEPTH {
            return Err(());
        }
        self.depth += 1;
        Ok(())
    }

    fn array(&mut self) -> Result<Value, ()> {
        self.enter()?;
        self.i += 1;
        let mut items = Vec::new();
        self.space();
        if self.b.get(self.i) == Some(&b']') {
            self.i += 1;
        } else {
            loop {
                items.push(self.value()?);
                self.space();
                match self.b.get(self.i) {
                    Some(b',') => self.i += 1,
                    Some(b']') => {
                        self.i += 1;
                        break;
                    }
                    _ => return Err(()),
                }
            }
        }
        self.depth -= 1;
        Ok(Value::Arr(items))
    }

    fn object(&mut self) -> Result<Value, ()> {
        self.enter()?;
        self.i += 1;
        let mut object = Obj::default();
        self.space();
        if self.b.get(self.i) == Some(&b'}') {
            self.i += 1;
        } else {
            loop {
                self.space();
                if self.b.get(self.i) != Some(&b'"') {
                    return Err(());
                }
                let key = self.string()?;
                self.space();
                if self.b.get(self.i) != Some(&b':') {
                    return Err(());
                }
                self.i += 1;
                // The key waits on jq's parser stack while its value is read.
                self.depth += 1;
                let value = self.value()?;
                self.depth -= 1;
                object.insert(key, value);
                self.space();
                match self.b.get(self.i) {
                    Some(b',') => self.i += 1,
                    Some(b'}') => {
                        self.i += 1;
                        break;
                    }
                    _ => return Err(()),
                }
            }
        }
        self.depth -= 1;
        Ok(Value::Obj(object))
    }
}

fn start(bytes: &[u8], dialect: Dialect) -> Result<&[u8], ()> {
    if dialect == Dialect::Python && std::str::from_utf8(bytes).is_err() {
        return Err(());
    }
    Ok(bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes))
}

/// Exactly one JSON value (jq's `fromjson`, Python's `json.loads`).
pub fn parse(bytes: &[u8], dialect: Dialect) -> Option<Value> {
    let bytes = start(bytes, dialect).ok()?;
    let mut parser = Parser {
        b: bytes,
        i: 0,
        depth: 0,
        dialect,
    };
    let value = parser.value().ok()?;
    parser.space();
    (parser.i == bytes.len()).then_some(value)
}

/// A stream of JSON values as jq reads its input: every value up to the end,
/// or up to the first parse error (`complete` is then false).
pub fn parse_stream(bytes: &[u8]) -> (Vec<Value>, bool) {
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    let mut parser = Parser {
        b: bytes,
        i: 0,
        depth: 0,
        dialect: Dialect::Jq,
    };
    let mut values = Vec::new();
    loop {
        parser.space();
        if parser.i == bytes.len() {
            return (values, true);
        }
        parser.depth = 0;
        match parser.value() {
            Ok(value) => values.push(value),
            Err(()) => return (values, false),
        }
    }
}

// ----------------------------------------------------------------- printing

fn jq_string(text: &str, out: &mut String) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn jq_into(value: &Value, out: &mut String, indent: Option<usize>) {
    let newline = |out: &mut String, level: usize| {
        out.push('\n');
        out.extend(std::iter::repeat_n(' ', level * 2));
    };
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Num(n) => out.push_str(&n.jq()),
        Value::Str(s) => jq_string(s, out),
        Value::Arr(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                if let Some(level) = indent {
                    newline(out, level + 1);
                }
                jq_into(item, out, indent.map(|l| l + 1));
            }
            if let (Some(level), false) = (indent, items.is_empty()) {
                newline(out, level);
            }
            out.push(']');
        }
        Value::Obj(object) => {
            out.push('{');
            for (i, (key, item)) in object.0.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                if let Some(level) = indent {
                    newline(out, level + 1);
                }
                jq_string(key, out);
                out.push(':');
                if indent.is_some() {
                    out.push(' ');
                }
                jq_into(item, out, indent.map(|l| l + 1));
            }
            if let (Some(level), false) = (indent, object.0.is_empty()) {
                newline(out, level);
            }
            out.push('}');
        }
    }
}

/// `jq -c` output of one value (without the newline).
pub fn jq(value: &Value) -> String {
    let mut out = String::new();
    jq_into(value, &mut out, None);
    out
}

/// A string as a JSON string literal, as jq prints it.
pub fn jq_str(text: &str) -> String {
    let mut out = String::new();
    jq_string(text, &mut out);
    out
}

/// `jq -r` output of one value (without the newline): strings raw, the rest
/// pretty-printed with two-space indentation.
pub fn jq_raw(value: &Value) -> String {
    match value {
        Value::Str(s) => s.clone(),
        other => {
            let mut out = String::new();
            jq_into(other, &mut out, Some(0));
            out
        }
    }
}

/// jq's `tostring` (also what string interpolation inserts).
pub fn tostring(value: &Value) -> String {
    match value {
        Value::Str(s) => s.clone(),
        other => jq(other),
    }
}

fn python_string(text: &str, out: &mut String) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            ' '..='~' => out.push(ch),
            c => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    let _ = write!(out, "\\u{:04x}", unit);
                }
            }
        }
    }
    out.push('"');
}

/// Python's `json.dumps(value, ensure_ascii=True, …)`: `sorted` is
/// `sort_keys=True`, `compact` the separators `(',', ':')` instead of
/// `(', ', ': ')`.
pub fn python(value: &Value, sorted: bool, compact: bool) -> String {
    let mut out = String::new();
    python_into(value, sorted, compact, &mut out);
    out
}

fn python_into(value: &Value, sorted: bool, compact: bool, out: &mut String) {
    let (item, pair) = if compact { (",", ":") } else { (", ", ": ") };
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Num(n) => out.push_str(&n.python()),
        Value::Str(s) => python_string(s, out),
        Value::Arr(items) => {
            out.push('[');
            for (i, v) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(item);
                }
                python_into(v, sorted, compact, out);
            }
            out.push(']');
        }
        Value::Obj(object) => {
            let mut entries: Vec<&(String, Value)> = object.0.iter().collect();
            if sorted {
                entries.sort_by(|a, b| a.0.cmp(&b.0));
            }
            out.push('{');
            for (i, (k, v)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push_str(item);
                }
                python_string(k, out);
                out.push_str(pair);
                python_into(v, sorted, compact, out);
            }
            out.push('}');
        }
    }
}

// ------------------------------------------------------------- jq semantics

impl Value {
    pub fn str(text: impl Into<String>) -> Value {
        Value::Str(text.into())
    }

    pub fn int(value: i128) -> Value {
        Value::Num(Num::int(value))
    }

    /// jq truthiness: everything but `null` and `false`.
    pub fn truthy(&self) -> bool {
        !matches!(self, Value::Null | Value::Bool(false))
    }

    /// `a // b` for a single-output `a`.
    pub fn or(self, other: Value) -> Value {
        if self.truthy() { self } else { other }
    }

    /// `.key`: null for null and missing keys, an error on non-objects.
    pub fn field(&self, key: &str) -> Jq<Value> {
        match self {
            Value::Obj(object) => Ok(object.get(key).cloned().unwrap_or(Value::Null)),
            Value::Null => Ok(Value::Null),
            _ => Err(JqError),
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn kind(&self) -> u8 {
        match self {
            Value::Null => 0,
            Value::Bool(false) => 1,
            Value::Bool(true) => 2,
            Value::Num(_) => 3,
            Value::Str(_) => 4,
            Value::Arr(_) => 5,
            Value::Obj(_) => 6,
        }
    }
}

/// jq's ordering of any two values.
pub fn cmp(a: &Value, b: &Value) -> Ordering {
    match (a, b) {
        (Value::Num(x), Value::Num(y)) => x.f64().partial_cmp(&y.f64()).unwrap_or(Ordering::Equal),
        (Value::Str(x), Value::Str(y)) => x.as_bytes().cmp(y.as_bytes()),
        (Value::Arr(x), Value::Arr(y)) => {
            for (p, q) in x.iter().zip(y) {
                match cmp(p, q) {
                    Ordering::Equal => continue,
                    other => return other,
                }
            }
            x.len().cmp(&y.len())
        }
        (Value::Obj(x), Value::Obj(y)) => {
            let mut xk: Vec<&String> = x.0.iter().map(|(k, _)| k).collect();
            let mut yk: Vec<&String> = y.0.iter().map(|(k, _)| k).collect();
            xk.sort_by(|p, q| p.as_bytes().cmp(q.as_bytes()));
            yk.sort_by(|p, q| p.as_bytes().cmp(q.as_bytes()));
            let keys = xk
                .iter()
                .map(|k| k.as_bytes())
                .cmp(yk.iter().map(|k| k.as_bytes()));
            if keys != Ordering::Equal {
                return keys;
            }
            for key in xk {
                match cmp(
                    x.get(key).unwrap_or(&Value::Null),
                    y.get(key).unwrap_or(&Value::Null),
                ) {
                    Ordering::Equal => continue,
                    other => return other,
                }
            }
            Ordering::Equal
        }
        _ => a.kind().cmp(&b.kind()),
    }
}

/// jq's `a > b`.
pub fn gt(a: &Value, b: &Value) -> bool {
    cmp(a, b) == Ordering::Greater
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jq_of(text: &str) -> String {
        jq(&parse(text.as_bytes(), Dialect::Jq).unwrap())
    }

    #[test]
    fn numbers_print_like_jq_1_8() {
        for (input, output) in [
            ("1.0", "1.0"),
            ("1e2", "1E+2"),
            ("1E2", "1E+2"),
            ("100", "100"),
            ("-0", "-0"),
            ("-0.0", "-0.0"),
            ("1.5e-7", "1.5E-7"),
            ("0.000001", "0.000001"),
            ("0.0000001", "1E-7"),
            ("123.456e-2", "1.23456"),
            ("12E-0", "12"),
            ("1.0e0", "1.0"),
            ("1e1000", "1E+1000"),
            ("1.7300000000001e12", "1730000000000.1"),
            (
                "123456789012345678901234567890",
                "123456789012345678901234567890",
            ),
            ("3.14159265358979323846", "3.14159265358979323846"),
        ] {
            assert_eq!(jq_of(input), output, "{input}");
        }
        assert_eq!(tonumber("0017").unwrap().0, "17");
        assert_eq!(tonumber("+5").unwrap().0, "5");
        assert_eq!(tonumber(".5").unwrap().0, "0.5");
        assert_eq!(tonumber("1.50").unwrap().0, "1.50");
        assert!(tonumber(" 12").is_err() && tonumber("12 ").is_err() && tonumber("0x10").is_err());
    }

    #[test]
    fn floats_print_like_python_repr() {
        for (value, text) in [
            (1730000000.123, "1730000000.123"),
            (1e16, "1e+16"),
            (1e15, "1000000000000000.0"),
            (0.0001, "0.0001"),
            (0.00001, "1e-05"),
            (1.5e-5, "1.5e-05"),
            (-0.0, "-0.0"),
            (123.0, "123.0"),
            (1.5e300, "1.5e+300"),
            (0.1, "0.1"),
        ] {
            assert_eq!(python_float(value), text);
        }
        assert_eq!(Num("-0".into()).python(), "0");
        assert_eq!(Num("1E2".into()).python(), "100.0");
    }

    #[test]
    fn strings_escape_like_jq_and_python() {
        let value = parse(
            "\"a\\u0001\\u007f\\u0080é\\u2028\\ud83d\\ude00/\\t\"".as_bytes(),
            Dialect::Jq,
        )
        .unwrap();
        assert_eq!(jq(&value), "\"a\\u0001\\u007f\u{80}é\u{2028}😀/\\t\"");
        assert_eq!(
            python(&value, false, true),
            "\"a\\u0001\\u007f\\u0080\\u00e9\\u2028\\ud83d\\ude00/\\t\""
        );
        assert_eq!(
            jq(&parse(b"\"\xff\xfe\"", Dialect::Jq).unwrap()),
            "\"\u{fffd}\u{fffd}\""
        );
        assert!(parse(b"\"\xff\"", Dialect::Python).is_none());
        assert!(parse(b"\"a\tb\"", Dialect::Jq).is_none());
        assert!(parse(b"\"\\ud800x\"", Dialect::Jq).is_none());
    }

    #[test]
    fn objects_keep_first_position_and_last_value() {
        assert_eq!(jq_of(r#"{"b":1,"a":2,"b":3}"#), r#"{"b":3,"a":2}"#);
        let value = parse(br#"{"b":1,"a":[1,{"c":2}],"d":{}}"#, Dialect::Jq).unwrap();
        assert_eq!(
            jq_raw(&value),
            "{\n  \"b\": 1,\n  \"a\": [\n    1,\n    {\n      \"c\": 2\n    }\n  ],\n  \"d\": {}\n}"
        );
        assert_eq!(
            python(&value, true, false),
            r#"{"a": [1, {"c": 2}], "b": 1, "d": {}}"#
        );
    }

    #[test]
    fn invalid_and_stream_input() {
        for bad in [
            "",
            " ",
            "{",
            "[1,]",
            "'a'",
            "nan",
            "NaN",
            "Infinity",
            "-",
            "1e",
            "1_000",
            "truefalse",
            "true1",
            "1true",
            "{} {}",
            "1 2",
        ] {
            assert!(parse(bad.as_bytes(), Dialect::Jq).is_none(), "{bad}");
        }
        for (lenient, text) in [
            ("01", "1"),
            ("1.", "1"),
            (".5", "0.5"),
            ("+1", "1"),
            ("1.e5", "1E+5"),
            ("-01", "-1"),
            ("00", "0"),
        ] {
            assert_eq!(jq_of(lenient), text, "{lenient}");
            assert!(
                parse(lenient.as_bytes(), Dialect::Python).is_none(),
                "{lenient}"
            );
        }
        assert!(parse(b"\xef\xbb\xbf{\"a\":1}\r\n", Dialect::Jq).is_some());
        let (values, complete) = parse_stream(b"{\"a\":1}{\"b\":2} 3\n[4]");
        assert_eq!((values.len(), complete), (4, true));
        let (values, complete) = parse_stream(b"[\"x\"] garbage");
        assert_eq!((values.len(), complete), (1, false));
        // jq's depth limit (a test thread's stack is smaller than main's).
        std::thread::Builder::new()
            .stack_size(64 << 20)
            .spawn(|| {
                let deep = |n| "[".repeat(n) + &"]".repeat(n);
                assert!(parse(deep(10_000).as_bytes(), Dialect::Jq).is_some());
                assert!(parse(deep(10_001).as_bytes(), Dialect::Jq).is_none());
                // An object's key counts while its value is read.
                let keyed = |n| format!("{{\"a\":{}}}", deep(n));
                assert!(parse(keyed(9_998).as_bytes(), Dialect::Jq).is_some());
                assert!(parse(keyed(9_999).as_bytes(), Dialect::Jq).is_none());
                let objects = |m| "{\"a\":".repeat(m) + "1" + &"}".repeat(m);
                assert!(parse(objects(5_000).as_bytes(), Dialect::Jq).is_some());
                assert!(parse(objects(5_001).as_bytes(), Dialect::Jq).is_none());
                let tail = "[".repeat(9_999) + "{\"a\":1}" + &"]".repeat(9_999);
                assert!(parse(tail.as_bytes(), Dialect::Jq).is_some());
            })
            .unwrap()
            .join()
            .unwrap();
    }

    #[test]
    fn ordering_is_jqs() {
        let v = |t: &str| parse(t.as_bytes(), Dialect::Jq).unwrap();
        let order = [
            "null",
            "false",
            "true",
            "-1",
            "2",
            "\"\"",
            "\"a\"",
            "[]",
            "[1]",
            "{}",
            "{\"a\":1}",
        ];
        for pair in order.windows(2) {
            assert_eq!(cmp(&v(pair[0]), &v(pair[1])), Ordering::Less, "{pair:?}");
        }
        assert!(gt(&v("\"abc\""), &v("0")));
        assert!(!gt(&v("true"), &v("0")));
    }
}
