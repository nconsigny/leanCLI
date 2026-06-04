/-!
# Loopback-only HTTP transport for the Lean-native agent

Thin Lean wrapper over the libcurl FFI shim in `c/lean_http/`. The C
layer is the floor for the loopback check; this layer adds the same
string-prefix rule before calling FFI so a future C-side regression
cannot widen the trust boundary silently.

Trust model: the agent talks to a local LLM server on the loopback
interface. Any URL whose host is not `127.0.0.1`, `[::1]`, or
`localhost` is refused. No HTTPS, no redirects, no auth headers — see
`c/lean_http/lean_http.c` for the C-side rationale.
-/

namespace LeanCli.Agent.Http

/-- Structured HTTP failure reasons. Mirrors the negative-coded error
    space in `c/lean_http/lean_http.h`. `nonJsonResponse` is a Lean-side
    classification (decoded from a successful HTTP exchange whose body
    isn't valid JSON) and never originates from FFI. -/
inductive Error where
  | transport       : String → Error
  | tooLarge        : Error
  | nonLoopback     : String → Error
  | timeout         : Error
  | nonJsonResponse : String → Error
  deriving Repr

/-- A successful HTTP response: server-reported status + body bytes. -/
structure Response where
  status : Nat
  body   : ByteArray

/-- Raw FFI return shape. Decoded by Lean into `Except Error Response`.
    `kind` mirrors the negation of `LK_HTTP_ERR_*` (0 = success). On
    failure the FFI puts a textual reason into `body`. -/
structure RawResponse where
  status : UInt32
  kind   : UInt32
  body   : ByteArray

@[extern "lk_http_post_json_ffi"]
private opaque postJsonRaw
    (url : @& String) (body : @& ByteArray) (timeoutMs : UInt32) : IO RawResponse

private def acceptedLoopbackPrefixes : List String :=
  [ "http://127.0.0.1"
  , "http://[::1]"
  , "http://localhost" ]

/-- Lean-side mirror of the C loopback check. Accepts a host prefix
    followed by either ':' (port), '/' (path), or end-of-string. Keep
    in sync with `lk_is_loopback_url` in `c/lean_http/lean_http.c`.
    Returns the first matched prefix when accepted (for diagnostics);
    otherwise `none`. -/
def isLoopbackUrl (url : String) : Bool :=
  acceptedLoopbackPrefixes.any fun pfx =>
    if url.startsWith pfx then
      let rest := url.drop pfx.length
      rest.isEmpty || rest.startsWith ":" || rest.startsWith "/"
    else
      false

/-- Decode the raw FFI tuple into our typed Result. -/
private def fromRaw (r : RawResponse) : Except Error Response :=
  let bodyStr : String := String.fromUTF8! r.body
  match r.kind with
  | 0 => .ok { status := r.status.toNat, body := r.body }
  | 1 => .error (.transport s!"invalid url: {bodyStr}")
  | 2 => .error (.nonLoopback bodyStr)
  | 3 => .error .timeout
  | 4 => .error (.transport bodyStr)
  | 5 => .error .tooLarge
  | _ => .error (.transport bodyStr)

/-- POST `body` as `application/json` to `url`. The URL is checked
    against the loopback allowlist before any FFI call. `timeoutMs`
    bounds the whole operation; 0 disables the timeout (not
    recommended). -/
def postJson (url body : String) (timeoutMs : Nat := 30000) :
    IO (Except Error Response) := do
  if !isLoopbackUrl url then
    return .error (.nonLoopback s!"refusing non-loopback url: {url}")
  let raw ← postJsonRaw url body.toUTF8 timeoutMs.toUInt32
  return fromRaw raw

/-- Convenience: decode the response body as UTF-8 string. Returns
    `nonJsonResponse` if the bytes don't decode as valid UTF-8. -/
def Response.bodyString (r : Response) : Except Error String :=
  match String.fromUTF8? r.body with
  | some s => .ok s
  | none => .error (.nonJsonResponse "response body is not valid UTF-8")

end LeanCli.Agent.Http
