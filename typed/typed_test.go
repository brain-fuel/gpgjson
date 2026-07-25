package typed

import "testing"

func TestPresenceIndexedElimination(t *testing.T) {
	present := Present[int]{Value: 42}
	if got := PresentValue[int](present); got != 42 {
		t.Fatalf("got %d", got)
	}
	var lookup SomeLookup[int] = PresentLookup[int]{Result: present}
	if _, ok := lookup.(PresentLookup[int]); !ok {
		t.Fatalf("got %T", lookup)
	}
}

func TestSchemaPathComposition(t *testing.T) {
	prefix := NewPath[int](8, []Segment{Field{Name: "user"}}, ObjectKind{})
	suffix := NewPath[string](8, []Segment{Field{Name: "name"}}, StringKind{})
	composed := Compose[int, string](prefix, suffix)
	segments := Segments[string](composed)
	if len(segments) != 2 {
		t.Fatalf("segments %d", len(segments))
	}
	segments[0] = Field{Name: "mutated"}
	if original := Segments[string](composed)[0].(Field).Name; original != "user" {
		t.Fatalf("path aliased caller: %q", original)
	}
}

func TestSchemaBoundDocument(t *testing.T) {
	document := BindDocument[string](8, "json")
	if got := DocumentValue[string](document); got != "json" {
		t.Fatalf("got %q", got)
	}
}
