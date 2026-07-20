# HOLDER

## Description
Holder is a robust, yet ergonomic process supervisor written in ruby.
Its goal is to allow ruby to have more control in orchestrating continuous, external shellouts, like a short lived nginx server.

It leans on ruby's own open3 library, whilst handling the parts that open3 doesn't. 

## Rules

1. **Commit often, and always forward**. Commit work frequently, and never rewrite history unless explicitly told to do so. "Rewriting history" is defined as any non-append only operation, such as amending, destructive rebasing (e.g. squashing), force pushing, and the like.

2. **Idiomatic, current-generation code only.** Always write idiomatic Ruby, and idiomatic usage of whatever gems/frameworks this project depends on. This is a greenfield project on the latest version of every tool — use the newest APIs and patterns, never deprecated or legacy-compatibility ones.

3. **Cross-reference the bundled framework docs before writing framework code.** Any line in a framework-related file (Rails, Sinatra, Hanami, etc., whichever this project uses) must first be checked against the bundled reference docs to confirm it follows the latest idiomatic pattern. Never write framework code from memory alone. Also use ruby-lsp to assist with writing.

5. **Self-documenting code over comments.** Communicate intent primarily through naming:
   - Well-named local variables (noun) and methods (verb) can often articulate the same thing a one line comment can.
   - Proper abstractions and entities with good names usually tell a story better than comments. Distill:
     - the _behaviors_ you need (methods/modules)
     - the _performer_ of those behaviors (classes/objects)
     - the _requirements_ of those behaviors (arguments/parameters)
     - the _recipient_ (if any) of those behaviors (return value)
   - If you have truly exhausted the above, then a comment is recommended.

6. **Avoid vague "-or"/"-er" names** (e.g. `LineProcessor`, `DataManager`). Only use one when Ruby or its frameworks spec it out as a defined architectural role — like Rails does with `Controller` or `Serializer` — with its own responsibilities and conventions, not just a common-sounding name you've assigned yourself. Despite this gem being called "holder", it does not have a class with the same name - it leans on a properly named domain model.

7. **"Done" means done**, as defined in the next section.

8. **Specs are tiered by cost, and the tier decides everything else**, as defined in the Testing section.

## Testing

RSpec only. Two tiers, and which one a spec belongs to is decided by what it
costs to run, never by what it is about.

**`spec/unit`** — pure logic. Spawns no child, sleeps for nothing, asserts no
duration. Held to a hard one-second budget that an example may lower and may
never raise: an example that wants longer is an integration example in the wrong
directory. These describe a **class**, and the file path has to match it
(`describe Holder::Tenant` lives at `spec/unit/holder/tenant_*_spec.rb`).

**`spec/integration`** — real children, real signals, host-dependent fixtures.
These describe a **behaviour in prose** (`RSpec.describe "tearing down a process
group"`), because the subject is a behaviour and several files legitimately
drive the same class from different angles.

Rules that follow from the split:

- **The watchdog is a backstop, not an assertion.** Its job is to stop a wedged
  example, and its default is deliberately tight enough to also bound teardown
  itself — most teardown examples assert liveness only *after* `terminate`
  returns, so the budget is the only thing bounding how long `terminate` may
  take. Do not loosen it to make something pass. An example whose own scripted
  work approaches the budget states a bigger one with `it "...", timeout: 8`,
  **and** asserts explicitly whatever the budget had been bounding implicitly.
- **A timing contract is an expectation, never a budget.** "Teardown returns
  within `PUMP_GRACE + 2`" is `expect(elapsed { ... }).to be < ...`.
- **Never loosen a cop to make a spec pass.** A `RSpec/ExampleLength`,
  `MultipleExpectations` or `SpecFilePathFormat` offence means the spec is not
  fine-grained enough: split the example per contract, lift staging into a named
  helper, or split the file. `:aggregate_failures` is for facets of one
  genuinely expensive staged scenario, not for dodging a split.
- **Nothing survives an example.** Every child, pipe, tmpfile and path is
  registered with `cleanup` so it is undone even when the example fails.
- Support classes and helper modules live in `spec/support` and are
  Zeitwerk-autoloaded, exactly as the gem's own constants are.

**A ported or refactored spec has never been seen to fail, so it has not been
tested.** Before trusting one, re-introduce the regression it exists to catch
and watch it go red.

## Definition of "done"

A task is not done until every loose end is taken care of. Do not stop with outstanding follow-ups, deferred fixes, or "still pending" items — finish them as part of the task.

State completion without caveats. A task is either **done and production ready** or it is **not done** — there is no third state. Do not hedge, do not attach "known limitations" or "runner-ups" to something you call complete. If something remains, the task is not done.

**Blocked is a specific claim, not a synonym for difficult.** You are genuinely blocked only when completing the task requires a decision, credential, permission, or resource outside your access — not because the problem is hard, ambiguous, or would take a long time to work through. If you can make progress by reasoning further, researching, or trying an alternative approach, you are not blocked.

If you are genuinely blocked, you are to do the following before stopping "not done" work:

1. Record the reason in `_claude/blocklog.md`.
2. Spin up 3 subagents, each given the same problem statement independently, without seeing each other's reasoning until after they've each proposed a path forward.
3. Communicate the issue at hand, and what you think the paths forward are.
4. Record each subagent's proposed path and reasoning in `_claude/blocklog.md`.
5. If at least 2/3 subagents independently agree on the same path forward, take that path. If the agreement is because they were fed the same framing or assumptions rather than reaching it independently, treat that as no consensus. Otherwise:
   - Stop working.
   - Report to user that you are stopping because the work is **not done** and you are **blocked**.
