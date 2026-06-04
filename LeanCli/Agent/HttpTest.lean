import LeanCli.Agent.Http

/-!
Compile-time assertions over `LeanCli.Agent.Http`'s pure pieces.
Build-fail-on-divergence stays in line with the project's "proofs are
the tests" stance — invalid loopback URLs cannot regress silently.
-/

namespace LeanCli.Agent.Http.Test

open LeanCli.Agent.Http

-- Accept: localhost / 127.0.0.1 / [::1], optionally followed by port
-- or path.

#guard isLoopbackUrl "http://127.0.0.1"
#guard isLoopbackUrl "http://127.0.0.1/"
#guard isLoopbackUrl "http://127.0.0.1/v1/chat/completions"
#guard isLoopbackUrl "http://127.0.0.1:8080"
#guard isLoopbackUrl "http://127.0.0.1:8080/v1"
#guard isLoopbackUrl "http://[::1]"
#guard isLoopbackUrl "http://[::1]:8080/v1"
#guard isLoopbackUrl "http://localhost"
#guard isLoopbackUrl "http://localhost:8080"
#guard isLoopbackUrl "http://localhost/v1"

-- Refuse: anything that isn't loopback. The check is permissive on
-- structure (only prefix + terminator) so it must be strict on host.

#guard !isLoopbackUrl ""
#guard !isLoopbackUrl "https://127.0.0.1"
#guard !isLoopbackUrl "https://localhost:8080"
#guard !isLoopbackUrl "http://api.openai.com/v1/chat/completions"
#guard !isLoopbackUrl "http://localhost.evil.com"
#guard !isLoopbackUrl "http://127.0.0.1.evil.com"
#guard !isLoopbackUrl "http://[::1].evil"

-- File-URL and other schemes refused.
#guard !isLoopbackUrl "file:///etc/passwd"
#guard !isLoopbackUrl "ftp://127.0.0.1"

end LeanCli.Agent.Http.Test
