# Projection model — the remaining compatibility gap

How a projection's state composes with what follows it was the last class
of divergence `FuzzDynamicPathDifferential` could find. This note records
what upstream actually does, and what has been ported from it.

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

## The contradiction, resolved

The note previously recorded that the model did not predict
`*.[*].#[0].#.#.#|0` — `""` upstream, `[]` here. It is resolved, and the
resolution was the missing piece.

There are TWO call sites for `splitPossiblePipe`, on two different strings:

- **the alogkey** (gjson.go:1721), when a projection collects; and
- **the query continuation** (gjson.go:1551), when a query matches and
  there is more path.

The decisive experiment: evaluating the tail `#.#.#|0` fresh against the
intermediate's raw JSON gives `[]`, while the same tail inside the full
path gives `""`. State was not being carried — the two are simply
different strings reaching different call sites.

After the query `#[0]` matches, the continuation is `#.#.#|0`, and the scan
consumes the FIRST `.#`, lands on the `.` that follows, and the loop's own
step carries it past — so the second `.#` never triggers the skip and the
`|` splits. Left `#.#.#` runs on the matched element and yields `[]`; right
`0` indexes that empty array and yields nothing. Evaluated fresh instead,
`#` leads and the path becomes an alogkey of `#.#|0`, where the scan lands
directly on the `|` and steps past it, so it never splits and the pipe stays
inside the projection — giving `[]`.

`compatibilityContinuationPipe` is that rule, transcribed, and applied where
upstream applies it. It works on rebuilt TEXT rather than on components
because a component-level scan applies the skip at every `#` and over-skips;
the offset is then mapped back to a part index.

## Still to do

The alogkey call site is not yet ported — projections still decide their
remainder through `compatibilityProjectionPipe` over components, which is
the same over-skipping approximation. It happens to agree everywhere
measured, but it agrees by construction rather than by transcription, and
it is the remaining piece of this model.

## What is already exact

For orientation on what must not regress: 2417 recorded corpus paths at
full byte parity, and nine enumerated families — operator precedence,
chained queries, tilde operands, quoted operands, empty left paths,
escaped queries, empty operands, multipath commas, projection nesting —
1748 forms, all exact.
