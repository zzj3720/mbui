# detlint: what determinism must not rest on

A run is deterministic because every input is given by the test: inputs, the core's messages, the host's results,
the clock. Not because anything waits for the app to "settle". `scripts/detlint.py` stops what goes the other way:
a guessed time, a wait for stability, a frame the app asks for itself, the machine's own clock. Being settled stays
one assertion, at a test's end (no input, no animation: no frame).

    python3 scripts/detlint.py                 the report; fails above or below the bar
    python3 scripts/detlint.py . --list RULE   every finding of RULE, file:line
    python3 scripts/detlint.py . --update      the counts found become the bar (never raised: --update=raise)
    python3 scripts/detlint_test.py            each rule's failing and passing example

It runs first in `scripts/check.sh` and in CI's test job. still.fail's `apps/mbui` runs the same file
(`apps/mbui/scripts/detlint.py`, a copy kept the same) with its own `apps/mbui/detlint.json`, from still.fail's
`scripts/check.sh`.

## The bar

`detlint.json` keeps each rule's findings, counted by file (`counts`). More than the bar fails, naming the files
that grew and their lines. Fewer fails too, until `--update` lowers the bar in the same commit: what a migration
moved off cannot come back. A rule at 0 is forbidden outright; once a migration reaches 0 nothing else is needed.

## Exceptions

On the line, or the line over it, with the reason:

    c.request_frame() // det-ok(frame-request): the bench draws every frame on purpose
    # det-ok(script-wait): the emulator's boot has nothing to wait for but its property

Several rules: `det-ok(poll, frame-request): …`. One without a reason is not taken. The report prints every
exception with its reason, and they do not count towards the bar.

## The rules

| rule | stops | instead |
|---|---|---|
| `frame-request` | the app (not `src/ui`, `src/host`, `src/motion`, `src/effect`) calls `Ctx::request_frame`, `@host.request_frame`, `@ui.request_frame` | nothing: the framework frames inputs, events, animations to their deadline, layout reads |
| `settle` | `Tester::settle` / `settled`, `Ctx::settled`, `Runtime::settle` / `settled`, anywhere (tests, the Tester's own `tap`…, the driver), but in their own definitions | `run_for(<a declared time>)`, `finish(<that ticket>)`; `assert_idle()` at the end |
| `flow-wait` | `wait N`, `linger N` in an end-to-end flow | `until`, and the named events (`answered`, `ready`, `decoded`) |
| `script-wait` | `sleep N`, `MBUI_SHOT_AT=N`, `setTimeout(…, N)`, `waitForTimeout(…)`, `time.sleep(…)` in test and screenshot scripts | wait for the file, the log line, the event; a picture at a time its animations declare |
| `frame-count` | a test's `for _ in 0..<N { … t.frame() … }` | the inputs, then `run_for` a declared time |
| `literal-time` | a bare number as a time: `run_for`, `wake_in`, `wake_after`, `wake_at`, `advance`, `frames_until`, `frame(ms=)` (`c.now() + 500.0` too; `0` is no time and passes) | a named length: `run_for(toast_life)`, `wake_at(at + hold_ms)` |
| `stable-mode` | the app reads `Ctx::stable()` (drawn otherwise when screenshotted) | the picture taken at a declared time, of the app as it runs |
| `app-clock` | the app reads the clock: `.now()`, `@ui.now()`, `@host.now()` (`(c.now() - at) / 180.0`, `at = c.now()`) | motion, `wake_at` from a declared length |
| `wall-clock` | `Date.now`, `performance.now`, `Math.random`, `crypto.getRandomValues`… (also inside externs' JS), an unseeded `@random`, `wall_ms()` outside the host / core that provides them | the host's clock through `@ui`, a seed |
| `poll` | a frame or a wake asked for under a condition (if, while, match, an arm's guard, an else's if) that reads the host (`@host.*`), the layout or a host handle (`list_row_height`, `list_place`, `rect_of`, `made`, `grabbed`, `photos`, `pressed`…), or calls a function of the package that does | the host's answer, the layout's, as an event; a deadline while a finger is down is a deadline and passes |
| `host-read` | the app calls `@host.now / wake_after / platform / system_dark / window_inset / env` (still.fail #738) | `@ui`'s, which a Tester answers |
| `globals` | a top-level `let` of a Ref, Map, Array or struct in `globals.roots` that its package's `reset` / `reset_globals` / what `on_reset` is given (and what they call) does not name, nor says `// kept across runs: why` over it (still.fail's check of `mbui-reader-rest`) | put it back in reset |

## How it reads MoonBit, and its limits

A lexer of its own (comments, strings and their `\{…}`, `#|` lines, chars, numbers: `0..<60` is a range), a call
being `NAME(…)` with what is before it (`x.`, `@pkg.`, `T::`) and its arguments split at the top level, top-level
items (a `test` block, a `fn T::f`), blocks and their headers. No types from the compiler: a receiver's type is
inferred where it is written (`self` in `fn T::…`; `x : T`; `let x = T::new(…)`; `let x = f(…)` with `f` declared
`-> T`), and a receiver it cannot tell is counted (over, not under).

Checked against the compiler (`moon ide find-references`, mbui main of 2026-10-20): `Tester::settle` 159 of 159,
`Tester::settled` 4 of 4, `Ctx::settled` 3 of 3, `Ctx::stable` 2 of 2, `Ctx::request_frame` 62 of 62, `Ctx::now` 27
of 27 (of those, 1, 4 and 7 through a receiver it could not type, counted as such); none that the compiler does not
find.

What it does not see:
- `poll` follows reads through the package's functions, not through state: `if update_busy() { c.request_frame() }`
  where `update_busy` reads a field another function filled from `@host.update_state()` is not a poll to it, nor a
  time polled every frame (`if waited(c, k) < later_ms { c.request_frame() }`). In the app both are still
  `frame-request`. Of the 17 polls the frame audit (2026-10-20) lists in still.fail's app, it finds 11.
- `app-clock` counts reads of the clock, not what is done with them: a timestamp kept to show "3 min ago" counts as
  an animation's start does (an exception says which it is).
- `Ctx::still()` (stable or reduced motion) is not `stable-mode`: reduced motion is the person's.
- Hosts (Objective-C, C, Java, JS outside MoonBit externs) are not read.
- `script-wait` reads lines: a `sleep` in a heredoc counts, one in a comment line does not.
