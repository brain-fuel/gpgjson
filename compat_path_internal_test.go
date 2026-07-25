package gjson

import "testing"

func TestCompatibilityPathSplitterPreservesNestedSyntax(t *testing.T) {
	path := `!{"name":{"first":"Tom"}}.{name.first}.first`
	parts, ok := splitCompatibilityPath(path)
	if !ok {
		t.Fatal("split rejected valid nested syntax")
	}
	want := []string{`!{"name":{"first":"Tom"}}`, `{name.first}`, "first"}
	if len(parts) != len(want) {
		t.Fatalf("parts = %#v", parts)
	}
	for index := range want {
		if parts[index].text != want[index] {
			t.Errorf("part %d = %q, want %q", index, parts[index].text, want[index])
		}
	}
	result := compatibilityGet(`{"unused":true}`, path)
	if result.String() != "Tom" {
		t.Fatalf("evaluation = %#v", result)
	}
}

func TestCompatibilityEscapedMultipathEntry(t *testing.T) {
	path := `{\"}`
	parts, ok := splitCompatibilityPath(path)
	if !ok {
		t.Fatalf("split rejected %q", path)
	}
	result := compatibilityGet(`{"value":1}`, path)
	if result.Raw != "{}" {
		t.Fatalf("parts=%#v result=%#v", parts, result)
	}
}
