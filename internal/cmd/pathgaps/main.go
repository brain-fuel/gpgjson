package main

import (
	"encoding/base64"
	"encoding/csv"
	"fmt"
	"io"
	"math"
	"os"

	upstream "github.com/tidwall/gjson"
	forge "goforge.dev/gpgjson"
)

func main() {
	if len(os.Args) != 3 {
		panic("usage: pathgaps CORPUS.csv GAPS.csv")
	}
	input, err := os.Open(os.Args[1])
	must(err)
	defer input.Close()

	reader := csv.NewReader(input)
	header, err := reader.Read()
	must(err)
	if len(header) != 2 || header[0] != "source_base64" || header[1] != "path_base64" {
		panic(fmt.Sprintf("invalid corpus header %q", header))
	}

	output, err := os.Create(os.Args[2])
	must(err)
	writer := csv.NewWriter(output)
	must(writer.Write(header))

	rows, gaps := 0, 0
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		must(err)
		source, err := base64.StdEncoding.DecodeString(record[0])
		must(err)
		path, err := base64.StdEncoding.DecodeString(record[1])
		must(err)
		got := forge.Get(string(source), string(path))
		want := upstream.Get(string(source), string(path))
		if !equal(got, want) {
			must(writer.Write(record))
			fmt.Printf("%04d %q\n", rows, string(path))
			if os.Getenv("GOFORGE_GAP_DETAILS") != "" {
				fmt.Printf("  source: %q\n  GoForge: %#v\n  upstream: %#v\n",
					string(source), got, want)
			}
			gaps++
		}
		rows++
	}
	writer.Flush()
	must(writer.Error())
	must(output.Close())
	fmt.Printf("recorded %d gaps from %d pinned corpus rows\n", gaps, rows)
}

func equal(got forge.Result, want upstream.Result) bool {
	return got.Type == forge.Type(want.Type) &&
		got.Raw == want.Raw &&
		got.Str == want.Str &&
		(got.Num == want.Num || math.IsNaN(got.Num) && math.IsNaN(want.Num)) &&
		got.Index == want.Index &&
		equalIndexes(got.Indexes, want.Indexes)
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

func must(err error) {
	if err != nil {
		panic(err)
	}
}
