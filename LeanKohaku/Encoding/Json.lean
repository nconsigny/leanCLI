import LeanKohaku.Crypto.Hex

/-!
# JSON value layer

Small dependency-free JSON value type, compact printer, and parser sufficient
for JSON-RPC 2.0 payloads.
-/

namespace LeanKohaku.Encoding.Json

inductive Json where
  | null
  | bool (value : Bool)
  | num (value : Int)
  | str (value : String)
  | arr (values : Array Json)
  | obj (fields : Array (String × Json))
  deriving Repr

def isWs : Char → Bool
  | ' ' | '\n' | '\r' | '\t' => true
  | _ => false

partial def skipWs : List Char → List Char
  | c :: cs => if isWs c then skipWs cs else c :: cs
  | [] => []

def isDigit (c : Char) : Bool :=
  '0' ≤ c && c ≤ '9'

def digitVal (c : Char) : Nat :=
  c.toNat - '0'.toNat

partial def parseDigits : List Char → Nat → Bool → Nat × List Char × Bool
  | c :: cs, acc, _ =>
      if isDigit c then parseDigits cs (acc * 10 + digitVal c) true else (acc, c :: cs, true)
  | [], acc, seen => (acc, [], seen)

/-- Skip the fractional + exponent tail of a JSON number, e.g. the
    `.6985731857318573` or `e+12` part of `0.6985...e+12`. The integer
    portion has already been consumed by `parseDigits`. Stored numbers
    are `Int` (Phase-0 model), so any fractional precision is discarded
    — the goal is to keep the parser moving past floats that producers
    like llama-server's `timings` block emit, not to preserve every
    decimal place. Callers that need the float can re-parse from the
    original string. -/
partial def skipNumberTail : List Char → List Char
  | '.' :: cs =>
      -- consume one or more digits after the decimal point
      let (_, rest, _) := parseDigits cs 0 false
      skipExponent rest
  | rest => skipExponent rest
where
  skipExponent : List Char → List Char
    | 'e' :: cs => skipExpDigits cs
    | 'E' :: cs => skipExpDigits cs
    | rest => rest
  skipExpDigits : List Char → List Char
    | '+' :: cs => let (_, rest, _) := parseDigits cs 0 false; rest
    | '-' :: cs => let (_, rest, _) := parseDigits cs 0 false; rest
    | rest      => let (_, rest, _) := parseDigits rest 0 false; rest

partial def consumeKeyword : List Char → List Char → Option (List Char)
  | [], rest => some rest
  | k :: ks, c :: cs => if k = c then consumeKeyword ks cs else none
  | _ :: _, [] => none

partial def parseStringChars : List Char → List Char → Except String (String × List Char)
  | [], _ => .error "unterminated JSON string"
  | '"' :: rest, acc => .ok (String.ofList acc.reverse, rest)
  | '\\' :: '"' :: rest, acc => parseStringChars rest ('"' :: acc)
  | '\\' :: '\\' :: rest, acc => parseStringChars rest ('\\' :: acc)
  | '\\' :: '/' :: rest, acc => parseStringChars rest ('/' :: acc)
  | '\\' :: 'b' :: rest, acc => parseStringChars rest ('\x08' :: acc)
  | '\\' :: 'f' :: rest, acc => parseStringChars rest ('\x0c' :: acc)
  | '\\' :: 'n' :: rest, acc => parseStringChars rest ('\n' :: acc)
  | '\\' :: 'r' :: rest, acc => parseStringChars rest ('\r' :: acc)
  | '\\' :: 't' :: rest, acc => parseStringChars rest ('\t' :: acc)
  | '\\' :: 'u' :: h1 :: h2 :: h3 :: h4 :: rest, acc =>
      -- \uXXXX → single code point (BMP only; surrogate pairs would
      -- require lookahead for a second \uXXXX. Qwen's typical output
      -- is BMP; punt surrogates to a TODO if they become observable).
      let hexVal : Char → Option Nat := fun c =>
        if isDigit c then some (digitVal c)
        else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
        else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
        else none
      match hexVal h1, hexVal h2, hexVal h3, hexVal h4 with
      | some d1, some d2, some d3, some d4 =>
          let code := d1 * 4096 + d2 * 256 + d3 * 16 + d4
          parseStringChars rest (Char.ofNat code :: acc)
      | _, _, _, _ => .error "invalid \\uXXXX hex digits"
  | '\\' :: _ :: _, _ => .error "unsupported JSON string escape"
  | c :: rest, acc => parseStringChars rest (c :: acc)

def parseStringLit : List Char → Except String (String × List Char)
  | '"' :: rest => parseStringChars rest []
  | _ => .error "expected JSON string"

mutual
  partial def parseValueFrom (chars : List Char) : Except String (Json × List Char) := do
    match skipWs chars with
    | [] => .error "unexpected end of JSON input"
    | 'n' :: rest =>
        match consumeKeyword "ull".toList rest with
        | some rest => .ok (.null, rest)
        | none => .error "invalid JSON null"
    | 't' :: rest =>
        match consumeKeyword "rue".toList rest with
        | some rest => .ok (.bool true, rest)
        | none => .error "invalid JSON true"
    | 'f' :: rest =>
        match consumeKeyword "alse".toList rest with
        | some rest => .ok (.bool false, rest)
        | none => .error "invalid JSON false"
    | '"' :: rest =>
        let (s, rest) ← parseStringChars rest []
        .ok (.str s, rest)
    | '[' :: rest => parseArray rest #[]
    | '{' :: rest => parseObject rest #[]
    | '-' :: rest =>
        let (n, rest, seen) := parseDigits rest 0 false
        if seen then .ok (.num (-Int.ofNat n), skipNumberTail rest)
        else .error "expected digits after minus"
    | c :: rest =>
        if isDigit c then
          let (n, rest, _) := parseDigits rest (digitVal c) true
          .ok (.num (Int.ofNat n), skipNumberTail rest)
        else
          .error s!"unexpected JSON character: {c}"

  partial def parseArray (chars : List Char) (acc : Array Json) :
      Except String (Json × List Char) := do
    match skipWs chars with
    | ']' :: rest => .ok (.arr acc, rest)
    | rest =>
        let (value, rest) ← parseValueFrom rest
        match skipWs rest with
        | ',' :: rest => parseArray rest (acc.push value)
        | ']' :: rest => .ok (.arr (acc.push value), rest)
        | _ => .error "expected comma or closing bracket in JSON array"

  partial def parseObject (chars : List Char) (acc : Array (String × Json)) :
      Except String (Json × List Char) := do
    match skipWs chars with
    | '}' :: rest => .ok (.obj acc, rest)
    | rest =>
        let (key, rest) ← parseStringLit rest
        match skipWs rest with
        | ':' :: rest =>
            let (value, rest) ← parseValueFrom rest
            match skipWs rest with
            | ',' :: rest => parseObject rest (acc.push (key, value))
            | '}' :: rest => .ok (.obj (acc.push (key, value)), rest)
            | _ => .error "expected comma or closing brace in JSON object"
        | _ => .error "expected colon in JSON object"
end

def parse (input : String) : Except String Json := do
  let (json, rest) ← parseValueFrom input.toList
  match skipWs rest with
  | [] => .ok json
  | _ => .error "trailing characters after JSON value"

def escapeChar : Char → String
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\r' => "\\r"
  | '\t' => "\\t"
  | c => c.toString

def quote (s : String) : String :=
  "\"" ++ String.join (s.toList.map escapeChar) ++ "\""

partial def compact : Json → String
  | .null => "null"
  | .bool true => "true"
  | .bool false => "false"
  | .num n => toString n
  | .str s => quote s
  | .arr values =>
      "[" ++ String.intercalate "," (values.toList.map compact) ++ "]"
  | .obj fields =>
      let fieldStrings := fields.toList.map (fun (k, v) => quote k ++ ":" ++ compact v)
      "{" ++ String.intercalate "," fieldStrings ++ "}"

def pretty (json : Json) : String :=
  compact json

def getField (key : String) : Json → Option Json
  | .obj fields => fields.toList.findSome? (fun (k, v) => if k = key then some v else none)
  | _ => none

def asString : Json → Option String
  | .str s => some s
  | _ => none

def asBool : Json → Option Bool
  | .bool b => some b
  | _ => none

def asNat : Json → Option Nat
  | .num n => if n ≥ 0 then some n.toNat else none
  | _ => none

def asArray : Json → Option (Array Json)
  | .arr values => some values
  | _ => none

def asBytes : Json → Option ByteArray
  | .str s => LeanKohaku.Crypto.Hex.decode s
  | _ => none

end LeanKohaku.Encoding.Json
