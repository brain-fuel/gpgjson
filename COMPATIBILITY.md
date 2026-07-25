# GJSON v1.19.0 compatibility and path matrix

The pinned reference is `github.com/tidwall/gjson` v1.19.0 at commit
`0fac2c9aa6eb5d5564bfaaaad513ce0d5d2314de` (MIT). `API_MANIFEST.csv`
inventories all 45 exported declarations. Tier 1 keeps the high-use scalar
facade while making parsed paths, validation, ownership, and modifiers explicit.

## Path language

| Construct | Semantic `CompilePath` | Compatibility `Get` |
|---|---|---|
| Dot-separated object fields | Supported and compiled | Supported |
| Numeric array indices | Supported | Supported |
| Escaped components | Supported | Supported |
| Empty path | Selects validated root | Returns upstream missing result |
| Missing and explicit null | Exhaustive distinct states | Upstream-compatible `Result` |
| Wildcards `*`, `?` | Rejected | Supported through `std/pathquery` |
| Array count/projection `#` | Rejected | Supported |
| Queries `#(...)`, `#[...]` | Rejected | First/all selection and comparison/glob operators supported |
| Multipaths `{...}`, `[...]` | Rejected | Supported |
| Modifiers and pipes | Explicit immutable `Registry` | Legacy globals, all pinned built-ins, custom modifiers, and disabling supported |
| Static literals `!value` | Rejected | Supported, including continued paths |

The semantic `Document` validates the entire JSON value before indexing it.
Upstream GJSON deliberately permits queries over some malformed input; GoForge
returns `MalformedState` instead. Numbers retain their raw decimal spelling.
`Borrowed.Int64` is lossless and rejects fractional, exponent, and overflowed
values; `Float64` is a visibly lossy opt-in conversion.

The dependent facade binds each format value as `TypedDocument[S,D]`; lookup
requires the same schema index on the document and `Path[S,T]`. Generated Go
retains and compares both schema witnesses at the erased boundary.

## API tier

`Type`, `Result`, scalar constants, `Parse`, `Get`, byte and multi variants,
`Valid`, `Escape`, and the common scalar/result methods are present. The
compatibility facade owns byte input and may allocate decoded `Result.Str`, as
upstream does. Semantic callers should compile a `Path`, parse a `Document`
once, and query `Borrowed` views.

Global `AddModifier`, `ModifierExists`, and `DisableModifiers` are implemented
for source and behavioral compatibility. `Registry.With`, `Registry.Exists`,
and `Registry.Apply` are the immutable additive API for new code. All 45
declarations are present and the manifest is reproducibly identical to pinned
v1.19.0; exhaustive behavioral proof remains separately gated.

The deterministic grammar matrix currently crosses 316 selector,
continuation, pipe, modifier, multipath, and malformed-delimiter cases against
the pinned evaluator. A 2026-07-24 differential fuzz gate loaded 2,042 local
corpus/cache inputs and completed 5.41 million additional executions in ten
seconds. It found and retained escaped-query-operator, wildcard/empty-operand,
trailing-escape, mismatched-multipath-delimiter, modifier-fallback, pipe
provenance, projection-provenance, escaped modifier, static-literal recovery,
escaped wildcard/dot cases, and multipath naming/recovery cases. This is
materially broader
evidence, but is not described as an exhaustive malformed-path proof.

The pinned upstream test extractor now records 1,301 distinct `(source,path)`
pairs from 94 deterministic v1.19.0 tests in `UPSTREAM_PATH_CORPUS.csv`.
All 1,301 match every public `Result` field. `UPSTREAM_PATH_GAPS.csv` is
header-only; the differential test rejects both new mismatches and stale gap
entries, so the exact denominator cannot silently regress.

## Borrowed lifetime

`ParseDocument(string)` retains its source string. Every `Borrowed` result
retains the same source and remains valid independently of the `Document`
variable. `Raw` is a zero-copy substring. `AppendString(dst)` decodes into
caller-owned reusable storage and does not retain `dst`.

`ParseDocumentBytes` intentionally copies input once; mutating or reusing the
caller’s byte slice cannot invalidate results. `LineScanner` similarly owns
each scanned line before publishing its `Document`. No unsafe string alias is
exposed.
