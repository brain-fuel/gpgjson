# Performance contract

The paired query selects and decodes the escaped string at `users.1.name`.
Upstream GJSON v1.19.0 receives its normal string path and returns an owned
decoded string. GoForge parses and validates an immutable `Document` once,
reuses a schema-indexed `Path[S,StringView]` with a matching
`TypedDocument[S,Document]`, and decodes with `AppendStringView` into reusable
caller-owned storage. `LookupStringInto` is the unboxed eliminator: it retains
the schema-equality obligation and exhaustive state tag without boxing the
proof-oriented generic enum result. Both engines yield `Gopher\nTeam`.

```sh
go test -run '^TestQueryAllocationBudget$' \
  -bench BenchmarkEscapedStringQuery -benchmem -count=5
```

Completion requires the slowest GoForge run to be at least twice as fast as
the fastest upstream run and at least 50% fewer allocations. Document
validation/index construction is intentionally outside the repeated-query
measurement and is amortized by immutable reuse.

## Completion measurement

Measured 2026-07-21 on Apple M5 Max (`darwin/arm64`):

| Query | Five-run range | Bytes/op | Allocations/op |
|---|---:|---:|---:|
| GoForge `Path` borrowed query | 29.76–30.02 ns | 0 | 0 |
| GoForge schema-typed `Path[S,StringView]` | 34.33–34.55 ns | 0 | 0 |
| GJSON v1.19.0 `Get(...).String()` | 79.93–81.64 ns | 16 | 1 |

Using the slowest schema-typed GoForge run and fastest upstream run, the checked
query is **2.31x faster** and uses **100% fewer allocations**. The ordinary
compiled borrowed path is 2.66x faster by the same conservative calculation.
This claim applies to
repeated queries over the indexed immutable document, not one-shot parsing or
deferred wildcard/query/modifier syntax.

## Standard-library wildcard kernel

Dynamic wildcard evaluation forced the extraction of
`goforge.dev/goplus/std/pathquery`. Its greedy UTF-8 matcher replaced the
initial rune-slice dynamic-programming implementation.

```sh
cd ../goplus/std
go test ./pathquery -bench BenchmarkMatch -benchmem -count=5
```

Measured 2026-07-23 on Apple M5 Max (`darwin/arm64`):

| Matcher | Five-run range | Bytes/op | Allocations/op |
|---|---:|---:|---:|
| `std/pathquery.Match` | 74.20–74.49 ns | 0 | 0 |
| replaced dynamic-programming kernel | 726.1–745.5 ns | 1,248 | 24 |

Using the slowest new run and fastest baseline run, the extracted matcher is
**9.76× faster** with **100% fewer allocations**. This comparison validates
the general matcher improvement, not the complete one-shot compatibility
evaluator; end-to-end wildcard/query/modifier benchmarks remain open.

## One-shot compatibility baseline

`BenchmarkDynamicCompatibilityPaths` measures the public dynamic compatibility
entry point against pinned GJSON v1.19.0. The current evaluator does not meet
the release target:

| Path class | GoForge | Upstream | GoForge allocations | Upstream allocations |
|---|---:|---:|---:|---:|
| wildcard | 111.4–111.8 ns | 52.00–52.68 ns | 0 B / 0 | 0 B / 0 |
| query | 460.0–460.5 ns | 219.4–221.2 ns | 0 B / 0 | 0 B / 0 |
| projection | 392.1–394.4 ns | 291.8–296.3 ns | 112 B / 2 | 544 B / 2 |

These measurements are retained as an optimization gate. The compiled,
immutable-document path meets the 2×/50% target; the one-shot compatibility
evaluator currently does not. Direct dynamic dispatch avoids allocating a
doomed strict-path diagnostic. Range-based traversal scans only containers
needed by the selected path, and the ASCII-specialized stdlib matcher removes
all 24 former wildcard allocations. The result is roughly 9.4× faster than the
initial GoForge baseline, but it remains about 2× slower than upstream.

Immutable last-path caching removes repeated path-part construction. Streaming
query evaluation and allocation-free object-child lookup reduce the query path
from 57 allocations to zero. Cached query plans also parse operators and
right-hand operands once, and cached ordinary-component runs avoid
materializing intermediate containers. Projection now uses a `strings.Builder`
and fused object-field traversal, reducing 55 allocations to two and bytes by
79.4% relative to upstream. Compiled one-component queries likewise fuse
predicate lookup with array advancement, avoiding a second object scan. Those
two projection allocations are the exact compatibility
result's output string and its independently observable `Indexes` provenance
slice; removing either would change `Result.Paths` behavior. Full permissive
v1.19.0 parity added bounded provenance and malformed-grammar state to the
cached evaluator; the table above is the post-parity baseline. The throughput
gate remains open.
