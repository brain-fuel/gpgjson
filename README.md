# GoForge schema-aware JSON paths

`goforge.dev/gpgjson` is the `/goals/07-gjson` semantic rewrite of
`github.com/tidwall/gjson`.

- immutable compiled paths and validated indexed documents;
- exhaustive missing/null/value/malformed lookup states;
- lossless integer access and explicit lossy floating-point conversion;
- zero-copy borrowed raw values and reusable-buffer string decoding;
- immutable modifier registries and JSON-lines streaming;
- Go+-authored `Path[S,T]`, `TypedDocument[S,D]`, `Lookup[T,p]`, finite
  existential paths, presence witnesses, and schema-preserving composition;
- the same typed integer path demonstrated against JSON and CBOR.

All production semantics are now authored in `.gp`, including the scanner,
compiled paths, immutable documents, modifiers, compatibility facade, bridges,
and the indexed `typed` package. Version-marked `*_gp.go` artifacts are
generated reproducibly by the pinned Go+ compiler:

```sh
go generate ./...
go tool goplus gen -check ./...
go test ./...
```

```go
document, err := gjson.ParseDocument(source)
path := gjson.MustCompilePath("users.0.id")
lookup := document.Query(path)
value, present := lookup.Value()
id, err := value.Int64()
```

See [COMPATIBILITY.md](COMPATIBILITY.md) for the exact path/API tier and
borrowed lifetime contract, [PERFORMANCE.md](PERFORMANCE.md) for the benchmark
gate, and `API_MANIFEST.csv` for the complete upstream inventory.
