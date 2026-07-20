# Implementing the "no child outlives its host" backstop

**Status: designed, not built.** The contract is pinned by four `pending` examples
in `spec/integration/no_child_outlives_its_host_spec.rb`. Build the backstop, watch
them flip green, then delete their `pending` lines.

## The invariant

No supervised child outlives its host process — for every host exit **except
SIGKILL** (uncatchable). Prior art: an OTP supervisor terminates its children on
shutdown, and `erlexec` kills the process group when the owner disconnects; even a
zsh shell HUPs its jobs on exit. Orphaning a child to init is the bug this closes.

## Where it stands

- **Block form** already keeps it, through `Tenant#run`'s `begin/ensure
  handle.terminate`. Ruby 4.0 unwinds `ensure` on an untrapped SIGTERM (and on
  SIGINT's `Interrupt`), so the block form reaps on normal return, raise, SIGINT,
  and SIGTERM. Green — see `host_sigterm_teardown_spec`, `tenant_block_form_spec`.
- **No-block form** does not. `Tenant#run` returns the handle and installs nothing,
  so a host that never calls `terminate`/`wait` leaks the child to init. The four
  pending examples are exactly that gap.

## The design: a registry + one `at_exit`

1. **Registry** — a process-wide, mutex-guarded collection of live handles. Register
   each handle when `Tenant#run` creates it.
2. **Deregister on teardown** — in `Handle#finalize` (reached by
   terminate/interrupt/wait), drop the handle from the registry. Keeps the registry
   to genuinely-live children and keeps the leak specs (`resource_leak_spec`) honest.
3. **The backstop** — one `at_exit` that walks whatever is still registered and reaps
   each with a *bounded* teardown: `terminate` with a short (or zero) grace — TERM
   then KILL — **never** an unbounded `wait`, or a wedged child would hang the
   process's own exit.

`at_exit` fires on normal exit, an uncaught exception, SIGINT (Ruby raises
`Interrupt`), and — on Ruby 4.0 — SIGTERM. Not on SIGKILL. That is precisely the four
pending cases, plus the SIGKILL boundary that must keep surviving.

## Watch-outs

- **Idempotency is free.** `Handle` teardown is already mutex-guarded and idempotent,
  so the `at_exit` calling `terminate` on a handle the caller already tore down is a
  no-op. Deregistration is therefore an optimization (bounds exit cost, keeps the
  leak specs honest), not a correctness requirement.
- **Strong refs are correct.** The registry must hold the handle to reap its child,
  so a registered handle will not be GC'd — that is fine. `tenant_block_form_spec`'s
  "leaves a dropped handle's child running" only asserts the child is alive
  *mid-run* (it is; the backstop reaps at process exit, not at GC). Do **not** use a
  `WeakMap`: a collected handle would lose the ref and re-open the leak.
- **Bound the exit.** Reaping many handles each through a full grace window would
  drag out process exit. A plain child dies on the first TERM in milliseconds, so a
  short grace (or `grace: 0`) suffices; reap concurrently if a host holds many.
- **No detach.** There is deliberately no opt-out — outliving the process is
  `Process.spawn`'s job, not a supervisor's. Every registered handle gets reaped.

## Verifying the flip

Delete the `pending` lines, then run under podman for a clean multi-core env — the
1-core sandbox shell flakes `group_teardown` on CPU contention, unrelated to this
work:

```sh
podman run --rm --network host -v "$PWD":/src:ro \
  docker.io/library/ruby:4.0 bash -lc 'cp -a /src /app && cd /app && bundle install && bundle exec rspec'
```
