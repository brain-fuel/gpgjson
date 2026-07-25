// Go+ modifier semantics.
package gjson

import (
	"fmt"
	"strings"

	"github.com/tidwall/pretty"
)

// Modifier is an explicit transformation over JSON text.
type Modifier func(json, argument string) (string, error)

// Registry is an immutable modifier registry. With returns a fresh snapshot;
// query behavior never depends on process-global mutation.
type Registry struct{ modifiers map[string]Modifier }

func NewRegistry() Registry { return Registry{modifiers: map[string]Modifier{}} }
func (r Registry) With(name string, modifier Modifier) (Registry, error) {
	if name == "" {
		return r, fmt.Errorf("gjson: empty modifier name")
	}
	if modifier == nil {
		return r, fmt.Errorf("gjson: nil modifier %q", name)
	}
	next := make(map[string]Modifier, len(r.modifiers)+1)
	for key, value := range r.modifiers {
		next[key] = value
	}
	next[name] = modifier
	return Registry{modifiers: next}, nil
}
func (r Registry) Exists(name string) bool { _, ok := r.modifiers[name]; return ok }
func (r Registry) Apply(name, json, argument string) (string, error) {
	modifier, ok := r.modifiers[name]
	if !ok {
		return "", fmt.Errorf("gjson: unknown modifier %q", name)
	}
	return modifier(json, argument)
}

func init() {
	compatibilityModifiers["pretty"] = compatibilityPretty
	compatibilityModifiers["ugly"] = func(json, _ string) string { return string(pretty.Ugly([]byte(json))) }
	compatibilityModifiers["reverse"] = compatibilityReverse
	compatibilityModifiers["this"] = func(json, _ string) string { return json }
	compatibilityModifiers["flatten"] = compatibilityFlatten
	compatibilityModifiers["join"] = compatibilityJoin
	compatibilityModifiers["valid"] = func(json, _ string) string {
		if Valid(json) {
			return json
		}
		return ""
	}
	compatibilityModifiers["keys"] = compatibilityKeys
	compatibilityModifiers["values"] = compatibilityValues
	compatibilityModifiers["tostr"] = func(json, _ string) string { return string(AppendJSONString(nil, json)) }
	compatibilityModifiers["fromstr"] = func(json, _ string) string {
		if !Valid(json) {
			return ""
		}
		return Parse(json).String()
	}
	compatibilityModifiers["group"] = compatibilityGroup
	compatibilityModifiers["dig"] = compatibilityDig
}

func compatibilityPretty(json, argument string) string {
	if argument == "" {
		return string(pretty.Pretty([]byte(json)))
	}
	options := *pretty.DefaultOptions
	Parse(argument).ForEach(func(key, value Result) bool {
		switch key.String() {
		case "sortKeys":
			options.SortKeys = value.Bool()
		case "indent":
			options.Indent = compatibilityWhitespace(value.String())
		case "prefix":
			options.Prefix = compatibilityWhitespace(value.String())
		case "width":
			options.Width = int(value.Int())
		}
		return true
	})
	return string(pretty.PrettyOptions([]byte(json), &options))
}

func compatibilityWhitespace(value string) string {
	return strings.Map(func(value rune) rune {
		if value == ' ' || value == '\t' || value == '\n' || value == '\r' {
			return value
		}
		return -1
	}, value)
}

func compatibilityReverse(json, _ string) string {
	result := Parse(json)
	if !result.IsArray() && !result.IsObject() {
		return json
	}
	type pair struct{ key, value Result }
	pairs := []pair{}
	result.ForEach(func(key, value Result) bool {
		pairs = append(pairs, pair{key: key, value: value})
		return true
	})
	raw := []byte{'['}
	if result.IsObject() {
		raw[0] = '{'
	}
	for index := len(pairs) - 1; index >= 0; index-- {
		if index != len(pairs)-1 {
			raw = append(raw, ',')
		}
		if result.IsObject() {
			raw = append(raw, pairs[index].key.Raw...)
			raw = append(raw, ':')
		}
		raw = append(raw, pairs[index].value.Raw...)
	}
	if result.IsObject() {
		raw = append(raw, '}')
	} else {
		raw = append(raw, ']')
	}
	return string(raw)
}

func compatibilityFlatten(json, argument string) string {
	result := Parse(json)
	if !result.IsArray() {
		return json
	}
	deep := Get(argument, "deep").Bool()
	raw := []byte{'['}
	wrote := 0
	var appendValue func(Result)
	appendValue = func(value Result) {
		if value.IsArray() {
			for _, nested := range value.Array() {
				if deep && nested.IsArray() {
					appendValue(nested)
				} else {
					if wrote > 0 {
						raw = append(raw, ',')
					}
					raw = append(raw, nested.Raw...)
					wrote++
				}
			}
			return
		}
		if wrote > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, value.Raw...)
		wrote++
	}
	for _, value := range result.Array() {
		appendValue(value)
	}
	raw = append(raw, ']')
	return string(raw)
}

func compatibilityKeys(json, _ string) string {
	result := Parse(json)
	if !result.Exists() {
		return "[]"
	}
	raw := []byte{'['}
	index := 0
	result.ForEach(func(key, _ Result) bool {
		if index > 0 {
			raw = append(raw, ',')
		}
		if result.IsObject() {
			raw = append(raw, key.Raw...)
		} else {
			raw = append(raw, "null"...)
		}
		index++
		return true
	})
	raw = append(raw, ']')
	return string(raw)
}

func compatibilityValues(json, _ string) string {
	result := Parse(json)
	if !result.Exists() {
		return "[]"
	}
	if result.IsArray() {
		return json
	}
	raw := []byte{'['}
	index := 0
	result.ForEach(func(_ Result, value Result) bool {
		if index > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, value.Raw...)
		index++
		return true
	})
	raw = append(raw, ']')
	return string(raw)
}

func compatibilityJoin(json, argument string) string {
	result := Parse(json)
	if !result.IsArray() {
		return json
	}
	preserve := Get(argument, "preserve").Bool()
	type pair struct{ key, value Result }
	order := []string{}
	keys := map[string]Result{}
	values := map[string]Result{}
	all := []pair{}
	for _, object := range result.Array() {
		if !object.IsObject() {
			continue
		}
		object.ForEach(func(key, value Result) bool {
			if preserve {
				all = append(all, pair{key: key, value: value})
			} else {
				if _, exists := keys[key.Str]; !exists {
					order = append(order, key.Str)
					keys[key.Str] = key
				}
				values[key.Str] = value
			}
			return true
		})
	}
	if !preserve {
		for _, key := range order {
			all = append(all, pair{key: keys[key], value: values[key]})
		}
	}
	raw := []byte{'{'}
	for index, item := range all {
		if index > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, item.key.Raw...)
		raw = append(raw, ':')
		raw = append(raw, item.value.Raw...)
	}
	raw = append(raw, '}')
	return string(raw)
}

func compatibilityGroup(json, _ string) string {
	result := Parse(json)
	if !result.IsObject() {
		return ""
	}
	rows := [][]byte{}
	result.ForEach(func(key, value Result) bool {
		if !value.IsArray() {
			return true
		}
		for index, item := range value.Array() {
			for len(rows) <= index {
				rows = append(rows, nil)
			}
			if len(rows[index]) > 0 {
				rows[index] = append(rows[index], ',')
			}
			rows[index] = append(rows[index], key.Raw...)
			rows[index] = append(rows[index], ':')
			rows[index] = append(rows[index], item.Raw...)
		}
		return true
	})
	raw := []byte{'['}
	for index, row := range rows {
		if index > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, '{')
		raw = append(raw, row...)
		raw = append(raw, '}')
	}
	raw = append(raw, ']')
	return string(raw)
}

func compatibilityDig(json, argument string) string {
	results := []Result{}
	var visit func(Result)
	visit = func(parent Result) {
		if result := compatibilityGet(parent.Raw, argument); result.Exists() {
			results = append(results, result)
		}
		if parent.IsArray() || parent.IsObject() {
			parent.ForEach(func(_ Result, child Result) bool {
				visit(child)
				return true
			})
		}
	}
	visit(Parse(json))
	raw := []byte{'['}
	for index, result := range results {
		if index > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, result.Raw...)
	}
	raw = append(raw, ']')
	return string(raw)
}
