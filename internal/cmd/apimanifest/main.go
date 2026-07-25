// Command apimanifest inventories the pinned tidwall/gjson API.
package main

import (
	"encoding/csv"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type symbol struct{ kind, name, file string }

var compatible = map[string]bool{"Type": true, "Result": true, "Null": true, "False": true, "Number": true, "String": true, "True": true, "JSON": true, "Parse": true, "ParseBytes": true, "Get": true, "GetBytes": true, "GetMany": true, "GetManyBytes": true, "Valid": true, "ValidBytes": true, "Escape": true, "AppendJSONString": true, "DisableEscapeHTML": true, "ForEachLine": true, "AddModifier": true, "ModifierExists": true, "DisableModifiers": true, "Type.String": true, "Result.String": true, "Result.Bool": true, "Result.Int": true, "Result.Uint": true, "Result.Float": true, "Result.Exists": true, "Result.IsArray": true, "Result.IsObject": true, "Result.All": true, "Result.Array": true, "Result.ForEach": true, "Result.Get": true, "Result.IsBool": true, "Result.Keys": true, "Result.Less": true, "Result.Map": true, "Result.Path": true, "Result.Paths": true, "Result.Time": true, "Result.Value": true, "Result.Values": true}

func main() {
	if len(os.Args) != 3 {
		panic("usage: apimanifest UPSTREAM_ROOT OUTPUT.csv")
	}
	root, output := os.Args[1], os.Args[2]
	fset := token.NewFileSet()
	var symbols []symbol
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == ".git" || entry.Name() == "internal" || entry.Name() == "vendor" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		add := func(kind, name string) {
			base := name
			if dot := strings.LastIndexByte(base, '.'); dot >= 0 {
				base = base[dot+1:]
			}
			if ast.IsExported(base) {
				symbols = append(symbols, symbol{kind, name, filepath.Base(path)})
			}
		}
		for _, decl := range file.Decls {
			switch d := decl.(type) {
			case *ast.FuncDecl:
				if d.Recv == nil {
					add("func", d.Name.Name)
				} else {
					add("method", receiver(d.Recv.List[0].Type)+"."+d.Name.Name)
				}
			case *ast.GenDecl:
				for _, raw := range d.Specs {
					switch spec := raw.(type) {
					case *ast.TypeSpec:
						add("type", spec.Name.Name)
					case *ast.ValueSpec:
						for _, name := range spec.Names {
							add(strings.ToLower(d.Tok.String()), name.Name)
						}
					}
				}
			}
		}
		return nil
	})
	if err != nil {
		panic(err)
	}
	sort.Slice(symbols, func(i, j int) bool {
		if symbols[i].name != symbols[j].name {
			return symbols[i].name < symbols[j].name
		}
		return symbols[i].kind < symbols[j].kind
	})
	file, err := os.Create(output)
	if err != nil {
		panic(err)
	}
	defer file.Close()
	writer := csv.NewWriter(file)
	defer writer.Flush()
	_ = writer.Write([]string{"package", "kind", "symbol", "source", "status", "destination_or_reason"})
	seen := map[string]bool{}
	for _, item := range symbols {
		key := item.kind + "|" + item.name
		if seen[key] {
			continue
		}
		seen[key] = true
		status, reason := "deferred", "outside compatibility tier 1"
		if compatible[item.name] {
			status, reason = "compatible", "goforge.dev/gpgjson"
		}
		if err := writer.Write([]string{"root", item.kind, item.name, item.file, status, reason}); err != nil {
			panic(err)
		}
	}
	if err := writer.Error(); err != nil {
		panic(err)
	}
	fmt.Fprintf(os.Stderr, "wrote %d unique exported declarations\n", len(seen))
}
func receiver(expr ast.Expr) string {
	switch x := expr.(type) {
	case *ast.Ident:
		return x.Name
	case *ast.StarExpr:
		return receiver(x.X)
	case *ast.IndexExpr:
		return receiver(x.X)
	}
	return "?"
}
