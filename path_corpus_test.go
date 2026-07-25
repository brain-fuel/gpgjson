package gjson_test

import (
	"encoding/base64"
	"encoding/csv"
	"fmt"
	"io"
	"math"
	"os"
	"testing"

	upstream "github.com/tidwall/gjson"
	forge "goforge.dev/gpgjson"
)

const pathCorpusJSON = `{
	"plain":1,
	"a.b":{"x":2},
	"wild":{"alpha":3,"alpine":4,"beta":5,"*":6},
	"items":[
		{"name":"Ada","age":37,"active":true,"tags":["go","math"]},
		{"name":"Lin","age":29,"active":false,"tags":["systems"]},
		null
	],
	"nested":{"items":[{"name":"Nia"}]},
	"empty":[],"nothing":null
}`

func TestPinnedUpstreamPathCorpus(t *testing.T) {
	gaps := readPathPairs(t, "UPSTREAM_PATH_GAPS.csv")
	file, err := os.Open("UPSTREAM_PATH_CORPUS.csv")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	reader := csv.NewReader(file)
	header, err := reader.Read()
	if err != nil || len(header) != 2 ||
		header[0] != "source_base64" || header[1] != "path_base64" {
		t.Fatalf("invalid corpus header %q: %v", header, err)
	}
	count := 0
	mismatches := 0
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		sourceBytes, sourceErr := base64.StdEncoding.DecodeString(record[0])
		pathBytes, pathErr := base64.StdEncoding.DecodeString(record[1])
		if sourceErr != nil || pathErr != nil {
			t.Fatalf("row %d base64: source=%v path=%v", count+2, sourceErr, pathErr)
		}
		source, path := string(sourceBytes), string(pathBytes)
		key := source + "\x00" + path
		t.Run(fmt.Sprintf("%04d/%s", count, path), func(t *testing.T) {
			got, want := forge.Get(source, path), upstream.Get(source, path)
			equalNumber := got.Num == want.Num ||
				math.IsNaN(got.Num) && math.IsNaN(want.Num)
			equal := got.Type == forge.Type(want.Type) && got.Raw == want.Raw &&
				got.Str == want.Str && equalNumber && got.Index == want.Index &&
				equalIndexes(got.Indexes, want.Indexes)
			_, expectedGap := gaps[key]
			if !equal {
				mismatches++
			}
			if !equal && !expectedGap {
				t.Fatalf("source=%q path=%q:\nGoForge: %#v\nupstream: %#v",
					source, path, got, want)
			}
			if equal && expectedGap {
				t.Fatalf("stale expected gap for source=%q path=%q", source, path)
			}
		})
		count++
	}
	if count != 1301 {
		t.Fatalf("corpus rows = %d, want pinned denominator 1301", count)
	}
	if mismatches != len(gaps) {
		t.Fatalf("observed %d mismatches, expected-gap manifest contains %d", mismatches, len(gaps))
	}
}

func readPathPairs(t *testing.T, filename string) map[string]struct{} {
	t.Helper()
	file, err := os.Open(filename)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	reader := csv.NewReader(file)
	header, err := reader.Read()
	if err != nil || len(header) != 2 ||
		header[0] != "source_base64" || header[1] != "path_base64" {
		t.Fatalf("invalid %s header %q: %v", filename, header, err)
	}
	pairs := make(map[string]struct{})
	for {
		record, err := reader.Read()
		if err == io.EOF {
			return pairs
		}
		if err != nil {
			t.Fatal(err)
		}
		source, sourceErr := base64.StdEncoding.DecodeString(record[0])
		path, pathErr := base64.StdEncoding.DecodeString(record[1])
		if sourceErr != nil || pathErr != nil {
			t.Fatalf("%s base64: source=%v path=%v", filename, sourceErr, pathErr)
		}
		key := string(source) + "\x00" + string(path)
		if _, duplicate := pairs[key]; duplicate {
			t.Fatalf("%s contains duplicate pair", filename)
		}
		pairs[key] = struct{}{}
	}
}

// TestPinnedPathGrammarMatrix is a deterministic, reviewable complement to
// the differential fuzzers. It crosses selectors with continuations and
// separators, and retains malformed delimiters/escapes instead of filtering
// them out. Every case is compared with the pinned upstream compatibility
// evaluator.
func TestPinnedPathGrammarMatrix(t *testing.T) {
	heads := []string{
		"plain", `a\.b`, "wild.a*", `wild.\*`, "items.0",
		"items.#", `items.#[age>=29]`, `items.#[active=true]#`,
		"items.#.name", "nested.items.#.name",
		`{value:plain,names:items.#.name}`, `[plain,items.0.name]`,
		"!true", `!{"value":7}`, "@this",
	}
	tails := []string{
		"", "name", "age", "#", "0", "missing", "@this",
		`#[age>30]`, `{name,age}`, `[name,age]`,
	}
	separators := []string{".", "|"}

	paths := make([]string, 0, len(heads)*(1+len(tails)*len(separators))+64)
	paths = append(paths, heads...)
	for _, head := range heads {
		for _, separator := range separators {
			for _, tail := range tails {
				if tail != "" {
					paths = append(paths, head+separator+tail)
				}
			}
		}
	}
	paths = append(paths,
		"", ".", "|", "..", "||", `\`, `plain\`,
		"items.{", "items.[",
		"items.#)", "items.#]", "items.}", "items.]",
		`items.#[name="Ada"]].name`, `items.#(age>30].name`,
		`{plain`, `[plain`, `{plain]`, `[plain}`,
		`!{"value":7`, `![1,2`, `!"unterminated`,
		"@pretty:{", "@this|", "@this.", ".{plain}", ".[plain]",
	)

	seen := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		if _, duplicate := seen[path]; duplicate {
			continue
		}
		seen[path] = struct{}{}
		t.Run(pathName(path), func(t *testing.T) {
			assertPathResultEqual(t, path, forge.Get(pathCorpusJSON, path), upstream.Get(pathCorpusJSON, path))
		})
	}

	// Provenance is part of Result's public contract. These cases exercise
	// direct source offsets, modifier/pipe resets, and projection child
	// offsets separately from the broad value matrix.
	for _, path := range []string{
		"plain", "plain.@this", "items.0|name", "items.#.name",
		"items.#[active=true]#.{name,age}",
	} {
		t.Run("provenance/"+path, func(t *testing.T) {
			got, want := forge.Get(pathCorpusJSON, path), upstream.Get(pathCorpusJSON, path)
			if got.Index != want.Index || !equalIndexes(got.Indexes, want.Indexes) {
				t.Fatalf("path %q provenance: GoForge=%#v upstream=%#v", path, got, want)
			}
		})
	}
}

func pathName(path string) string {
	if path == "" {
		return "empty"
	}
	return path
}

func assertPathResultEqual(t *testing.T, path string, got forge.Result, want upstream.Result) {
	t.Helper()
	equalNumber := got.Num == want.Num || math.IsNaN(got.Num) && math.IsNaN(want.Num)
	if got.Type != forge.Type(want.Type) || got.Raw != want.Raw ||
		got.Str != want.Str || !equalNumber {
		t.Fatalf("path %q:\nGoForge: %#v\nupstream: %#v", path, got, want)
	}
}

func equalIndexes(left, right []int) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
