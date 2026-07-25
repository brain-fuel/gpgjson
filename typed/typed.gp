// Package typed is the checked schema/path core for GoForge JSON paths.
package typed

import (
	"strconv"
	"strings"
)

type Segment enum {
	Field(Name string)
	Index(Position int)
}

type ValueKind enum {
	BooleanKind()
	IntegerKind()
	NumberKind()
	StringKind()
	ObjectKind()
	ArrayKind()
}

// NumberText retains the exact JSON decimal spelling. Conversion to a lossy
// floating representation is deliberately outside the checked core.
type NumberText struct { Raw string }
type StringView struct { Raw string; Content string; Escaped bool }

// Path[S,T] ties a path result T to schema identity S. The constructor is
// sealed so unrelated schema paths cannot be forged in Go+.
//goplus:derive off
type Path[S nat, T any] enum {
	pathValue(Schema int, Segments []Segment, Key string, Kind ValueKind) Path[S, T]
}

// TypedDocument[S,D] binds a format-specific immutable document D to schema S.
//goplus:derive off
type TypedDocument[S nat, D any] enum {
	documentValue(Schema int, Payload D) TypedDocument[S, D]
}

type PathError struct { Message string }
func (e PathError) Error() string { return e.Message }

// Lookup[T,p] indexes the four exhaustive lookup states. The finite
// SomeLookup boundary hides p until exhaustive matching recovers it.
type Lookup[T any, p nat] enum {
	Missing() Lookup[T, 0]
	Null() Lookup[T, 1]
	Present(Value T) Lookup[T, 2]
	Malformed(Error PathError) Lookup[T, 3]
}

type SomeLookup[T any] enum {
	MissingLookup(Result Lookup[T, 0])
	NullLookup(Result Lookup[T, 1])
	PresentLookup(Result Lookup[T, 2])
	MalformedLookup(Result Lookup[T, 3])
}

// SomePath[S] hides the leaf result type T while retaining the document schema
// index. Matching a variant recovers the concrete Path[S,T].
type SomePath[S nat] enum {
	SomeBooleanPath(Path Path[S, bool])
	SomeIntegerPath(Path Path[S, int])
	SomeNumberPath(Path Path[S, NumberText])
	SomeStringPath(Path Path[S, StringView])
}

type PathParse[S nat] enum {
	PathParsed(Path SomePath[S])
	PathRejected(Error PathError)
}

// PresentValue requires p=2 statically; missing, null, and malformed values
// cannot reach this function in Go+.
func PresentValue[T any](value Lookup[T, 2]) T {
	match value { case Present(result): return result }
}

// NewPath is the checked construction boundary. Schema IDs survive erasure for
// defensive ordinary-Go boundary checks.
func NewPath[T any](schema nat, segments []Segment, kind ValueKind) Path[schema, T] {
	if schema < 0 { panic("gjson/typed: negative schema") }
	owned := append([]Segment(nil), segments...)
	return pathValue(int(schema), owned, pathKey(owned), kind)
}

func BindDocument[D any](schema nat, document D) TypedDocument[schema, D] {
	if schema < 0 { panic("gjson/typed: negative schema") }
	return documentValue(int(schema), document)
}

func DocumentValue[D any](0 schema nat, document TypedDocument[schema, D]) D {
	match document { case documentValue(_, payload): return payload }
}

// OpenDocument validates the retained schema witnesses after Go erasure.
func OpenDocument[T any, D any](0 schema nat, path Path[schema, T], document TypedDocument[schema, D]) D {
	match path {
	case pathValue(pathSchema, _, _, _):
		match document {
		case documentValue(documentSchema, payload):
			if pathSchema != documentSchema { panic("gjson/typed: erased path/document schema mismatch") }
			return payload
		}
	}
}

func Segments[T any](0 schema nat, path Path[schema, T]) []Segment {
	match path { case pathValue(_, segments, _, _): return append([]Segment(nil), segments...) }
}

func Kind[T any](0 schema nat, path Path[schema, T]) ValueKind {
	match path { case pathValue(_, _, _, kind): return kind }
}

func Key[T any](0 schema nat, path Path[schema, T]) string {
	match path { case pathValue(_, _, key, _): return key }
}

// Compose preserves the document schema index while appending an immutable
// suffix. The result type is determined by the suffix path.
func Compose[A any, B any](0 schema nat, prefix Path[schema, A], suffix Path[schema, B]) Path[schema, B] {
	match prefix {
	case pathValue(prefixSchema, left, _, _):
		match suffix {
		case pathValue(suffixSchema, right, _, kind):
			if prefixSchema != suffixSchema { panic("gjson/typed: erased schema mismatch") }
			segments := append(append([]Segment(nil), left...), right...)
			return pathValue(prefixSchema, segments, pathKey(segments), kind)
		}
	}
}

func pathKey(segments []Segment) string {
	var builder strings.Builder
	for i, segment := range segments {
		if i > 0 { builder.WriteByte('.') }
		match segment {
		case Field(name):
			for j := 0; j < len(name); j++ { if name[j] == '.' || name[j] == '\\' { builder.WriteByte('\\') }; builder.WriteByte(name[j]) }
		case Index(position): builder.WriteString(strconv.Itoa(position))
		}
	}
	return builder.String()
}
