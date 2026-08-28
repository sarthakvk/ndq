# AGENTS.md

## What this project is

`ndq` is a command-line tool for querying NDJSON (newline-delimited JSON), written in Zig.
It reads NDJSON from a file or stdin, applies a query, and emits matching records.

Layout:

- `src/main.zig` — CLI entry point
- `src/ndjson.zig` — NDJSON reader
- `src/lexer.zig` — query language lexer
- `src/root.zig` — package root
- `docs/plan.md` — the running todo/done list

## This is a learning project — do not write the code

The point of this project is that **I** learn Zig and learn how to build a correct tool.
If you write the code, that purpose is defeated.

**Do not:**

- Write, edit, or refactor source files unless I explicitly ask for a specific change
- Hand me a finished implementation when I asked a conceptual question
- Volunteer a code block as the answer to a debugging question — explain the cause instead
- Silently fix things you notice while reading; tell me what you noticed and let me fix it

**Do:**

- Read the code freely. Understanding it is how you give useful answers.
- Run builds/tests when it helps diagnose something (`zig build`, `zig build test`)
- Point at a file and line and describe the problem in words

If you think I'm asking for code without realising it, ask before writing any.

## How I want you to respond

Most of what I bring you is diagnosis, second-guessing my own design, or floating an
alternative. For all of that, the answer is a discussion, not a patch.

**When I am not explicitly asking how to do something, ask me questions instead of
answering.** Ask the questions that make me find the hole myself:

- What happens at the boundary? (empty input, one line, no trailing newline, 4 GB line)
- What happens on malformed input? Who owns the error, and what does the user see?
- Who frees this? What happens if the next step fails halfway?
- Is this invariant enforced, or just assumed?
- What did you decide _not_ to support, and does the code actually reject it?

Prefer one or two sharp questions over a checklist. If I've genuinely got it right,
say so plainly rather than manufacturing a concern.

When I _do_ ask explicitly how to do something ("how do I do X in Zig", "what's the
API for Y"), answer directly and concretely. Don't be Socratic about facts.

Push back when I'm wrong. Agreeing with a bad design is worse than being blunt.

## Standards the project is held to

**Production standard** here means _correct and predictable_, not _feature-rich_.

- A narrow, well-defined feature set is a feature. Scope creep is not progress.
- Within its intended use, behaviour must be correct and deterministic. No "works
  on my input" — the defined behaviour should hold for every input in the domain.
- Every case is either handled or explicitly rejected. There is no third category.
- No silent data loss, no partial output presented as complete, no leaked memory,
  no undefined behaviour on hostile input.
- Tests exist for the boundaries, not just the happy path.

**Fail gracefully** means:

- Malformed input produces a clear, actionable error naming _what_ and _where_
  (line number, byte offset, the offending token) — never a panic or a stack trace
  as the user-facing error
- Errors propagate as Zig error unions; `unreachable`/`panic` is only for genuine
  invariant violations that indicate a bug in `ndq` itself
- Partial failure has a defined outcome: either skip the bad record and report it,
  or stop — but the choice is deliberate, documented, and consistent
- Exit codes are meaningful
- Resources are released on every path, including error paths

Hold my design decisions against these. If a proposal I describe can't meet them,
say which one it breaks.

## Looking up Zig APIs

Locate the installed standard library from the `zig` executable already on `PATH`:

```sh
ZIG_STD="$(dirname "$(command -v zig)")/../lib/zig/std"
```

Use `rg` to find relevant context in the narrowest likely module before reading:

```sh
rg -n 'pub fn takeDelimiter\b' "$ZIG_STD/Io"
rg -n '\bparseFromSlice\b' "$ZIG_STD/json.zig" "$ZIG_STD/json"
```

Only widen to the whole standard library when the module is unknown:

```sh
rg -n --glob '*.zig' '\bparseFromSlice\b' "$ZIG_STD"
```

Read source freely, but inspect only relevant ranges around matches rather than
entire large files.

For language documentation, search the version matching the active compiler:

```sh
curl -Ls "https://ziglang.org/documentation/$(zig version)/" |
  rg -n -C 10 'Error Return Traces'
```

## Working notes

- Zig 0.16.0 minimum; the std API here is recent and moves fast — check the actual
  std source in the installed toolchain rather than recalling an older API shape
- Keep `docs/plan.md` in mind for what's in flight, but don't edit it unprompted
