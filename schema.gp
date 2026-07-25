package gjson

import "goforge.dev/gpgjson/typed"

// ParseTypedPath is the existential boundary for runtime path strings. The
// schema identity remains in the result index while exhaustive matching
// recovers the requested leaf type.
func ParseTypedPath(schema nat, source string, kind typed.ValueKind) typed.PathParse[schema] {
	segments, err := parseTypedSegments(source)
	if err != nil { return typed.PathRejected(typed.PathError{Message: err.Error()}) }
	match kind {
	case typed.BooleanKind(): return typed.PathParsed(typed.SomeBooleanPath(typed.NewPath[bool](schema, segments, kind)))
	case typed.IntegerKind(): return typed.PathParsed(typed.SomeIntegerPath(typed.NewPath[int](schema, segments, kind)))
	case typed.NumberKind(): return typed.PathParsed(typed.SomeNumberPath(typed.NewPath[typed.NumberText](schema, segments, kind)))
	case typed.StringKind(): return typed.PathParsed(typed.SomeStringPath(typed.NewPath[typed.StringView](schema, segments, kind)))
	case typed.ObjectKind(): return typed.PathRejected(typed.PathError{Message: "object paths are deferred from typed tier 1"})
	case typed.ArrayKind(): return typed.PathRejected(typed.PathError{Message: "array paths are deferred from typed tier 1"})
	}
}

func BindJSONDocument(schema nat, document Document) typed.TypedDocument[schema, Document] {
	return typed.BindDocument(schema, document)
}

func BindCBORDocument(schema nat, document []byte) typed.TypedDocument[schema, []byte] {
	owned := append([]byte(nil), document...)
	return typed.BindDocument(schema, owned)
}

func LookupInteger(0 schema nat, path typed.Path[schema, int], document typed.TypedDocument[schema, Document]) typed.SomeLookup[int] {
	return lookupTypedInteger(typed.OpenDocument(path, document), typed.Key(path))
}

func LookupBoolean(0 schema nat, path typed.Path[schema, bool], document typed.TypedDocument[schema, Document]) typed.SomeLookup[bool] {
	return lookupTypedBoolean(typed.OpenDocument(path, document), typed.Key(path))
}

func LookupString(0 schema nat, path typed.Path[schema, typed.StringView], document typed.TypedDocument[schema, Document]) typed.SomeLookup[typed.StringView] {
	return lookupTypedString(typed.OpenDocument(path, document), typed.Key(path))
}

// LookupStringInto is the unboxed hot-path eliminator. It retains the same
// schema equality obligation and writes only for ValueState.
func LookupStringInto(0 schema nat, path typed.Path[schema, typed.StringView], document typed.TypedDocument[schema, Document], destination *typed.StringView) State {
	return lookupTypedStringInto(typed.OpenDocument(path, document), typed.Key(path), destination)
}

func LookupNumber(0 schema nat, path typed.Path[schema, typed.NumberText], document typed.TypedDocument[schema, Document]) typed.SomeLookup[typed.NumberText] {
	return lookupTypedNumber(typed.OpenDocument(path, document), typed.Key(path))
}

// LookupCBORInteger is the second-format consumer of Path[S,T]. It preserves
// the same schema index while the format-specific traversal remains outside
// the prospective shared standard abstraction.
func LookupCBORInteger(0 schema nat, path typed.Path[schema, int], document typed.TypedDocument[schema, []byte]) typed.SomeLookup[int] {
	return lookupCBORInteger(typed.OpenDocument(path, document), typed.Segments(path))
}
