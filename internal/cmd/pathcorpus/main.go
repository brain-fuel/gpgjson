package main

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	if len(os.Args) != 3 {
		panic("usage: pathcorpus UPSTREAM_ROOT OUTPUT.csv")
	}
	upstream, err := filepath.Abs(os.Args[1])
	must(err)
	output, err := filepath.Abs(os.Args[2])
	must(err)

	temporary, err := os.MkdirTemp("", "gjson-path-corpus-*")
	must(err)
	defer os.RemoveAll(temporary)
	must(copyModule(upstream, temporary))
	must(instrument(filepath.Join(temporary, "gjson.go")))
	tests, err := deterministicTests(filepath.Join(temporary, "gjson_test.go"))
	must(err)
	must(os.WriteFile(filepath.Join(temporary, "corpus_hook_test.go"), []byte(hookSource), 0o644))

	command := exec.Command("go", "test", "-count=1", "-run", "^("+strings.Join(tests, "|")+")$")
	command.Dir = temporary
	command.Env = append(os.Environ(), "GOFORGE_CORPUS_OUTPUT="+output)
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	must(command.Run())
	fmt.Printf("recorded deterministic upstream corpus from %d tests\n", len(tests))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func copyModule(source, destination string) error {
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(source, entry.Name()))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(destination, entry.Name()), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}

func instrument(filename string) error {
	source, err := os.ReadFile(filename)
	if err != nil {
		return err
	}
	replacements := map[string]string{
		"func (t Result) Get(path string) Result {":                 "func (t Result) Get(path string) Result {\n\trecordCorpus(t.Raw, path)",
		"func Get(json, path string) Result {":                      "func Get(json, path string) Result {\n\trecordCorpus(json, path)",
		"func GetBytes(json []byte, path string) Result {":          "func GetBytes(json []byte, path string) Result {\n\trecordCorpus(string(json), path)",
		"func GetMany(json string, path ...string) []Result {":      "func GetMany(json string, path ...string) []Result {\n\tfor _, item := range path { recordCorpus(json, item) }",
		"func GetManyBytes(json []byte, path ...string) []Result {": "func GetManyBytes(json []byte, path ...string) []Result {\n\tfor _, item := range path { recordCorpus(string(json), item) }",
	}
	for before, after := range replacements {
		if bytes.Count(source, []byte(before)) != 1 {
			return fmt.Errorf("instrumentation anchor %q did not occur exactly once", before)
		}
		source = bytes.Replace(source, []byte(before), []byte(after), 1)
	}
	return os.WriteFile(filename, source, 0o644)
}

func deterministicTests(filename string) ([]string, error) {
	file, err := parser.ParseFile(token.NewFileSet(), filename, nil, 0)
	if err != nil {
		return nil, err
	}
	var tests []string
	for _, declaration := range file.Decls {
		function, ok := declaration.(*ast.FuncDecl)
		if !ok || !strings.HasPrefix(function.Name.Name, "Test") ||
			strings.Contains(function.Name.Name, "Random") {
			continue
		}
		tests = append(tests, function.Name.Name)
	}
	sort.Strings(tests)
	return tests, nil
}

const hookSource = `package gjson

import (
	"encoding/base64"
	"fmt"
	"os"
	"sort"
	"sync"
	"testing"
)

var corpusMu sync.Mutex
var corpus = map[string][2]string{}

func recordCorpus(source, path string) {
	if len(source) > 1<<20 || len(path) > 1<<16 {
		return
	}
	key := source + "\x00" + path
	corpusMu.Lock()
	corpus[key] = [2]string{source, path}
	corpusMu.Unlock()
}

func TestMain(m *testing.M) {
	code := m.Run()
	if code == 0 {
		keys := make([]string, 0, len(corpus))
		for key := range corpus {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		output, err := os.Create(os.Getenv("GOFORGE_CORPUS_OUTPUT"))
		if err != nil {
			panic(err)
		}
		fmt.Fprintln(output, "source_base64,path_base64")
		for _, key := range keys {
			item := corpus[key]
			fmt.Fprintf(output, "%s,%s\n",
				base64.StdEncoding.EncodeToString([]byte(item[0])),
				base64.StdEncoding.EncodeToString([]byte(item[1])))
		}
		if err := output.Close(); err != nil {
			panic(err)
		}
	}
	os.Exit(code)
}
`
