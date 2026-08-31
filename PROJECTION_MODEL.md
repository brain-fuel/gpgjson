# Projection model — the remaining compatibility gap

Every divergence `FuzzDynamicPathDifferential` still finds is one class:
how a projection's state composes with what follows it. This note records
what upstream actually does, so the work starts from a model rather than
from another round of path-shape heuristics.

It is written because heuristics have stopped paying. The last two attempts
each fixed their case and regressed another, and the reason is structural:
the remainder `["0", "#", "0"|]` must keep its pipe inside the projection in
one path and hand it to the collected array in another, and the two are
**identically shaped**. No predicate over the parts can separate them,
because the information that separates them is not in the parts.

## What upstream does

GJSON does not have a "projection" value. It has a path parser that, on
meeting `#` at the start of a component, decides between three things
(`parseArrayPath`, gjson.go:774):

| Spelling | Meaning | Fields set |
| --- | --- | --- |
| `#` alone | count | `arrch` |
| `#.rest` | projection | `arrch`, `alogok`, `alogkey = rest` |
| `#[…]`, `#(…)` | query | `arrch`, `query.*` |

The decisive part is `alogkey`: for a projection, **the entire remaining
path becomes the key**, pipes included. It is not split into components the
way this package splits a path.

The collection then happens at the closing `]` of the array
(gjson.go:1718):

```go
if rp.arrch && rp.part == "#" {
    if rp.alogok {
        left, right, ok := splitPossiblePipe(rp.alogkey)
        if ok {
            rp.alogkey = left      // per-element path
            c.pipe = right         // applied to the COLLECTED array
            c.piped = true
        }
        for each recorded element offset {
            res := parseAny(json, idx).Get(rp.alogkey)
            if res.Exists() { append res.Raw; append res.Index }
        }
        c.value = JSON array of the appended raws
    }
}
```

Two things follow, and both are load-bearing:

1. An element whose per-element path yields nothing **contributes no slot**.
   The collected array is not "one entry per element"; it is one entry per
   element that matched.
2. Whether a pipe binds inside the projection or outside it is decided by
   `splitPossiblePipe` on the alogkey TEXT — not by the component structure.

## `splitPossiblePipe`, exactly

gjson.go:1817. Scanning the path left to right:

- `\` — skip the next byte.
- `.` — if it is the last byte, no split. If the next byte is `#`, advance
  **two** bytes; if the byte landed on is `[` or `(`, skip the balanced
  selector (quotes balanced inside it). Otherwise continue.
- `|` — split here: `path[:i]`, `path[i+1:]`.

The quirk that matters: after `.#`, the loop's own `i++` steps past the
byte the `i += 2` landed on, so **a `|` immediately following `.#` is never
tested** and cannot split. `0.#|0` does not split; `0.#.x|0` does.

This package's `compatibilityProjectionPipe` reproduces that skip in the
parts domain, which is why removing the skip regressed
`info.friends.#.0.#|0` and `a.#.#.#|#`. The skip is correct. The gap is
elsewhere.

## Where the model has to change

The parts model discards the raw path at `compatibilityPathParts`, so by
the time a projection needs to decide about its remainder, the text
`splitPossiblePipe` needs is gone and only components remain. Every
heuristic in `projectCompatibilityArray` and `compatibilityProjectionPipe`
is an attempt to recover that text from the components.

The faithful shape is to carry the remaining path TEXT alongside the parts
and to split it with a port of `splitPossiblePipe`, so a projection's
per-element path and its trailing pipe come from the same rule upstream
uses rather than from a reconstruction.

## Open question, unresolved

The model above does not yet predict `*.[*].#[0].#.#.#|0`, which is `""`
upstream and `[]` here. Tracing gives: `*.[*]` is `[[friend, friend]]`,
`#[0]` is a single-result query selecting the friends array, and the
remaining `#.#.#|0` should become `alogkey = "#.#|0"`, which
`splitPossiblePipe` does not split, applied per friend. Each friend is an
object, so `#` yields nothing and no slot is contributed — which predicts
`[]`, the answer this package already gives.

So either `#[0]` does not leave what the trace suggests, or the outer
`[*]` multipath changes what the query sees. **Resolve that before
refactoring** — it is the one place the written model and the observed
behaviour disagree, and building on a model that is wrong here would
propagate the error into everything the refactor touches.

## What is already exact

For orientation on what must not regress: 2417 recorded corpus paths at
full byte parity, and nine enumerated families — operator precedence,
chained queries, tilde operands, quoted operands, empty left paths,
escaped queries, empty operands, multipath commas, projection nesting —
1748 forms, all exact.
