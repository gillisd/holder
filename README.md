# Holder

A process supervisor that ensures no child is left behind.

Spawning a child process in Ruby is easy; tearing it down cleanly is not. A child
that ignores `SIGTERM`, a shell that backgrounds grandchildren into the same
process group, a redirect pump blocked on an IO that never reaches EOF — any of
these can leave you with orphaned processes, leaked file descriptors, or dangling
threads.

Holder wraps `Open3` and gives you a single `Handle` that owns the whole lifecycle:
it launches the child in its own process group, lets you talk to its streams, and
on teardown signals the **entire group**, escalates to `SIGKILL` if the grace
period lapses, reaps the child, joins the redirect pumps, and closes every pipe it
owns. Teardown is idempotent, thread-safe, and callable from any thread.

## Requirements

- Ruby >= 4.0.1
- A Unix-like OS (teardown relies on POSIX process groups and signals)

## Installation

Add the gem to your application's Gemfile:

```
$ bundle add holder
```

Or install it directly:

```
$ gem install holder
```

## Usage

A `Holder::Tenant` describes a command to run; `#run` launches it and returns a
`Holder::Handle`. `#run` has two forms.

### Block form — scoped, self-cleaning

The handle is yielded to the block and torn down automatically when the block
exits, **even if it raises**. `#run` returns the block's value. This is ideal for
a process whose lifetime should be tied to a scope — a server you need up only
while a test runs, say:

```ruby
require "holder"

# Bring nginx up only while your integration suite runs. nginx forks a master
# plus worker processes; signalling just the master would orphan the workers, so
# Holder tears down the whole process group. On block exit — or if the block
# raises — everything is reaped and the port is freed.
Holder::Tenant.new("nginx", "-g", "daemon off;", "-c", "/etc/nginx/test.conf").run do |nginx|
  sleep 0.5                                    # wait for nginx to bind the port
  MyApp::IntegrationSuite.run(base_url: "http://localhost:8080")
end
```

### No-block form — you own teardown

`#run` returns the handle; call `#wait` to block until it exits on its own, or
`#terminate`/`#interrupt` to stop it whenever you like. Good for a long-running
process you read from until you've seen enough:

```ruby
# Follow a growing log file in the background, then stop it when you're done.
handle = Holder::Tenant.new("tail", "-F", "/var/log/app.log").run

handle.stdout.each_line do |line|
  break if line.include?("migration complete")
end

handle.terminate   # SIGTERM the group, escalate to SIGKILL after the grace period, reap
```

### Redirecting streams

Pass an **IO object** (not a path or fd number) as `in:`, `out:`, or `err:`:

```ruby
# Feed an IO as the child's stdin (drained to EOF, then closed for you)
sorted = File.open("names.txt") do |input|
  Holder::Tenant.new("sort", in: input).run { |handle| handle.stdout.read }
end

# Send the child's stdout/stderr to your own IOs
File.open("build.log", "w") do |log|
  Holder::Tenant.new("make", "build", out: log, err: log).run.wait
end
```

A stream you redirect is talked to through *your* IO, so the matching accessor on
the handle is `nil`; a stream you leave alone is exposed as a pipe
(`handle.stdin` / `handle.stdout` / `handle.stderr`).

Anything other than an IO or `nil` is rejected by `#run`, before anything is
spawned:

```ruby
Holder::Tenant.new("cat", in: 0).run             # => ArgumentError
Holder::Tenant.new("cat", out: "log.txt").run    # => ArgumentError
Holder::Tenant.new("cat", err: StringIO.new).run # => ArgumentError
```

### Group teardown

The child always runs in its own process group (this is not overridable), so
teardown reaches backgrounded grandchildren too. Signalling only the wrapper
process would orphan anything it spawned; Holder signals the whole group:

```ruby
# A dev script that boots a server and a file watcher alongside it. Both — and
# the shell that launched them — are reaped when the block exits.
Holder::Tenant.new("sh", "-c", "npm run watch & npm start").run do |handle|
  # ... run against the server ...
end
```

### Forwarding spawn options

Any keyword other than `in:`/`out:`/`err:` is forwarded to the underlying spawn
(`chdir`, `umask`, `unsetenv_others`, ...):

```ruby
Holder::Tenant.new("git", "log", "--oneline", "-5", out: $stdout, chdir: "/path/to/repo").run.wait
```

## API

### `Holder::Tenant`

- `Tenant.new(*command, in: nil, out: nil, err: nil, **spawn_opts)` — describe a
  command. `in:`/`out:`/`err:` take an IO or `nil`; `spawn_opts` are forwarded to
  the spawn.
- `#run` — launch, return a `Handle` (caller owns teardown).
- `#run { |handle| ... }` — launch, yield the handle, tear it down on block exit,
  and return the block's value.

### `Holder::Handle`

| Member | Description |
| --- | --- |
| `#pid` | the child's process id |
| `#stdin` / `#stdout` / `#stderr` | the pipe for a stream you did **not** redirect, otherwise `nil` |
| `#wait` | block until the child exits on its own, reap group leftovers, deliver a redirected `out:` to the last byte, and return its `Process::Status` |
| `#terminate(grace: 5)` | `SIGTERM` the group, wait `grace` seconds, then `SIGKILL`; reap and close pipes. Returns the `Process::Status` |
| `#interrupt(grace: 5)` | same as `#terminate` but the first signal is `SIGINT` |
| `#pump_error` | the unexpected error a redirect pump hit (e.g. `ENOSPC`), or `nil`, available after teardown; when both pumps fail, the output-losing (drain) error wins |

`#terminate`, `#interrupt`, and `#wait` are idempotent, thread-safe, and may be
called from any thread; calling `#terminate` twice returns the same status.
Concurrent teardowns share one escalation clock — the earliest deadline any
caller asked for wins, so a `terminate(grace: 0)` is never stuck behind another
caller's longer grace.

### `Holder::Error`

Base error class for the gem.

## How teardown works

1. Signal the whole process group with the first signal (`TERM` or `INT`) — always,
   even if the leader has already exited, since orphaned grandchildren keep the
   group's pgid alive.
2. Wait up to `grace` seconds for the group to die; if it doesn't, send `SIGKILL`
   and wait again.
3. Reap the child.
4. Join the redirect pumps, giving a healthy one `Handle::PUMP_GRACE` seconds to
   finish draining; a pump still blocked on a misbehaving IO is interrupted so it
   can never wedge teardown.
5. Close every pipe the handle owns. Caller-provided `in:`/`out:`/`err:` IOs are
   **not** closed — you opened them, so you close them.

`#wait` differs in two ways: it sends no first signal (group leftovers found
after the leader's own exit are killed outright), and it never deadline-kills
the `out:` drain — a child that exited on its own gets its redirected output
delivered in full, however slow the sink. Bound that delivery by calling
`#terminate` instead.

## Development

After checking out the repo, run `bundle install` to install dependencies. Then:

- `rake test` — run the test suite
- `rake rubocop` — run the linter
- `rake` — run both (the default task)
- `rake zeitwerk:validate` — verify the gem follows Zeitwerk naming conventions

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
