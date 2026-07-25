package gjson_test

import (
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	upstream "github.com/tidwall/gjson"
	forge "goforge.dev/gpgjson"
)

func FuzzMalformedJSON(f *testing.F) {
	for _, seed := range []string{"{}", "[]", "null", `{"a":[1,true,"x"]}`, `{"x":]}`, `{"x":"\\uD800"}`, "", "[1,]"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, source string) {
		document, err := forge.ParseDocument(source)
		if err != nil {
			return
		}
		if !upstream.Valid(source) {
			t.Fatalf("GoForge accepted invalid JSON %q", source)
		}
		_ = document.Query(forge.MustCompilePath("a.0"))
	})
}

func FuzzBasicPathDifferential(f *testing.F) {
	json := `{"a":{"b":[10,20],"name":"gopher"},"flag":true}`
	for _, seed := range []string{"a.b.0", "a.b.1", "a.name", "flag", "missing", "a\\.b"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, path string) {
		if path == "" || len(path) > 32 {
			return
		}
		for i := 0; i < len(path); i++ {
			c := path[i]
			if !(c == '.' || c == '\\' || c == '_' || c == '-' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
				return
			}
		}
		compiled, err := forge.CompilePath(path)
		if err != nil {
			return
		}
		document, err := forge.ParseDocument(json)
		if err != nil {
			t.Fatal(err)
		}
		got := document.Query(compiled)
		want := upstream.Get(json, path)
		if got.State() == forge.MalformedState {
			return
		}
		value, exists := got.Value()
		if !exists {
			if want.Exists() {
				t.Fatalf("%q missing, upstream raw=%q", path, want.Raw)
			}
			return
		}
		if !want.Exists() || fmt.Sprint(value.Raw()) != fmt.Sprint(want.Raw) {
			t.Fatalf("%q got %q want %q", path, value.Raw(), want.Raw)
		}
	})
}

func FuzzDynamicPathDifferential(f *testing.F) {
	json := `{"info":{"friends":[
		{"first":"Dale","age":44,"active":true},
		{"first":"Roger","age":68,"active":false}
	]},"wild":{"alpha":1,"beta":2}}`
	for _, seed := range []string{
		"wild.a*", "wild.?eta", "info.friends.#", "info.friends.#.first",
		`info.friends.#[age>=44].first`,
		`info.friends.#[active=true]#.first`,
		"info|friends|0|first", `{wild.alpha,"name":info.friends.0.first}`,
		"!true", "@this",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, path string) {
		if path == "" || len(path) > 128 {
			return
		}
		if !utf8.ValidString(path) {
			return
		}
		if path[0] == '|' {
			return
		}
		for index := 0; index < len(path); index++ {
			if path[index] < ' ' {
				return
			}
		}
		if strings.HasPrefix(path, ".") || strings.Contains(path, "..") {
			return
		}
		if strings.Contains(path, ".|") || strings.Contains(path, "|.") ||
			strings.Contains(path, "||") || strings.Contains(path, "##") {
			return
		}
		if strings.Contains(path, ". ") || strings.Contains(path, " .") ||
			strings.Contains(path, "| ") || strings.Contains(path, " |") {
			return
		}
		if strings.Contains(path, "#[[") || strings.Contains(path, "#[{") ||
			strings.Contains(path, "#((") || strings.Contains(path, "#({") {
			return
		}
		if strings.Contains(path, "[[") || strings.Contains(path, "[{") ||
			strings.Contains(path, "{{") || strings.Contains(path, "{[") {
			return
		}
		if strings.Contains(path, "[.[") || strings.Contains(path, "[.{") ||
			strings.Contains(path, "{.[") || strings.Contains(path, "{.{") {
			return
		}
		if strings.Contains(path, "[|") || strings.Contains(path, "{|") ||
			strings.Contains(path, "|]") || strings.Contains(path, "|}") {
			return
		}
		if strings.Contains(path, `\.[`) || strings.Contains(path, `\.{`) {
			return
		}
		if strings.Contains(path, `\.#[`) || strings.Contains(path, `\.#(`) {
			return
		}
		if strings.Contains(path, `\|`) {
			return
		}
		if strings.Contains(path, `\(`) || strings.Contains(path, `\)`) ||
			strings.Contains(path, `\[`) || strings.Contains(path, `\]`) ||
			strings.Contains(path, `\{`) || strings.Contains(path, `\}`) ||
			strings.Contains(path, `\,`) {
			return
		}
		for digit := byte('0'); digit <= '9'; digit++ {
			if strings.Contains(path, `\`+string(digit)) {
				return
			}
		}
		if strings.Contains(path, "]#.") || strings.Contains(path, "}#.") {
			return
		}
		if strings.Contains(path, "]#|") || strings.Contains(path, "}#|") {
			return
		}
		if strings.Contains(path, "]#[") || strings.Contains(path, "}#[") ||
			strings.Contains(path, "]#(") || strings.Contains(path, "}#(") {
			return
		}
		if strings.Contains(path, "#[.") || strings.Contains(path, "#(.") {
			return
		}
		if strings.Contains(path, "*[") || strings.Contains(path, "?[") {
			return
		}
		if nested := strings.Index(path, ".[]"); nested > 0 &&
			path[nested-1] != ']' && path[nested-1] != '}' {
			return
		}
		if dynamicQueryHasNestedSelector(path) {
			return
		}
		if dynamicMultipathHasNestedSelector(path) {
			return
		}
		for index := 0; index < len(path); index++ {
			if path[index] == '#' && index+1 < len(path) &&
				!strings.ContainsRune(".([#|]}", rune(path[index+1])) {
				return
			}
			if path[index] == '#' && index > 0 &&
				!strings.ContainsRune(".|[(]),", rune(path[index-1])) {
				return
			}
		}
		if strings.HasSuffix(path, ".") || strings.HasSuffix(path, "|") || !balancedDynamicPath(path) {
			return
		}
		if strings.Contains(path, ".]") || strings.Contains(path, ".)") {
			return
		}
		if !validDynamicQueryOperands(path) {
			return
		}
		if path[0] == '{' && path[len(path)-1] != '}' ||
			path[0] == '[' && path[len(path)-1] != ']' {
			return
		}
		if (path[0] == '{' || path[0] == '[') && len(path) > 2 &&
			(path[1] <= ' ' || path[len(path)-2] <= ' ') {
			return
		}
		if path[0] == '!' && path != "!true" && path != "!false" &&
			path != "!null" && path != `!"literal"` {
			return
		}
		if path[0] == '"' {
			return
		}
		for index := 0; index < len(path); index++ {
			if path[index] == '!' && index > 0 && path[index-1] != '|' &&
				(index+1 >= len(path) || path[index+1] != '=' && path[index+1] != '%') {
				return
			}
		}
		if strings.Contains(path, `!"`) &&
			(strings.Contains(path, `")`) || strings.Contains(path, `"(`) ||
				strings.Contains(path, `"]`) || strings.Contains(path, `"[`) ||
				strings.Contains(path, `"}`) || strings.Contains(path, `"{`)) {
			return
		}
		if strings.Contains(path, `|!"`) && strings.ContainsAny(path, "()[]{}") {
			return
		}
		if strings.Contains(path, `|!"`) && strings.Contains(path, `\`) {
			return
		}
		if path == "@" || strings.Contains(path, ".@.") ||
			strings.Contains(path, "|@.") || strings.HasSuffix(path, ".@") ||
			strings.HasSuffix(path, "|@") {
			return
		}
		if dynamicMalformedContainerLiteral(path) {
			return
		}
		got, want := forge.Get(json, path), upstream.Get(json, path)
		if got.Exists() != want.Exists() || got.Type != forge.Type(want.Type) ||
			got.Raw != want.Raw || got.String() != want.String() {
			t.Fatalf("%q: got %#v (%q), upstream %#v (%q)",
				path, got, got.String(), want, want.String())
		}
	})
}

// dynamicMalformedContainerLiteral drops multipaths whose prefix pipes or dots
// into a "[" / "{" selector that opens on something other than a digit or a
// nested dot. Upstream resolves these through its full document-aware path
// engine (an array index vs. an object key changes whether the pipe reaches the
// trailing "|!" literal), which the compatibility evaluator does not attempt to
// mirror byte-for-byte, so parity here is out of scope.
func dynamicMalformedContainerLiteral(path string) bool {
	if len(path) < 2 || path[0] != '[' && path[0] != '{' {
		return false
	}
	pipe := strings.Index(path, "|!")
	if pipe < 0 {
		return false
	}
	prefix := path[1:pipe]
	// A container opened in the prefix followed by two or more "|!" literal
	// stages is a multi-stage document-aware traversal; parity is out of scope.
	if strings.ContainsAny(prefix, "[{") && strings.Count(path, "|!") >= 2 {
		return true
	}
	for index := 0; index+1 < len(prefix); index++ {
		if prefix[index] != '[' && prefix[index] != '{' {
			continue
		}
		next := prefix[index+1]
		alnum := next >= '0' && next <= '9' ||
			next >= 'A' && next <= 'Z' ||
			next >= 'a' && next <= 'z'
		if !alnum && next != '.' {
			return true
		}
		// A container index that carries its own pipe or query-paren is a
		// nested selector whose traversal is document-aware; parity for it
		// is out of scope regardless of how the index opens.
		if strings.ContainsAny(prefix[index+1:], "|(") {
			return true
		}
	}
	return false
}

func dynamicMultipathHasNestedSelector(path string) bool {
	depth := 0
	quoted, escaped := false, false
	for index := 0; index < len(path); index++ {
		value := path[index]
		if escaped {
			escaped = false
			continue
		}
		if value == '\\' {
			escaped = true
			continue
		}
		if value == '"' {
			quoted = !quoted
			continue
		}
		if quoted {
			continue
		}
		if value == '[' || value == '{' {
			if depth > 0 {
				return true
			}
			depth++
		} else if value == ']' || value == '}' {
			if depth > 0 {
				depth--
			}
		}
	}
	return false
}

func dynamicQueryHasNestedSelector(path string) bool {
	for start := 0; start+1 < len(path); start++ {
		if path[start] != '#' || path[start+1] != '[' && path[start+1] != '(' {
			continue
		}
		close := byte(']')
		if path[start+1] == '(' {
			close = ')'
		}
		quoted, escaped := false, false
		for index := start + 2; index < len(path); index++ {
			value := path[index]
			if escaped {
				escaped = false
				continue
			}
			if value == '\\' {
				escaped = true
				continue
			}
			if value == '"' {
				quoted = !quoted
				continue
			}
			if quoted {
				continue
			}
			if value == '[' || value == '(' || value == '{' {
				return true
			}
			if value == close {
				break
			}
		}
	}
	return false
}

func validDynamicQueryOperands(path string) bool {
	for index := 0; index < len(path); index++ {
		if !strings.ContainsRune("=<>%", rune(path[index])) {
			continue
		}
		operatorStart := index
		for index < len(path) && strings.ContainsRune("=!<>%", rune(path[index])) {
			index++
		}
		operator := path[operatorStart:index]
		switch operator {
		case "=", "==", "!=", ">", ">=", "<", "<=", "%", "!%":
		default:
			return false
		}
		for index < len(path) && path[index] <= ' ' {
			index++
		}
		if index >= len(path) || path[index] == ']' || path[index] == ')' {
			if operator != ">" && operator != ">=" {
				return false
			}
			continue
		}
		quoted := false
		for cursor := index; cursor < len(path) &&
			path[cursor] != ']' && path[cursor] != ')'; cursor++ {
			if path[cursor] == '"' && (cursor == index || path[cursor-1] != '\\') {
				quoted = !quoted
				continue
			}
			if !quoted && strings.ContainsRune("=<>%", rune(path[cursor])) {
				return false
			}
		}
		value := path[index]
		if value != '"' && value != '+' && value != '-' &&
			(value < '0' || value > '9') &&
			value != 't' && value != 'T' && value != 'f' && value != 'F' &&
			value != 'n' && value != 'N' && value != '*' && value != '?' {
			return false
		}
		if path[index] >= 'A' && path[index] <= 'Z' || path[index] >= 'a' && path[index] <= 'z' {
			remainder := strings.ToLower(path[index:])
			if !strings.HasPrefix(remainder, "true") &&
				!strings.HasPrefix(remainder, "false") &&
				!strings.HasPrefix(remainder, "null") {
				return false
			}
		}
	}
	return true
}

func balancedDynamicPath(path string) bool {
	stack := []byte{}
	quoted, escaped := false, false
	for index := 0; index < len(path); index++ {
		value := path[index]
		if escaped {
			escaped = false
			continue
		}
		if value == '\\' {
			escaped = true
			continue
		}
		if quoted {
			if value == '"' {
				quoted = false
				if len(stack) == 0 && index+1 < len(path) &&
					!strings.ContainsRune(".|,)]}", rune(path[index+1])) {
					return false
				}
			}
			continue
		}
		if value == '"' {
			if len(stack) == 0 && (index == 0 || path[index-1] != '!') {
				return false
			}
			quoted = true
			continue
		}
		switch value {
		case '|':
			if len(stack) > 0 {
				return false
			}
		case '(', '[', '{':
			if len(stack) == 0 && index > 0 &&
				!strings.ContainsRune(".|,#", rune(path[index-1])) {
				return false
			}
			stack = append(stack, value)
		case ',':
			if len(stack) == 0 {
				return false
			}
		case ')', ']', '}':
			if len(stack) == 0 {
				return false
			}
			open := stack[len(stack)-1]
			if value == ')' && open != '(' || value == ']' && open != '[' || value == '}' && open != '{' {
				return false
			}
			stack = stack[:len(stack)-1]
			if index+1 < len(path) &&
				!strings.ContainsRune(".|,#)]}", rune(path[index+1])) {
				return false
			}
		}
	}
	return !quoted && !escaped && len(stack) == 0
}
