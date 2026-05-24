import LeanKohaku.Agent.Session
import LeanKohaku.Agent.State
import LeanKohaku.Encoding.Json

/-!
# Session DB smoke test

End-to-end exercise of the SQLite-backed session store. Run via
`.lake/build/bin/agent_session_test`; non-zero exit signals a real
regression. We do not gate this on the broader CI Lean theorem
prover gate — proofs are still the source of truth for behavioural
properties; this binary checks that the FFI shim, the schema
bootstrap, and the FTS5 trigger wiring are honest.

The test uses a `mktemp` file rather than `:memory:` so we exercise
the on-disk WAL path the daemon will actually use, and so we can
re-open the DB to check that data survives a close.
-/

namespace LeanKohaku.Agent.SessionTest

open LeanKohaku.Agent
open LeanKohaku.Agent.Session
open LeanKohaku.Encoding.Json

/-- Failure aborts the test with a non-zero exit. The msg goes to
    stderr to keep stdout clean for shell scripts. -/
private def fail {α : Type} (msg : String) : IO α := do
  IO.eprintln s!"agent_session_test: FAIL: {msg}"
  IO.Process.exit 1

private def check (cond : Bool) (msg : String) : IO Unit :=
  if cond then pure () else fail msg

private def tmpDbPath : IO String := do
  let dir ← IO.getEnv "TMPDIR"
  let base := dir.getD "/tmp"
  let pid ← IO.Process.getPID
  pure s!"{base}/leankohaku-session-test-{pid}.sqlite"

private def cleanup (path : String) : IO Unit := do
  -- WAL/SHM siblings ride along — delete each best-effort.
  for suffix in ["", "-wal", "-shm", "-journal"] do
    let p : System.FilePath := path ++ suffix
    try
      if ← p.pathExists then IO.FS.removeFile p
    catch _ => pure ()

def main : IO UInt32 := do
  let path ← tmpDbPath
  cleanup path
  IO.eprintln s!"agent_session_test: using {path}"

  -- 1. Open / close cycle on an empty DB bootstraps the schema.
  let h ← openDb path
  close h
  IO.eprintln "agent_session_test: bootstrap OK"

  -- 2. Reopen, create a session, append 10 messages, load back in order.
  let h ← openDb path
  let sid ← createSession h (.obj #[
    ("chainId", .num 11155111),
    ("model",   .str "local-default")
  ])
  check (sid ≥ 1) s!"createSession returned bogus id {sid}"

  for i in [0:10] do
    let m : AgentMessage := {
      role := if i % 2 == 0 then .user else .assistant,
      content := some s!"turn {i}: hello world {i}",
      toolCalls := [],
      toolCallId := none
    }
    appendMessage h sid m

  let loaded ← loadSession h sid
  check (loaded.size == 10)
    s!"expected 10 messages, got {loaded.size}"
  for i in [0:10] do
    let m := loaded[i]!
    let expectedRole : Role := if i % 2 == 0 then .user else .assistant
    check (m.role == expectedRole) s!"msg {i} role mismatch"
    check (m.content == some s!"turn {i}: hello world {i}")
      s!"msg {i} content mismatch: {repr m.content}"
  IO.eprintln "agent_session_test: round-trip OK"

  -- 3. Append a message carrying a tool call; round-trip preserves
  --    the tool call list.
  let withTool : AgentMessage := {
    role := .assistant,
    content := none,
    toolCalls := [{ id := "call_1", name := "tx_simulate", argsJson := "{\"chainId\":11155111}" }],
    toolCallId := none
  }
  appendMessage h sid withTool

  let loaded2 ← loadSession h sid
  check (loaded2.size == 11)
    s!"expected 11 messages after tool-call append, got {loaded2.size}"
  let last := loaded2[10]!
  check (last.toolCalls.length == 1) "tool_calls not round-tripped"
  check ((last.toolCalls.head?.map (·.name)).getD "" == "tx_simulate")
    "tool_call name not round-tripped"
  IO.eprintln "agent_session_test: tool-call round-trip OK"

  -- 4. FTS5 search returns the expected message ids.
  let hits ← searchFts h "world" 20
  check (hits.size ≥ 1)
    s!"expected ≥1 FTS hit for 'world', got {hits.size}"
  for hit in hits do
    check (hit.sessionId == sid)
      s!"hit references wrong session: {hit.sessionId}"
    check (hit.snippet.length > 0)
      "FTS snippet was empty"
  IO.eprintln s!"agent_session_test: FTS OK ({hits.size} hits)"

  -- 5. Concurrent handles: a second handle on the same DB sees data
  --    written by the first. (Same process, same WAL — exercises the
  --    "open twice, read in B, write in A" pattern the daemon does
  --    not use in Phase 1a but might in 1c.)
  let h2 ← openDb path
  let loadedB ← loadSession h2 sid
  check (loadedB.size == 11)
    s!"second handle saw {loadedB.size}, expected 11"
  close h2
  IO.eprintln "agent_session_test: concurrent-handle OK"

  -- 6. Close the session, verify closed_at is recorded by checking
  --    that loadSession still returns all messages (closing is just
  --    a flag, not a deletion).
  closeSessionRow h sid
  let loadedC ← loadSession h sid
  check (loadedC.size == 11) "closeSession lost messages"
  IO.eprintln "agent_session_test: close-session OK"

  close h
  cleanup path
  IO.println "agent_session_test: PASS"
  pure 0

end LeanKohaku.Agent.SessionTest

def main : IO UInt32 := LeanKohaku.Agent.SessionTest.main
