# ndq

`ndq` is a small, streaming command-line tool for filtering newline-delimited JSON (NDJSON) without loading the entire input into memory.

> [!WARNING]
> `ndq` is a work in progress. Its interface and query language may change.

## Install

Building from source requires [Zig 0.16.0](https://ziglang.org/download/) or newer:

```sh
git clone https://github.com/sarthakvk/ndq.git
cd ndq
zig build -Doptimize=ReleaseFast --prefix ~/.local
```

Ensure `~/.local/bin` is in your `PATH`, then run `ndq`.

## Use

Pass NDJSON through stdin:

```sh
cat users.ndjson | ndq 'active = true'
```

Or read from a file and write matching records to stdout:

```sh
ndq -i users.ndjson 'profile.country = "IN" & age >= 18'
```

Write the result to an existing file with `-o`:

```sh
: > adults.ndjson
ndq -i users.ndjson -o adults.ndjson 'age >= 18'
```

```text
ndq [OPTIONS] <query>

-i FILE, --input=FILE   Read from FILE instead of stdin
-o FILE                 Write to FILE instead of stdout
```

Each matching input line is emitted unchanged.

## Query syntax

A query compares fields and JSON values:

> values are always inside double quotes, and unquoted identifier will be treated as a fields

```text
status = "active"
age >= 18
verified != null
```

Supported comparison operators are `=`, `!=`, `<`, `<=`, `>`, and `>=`. Values may be strings, integers, floats, booleans, or `null`.

Use `.` for nested fields and array indexes:

```text
profile.country = "IN"
tags.0 = "zig"
events.-1.type = "logout"
```

Use quoted field names when a key is not a bare identifier. Prefix a quoted root field with `@`:

```text
@"display name" = "Sarthak"
profile."display name" = "Sarthak"
```

Combine comparisons with `!` (not), `&` (and), `|` (or), and parentheses. Precedence is `!`, then `&`, then `|`:

```text
active = true & (role = "admin" | role = "owner")
!(deleted = true)
```

## Contributing

Bug reports and human-written bug fixes are welcome. Please include a small NDJSON sample, the query, and the expected and actual output when reporting a bug.

This learning project does **not** accept AI-generated code contributions. The implementation is human-written; AI was used only to expand test coverage.
