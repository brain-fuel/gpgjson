package gjson_test

import (
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"unsafe"

	upstream "github.com/tidwall/gjson"
	forge "goforge.dev/gpgjson"
	"goforge.dev/gpgjson/typed"
	"goforge.dev/goplus/std/cbor"
)

const sample = `{"meta":{"version":3},"users":[{"name":"Ada","active":true},{"name":"Go\u0070her\nTeam","active":false}],"count":9007199254740993,"nothing":null}`

func TestDifferentialBasicPathCorpus(t *testing.T) {
	t.Parallel()
	for _, path := range []string{"meta.version", "users.0.name", "users.0.active", "users.1.name", "count", "nothing", "missing"} {
		t.Run(path, func(t *testing.T) {
			got := forge.Get(sample, path)
			want := upstream.Get(sample, path)
			if got.Exists() != want.Exists() {
				t.Fatalf("Exists=%v want %v", got.Exists(), want.Exists())
			}
			if got.Exists() && got.Raw != want.Raw {
				t.Fatalf("Raw=%q want %q", got.Raw, want.Raw)
			}
		})
	}
}

func TestResultCollectionSurfaceDifferential(t *testing.T) {
	source := `{"when":"2026-07-23T12:34:56Z","items":[1,"two",true,null,{"x":3}],"dup":1,"dup":2}`
	got, want := forge.Parse(source), upstream.Parse(source)
	if got.Time() != want.Time() || got.IsBool() != want.IsBool() {
		t.Fatal("root scalar helpers differ")
	}
	gotItems, wantItems := got.Get("items"), want.Get("items")
	if gotItems.Index != wantItems.Index || gotItems.Raw != wantItems.Raw {
		t.Fatalf("Get = %#v, upstream %#v", gotItems, wantItems)
	}
	gotArray, wantArray := gotItems.Array(), wantItems.Array()
	if len(gotArray) != len(wantArray) {
		t.Fatalf("Array length = %d, upstream %d", len(gotArray), len(wantArray))
	}
	for i := range gotArray {
		if gotArray[i].Raw != wantArray[i].Raw ||
			gotArray[i].Index != wantArray[i].Index ||
			!reflect.DeepEqual(gotArray[i].Value(), wantArray[i].Value()) {
			t.Errorf("Array[%d] = %#v/%#v, upstream %#v/%#v",
				i, gotArray[i], gotArray[i].Value(), wantArray[i], wantArray[i].Value())
		}
	}
	gotMap, wantMap := got.Map(), want.Map()
	for _, key := range []string{"when", "items", "dup"} {
		if gotMap[key].Raw != wantMap[key].Raw || gotMap[key].Index != wantMap[key].Index {
			t.Errorf("Map[%q] = %#v, upstream %#v", key, gotMap[key], wantMap[key])
		}
	}

	var gotPairs, wantPairs []string
	got.ForEach(func(key, value forge.Result) bool {
		gotPairs = append(gotPairs, key.String()+"="+value.Raw)
		return true
	})
	want.ForEach(func(key, value upstream.Result) bool {
		wantPairs = append(wantPairs, key.String()+"="+value.Raw)
		return true
	})
	if !reflect.DeepEqual(gotPairs, wantPairs) {
		t.Errorf("ForEach = %#v, upstream %#v", gotPairs, wantPairs)
	}

	var gotKeys, gotValues []string
	for key := range got.Keys() {
		gotKeys = append(gotKeys, key.String())
	}
	for value := range got.Values() {
		gotValues = append(gotValues, value.Raw)
	}
	if !reflect.DeepEqual(gotKeys, []string{"when", "items", "dup", "dup"}) ||
		!reflect.DeepEqual(gotValues, []string{`"2026-07-23T12:34:56Z"`, `[1,"two",true,null,{"x":3}]`, "1", "2"}) {
		t.Errorf("iterators = %#v / %#v", gotKeys, gotValues)
	}
	for _, pair := range [][2]forge.Result{
		{{Type: forge.String, Str: "A"}, {Type: forge.String, Str: "b"}},
		{{Type: forge.Number, Num: 1}, {Type: forge.Number, Num: 2}},
		{{Type: forge.Null}, {Type: forge.False}},
	} {
		upA := upstream.Result{Type: upstream.Type(pair[0].Type), Str: pair[0].Str, Num: pair[0].Num}
		upB := upstream.Result{Type: upstream.Type(pair[1].Type), Str: pair[1].Str, Num: pair[1].Num}
		if pair[0].Less(pair[1], false) != upA.Less(upB, false) {
			t.Errorf("Less differs for %#v %#v", pair[0], pair[1])
		}
	}
}

func TestCompatibilityUtilitiesDifferential(t *testing.T) {
	for _, value := range []string{
		"plain", "\"quoted\"\n", "<script>&", "\u2028\u2029", string([]byte{0xff}),
	} {
		for _, disableHTML := range []bool{false, true} {
			forge.DisableEscapeHTML = disableHTML
			upstream.DisableEscapeHTML = disableHTML
			got := forge.AppendJSONString([]byte("prefix:"), value)
			want := upstream.AppendJSONString([]byte("prefix:"), value)
			if string(got) != string(want) {
				t.Errorf("AppendJSONString(%q, disable=%v) = %q, upstream %q",
					value, disableHTML, got, want)
			}
		}
	}
	forge.DisableEscapeHTML = false
	upstream.DisableEscapeHTML = false

	input := " 1\n{\"x\":2}\ntrue\n"
	var gotLines, wantLines []string
	forge.ForEachLine(input, func(line forge.Result) bool {
		gotLines = append(gotLines, line.Raw)
		return true
	})
	upstream.ForEachLine(input, func(line upstream.Result) bool {
		wantLines = append(wantLines, line.Raw)
		return true
	})
	if !reflect.DeepEqual(gotLines, wantLines) {
		t.Errorf("ForEachLine = %#v, upstream %#v", gotLines, wantLines)
	}

	name := "goforge_test_modifier"
	forge.AddModifier(name, func(json, argument string) string { return json + argument })
	upstream.AddModifier(name, func(json, argument string) string { return json + argument })
	if forge.ModifierExists(name, nil) != upstream.ModifierExists(name, nil) ||
		forge.ModifierExists("missing", nil) != upstream.ModifierExists("missing", nil) ||
		forge.ModifierExists("pretty", nil) != upstream.ModifierExists("pretty", nil) {
		t.Error("modifier inventory differs")
	}
}

func TestResultPathDifferential(t *testing.T) {
	source := `{"a.b":{"items":[{"x":1},{"x":2}]},"plain":true}`
	for _, path := range []string{`a\.b`, `a\.b.items`, `a\.b.items.0.x`, "plain"} {
		got, want := forge.Get(source, path), upstream.Get(source, path)
		if got.Path(source) != want.Path(source) {
			t.Errorf("%q Path = %q, upstream %q", path, got.Path(source), want.Path(source))
		}
	}
	gotRoot, wantRoot := forge.Parse(source), upstream.Parse(source)
	if gotRoot.Path(source) != wantRoot.Path(source) {
		t.Errorf("root Path = %q, upstream %q", gotRoot.Path(source), wantRoot.Path(source))
	}

	projected := upstream.Get(source, `a\.b.items.#.x`)
	ours := forge.Result{
		Type: forge.Type(projected.Type), Raw: projected.Raw, Str: projected.Str,
		Num: projected.Num, Index: projected.Index,
		Indexes: append([]int(nil), projected.Indexes...),
	}
	if got, want := ours.Paths(source), projected.Paths(source); !reflect.DeepEqual(got, want) {
		t.Errorf("Paths = %#v, upstream %#v", got, want)
	}
}

func TestDynamicPathLanguageDifferential(t *testing.T) {
	source := `{
		"info":{"friends":[
			{"first":"Dale","last":"Murphy","age":44,"kind":"Person"},
			{"first":"Roger","last":"Craig","age":68,"kind":"Person"},
			{"first":"Jane","last":"Murphy","age":47,"kind":"Other"}
		]},
		"wildcard":{"alpha":1,"alpine":2,"beta":3}
	}`
	paths := []string{
		"wildcard.al*",
		"wildcard.?eta",
		"info.friends.#",
		"info.friends.#.first",
		`info.friends.#[first="Dale"].last`,
		`info.friends.#[age>=47].first`,
		`info.friends.#[kind="Person"]#.first`,
		"info|friends|0|first",
		"info.friends.[0.first,1.last]",
		"info.friends.0.{first,last,years:age}",
		`{"first":info.friends.0.first,"count":info.friends.#}`,
		"!true",
		`!"literal"`,
		"@this:.0",
		"info.friends.#.0.#|0",
		"info.friends.#.1.#|0",
		"info.friends.#.A.#|0",
		"info.friends.#.#|0",
		"info.friends.#.0.#.#|0",
		"info.friends.#.0|0",
		"info.friends.+0",
		"info.friends.800000000000000000000000000000000000000000000000000000000000000",
		"info.friends.[#].#[]",
		"*.[b**a].0",
	}
	for _, path := range paths {
		t.Run(path, func(t *testing.T) {
			got, want := forge.Get(source, path), upstream.Get(source, path)
			if got.Exists() != want.Exists() || got.Type != forge.Type(want.Type) ||
				got.Raw != want.Raw || got.String() != want.String() ||
				!reflect.DeepEqual(got.Indexes, want.Indexes) {
				t.Errorf("got %#v (%q), upstream %#v (%q)", got, got.String(), want, want.String())
			}
		})
	}

	modifier := "goforge_upper"
	forge.AddModifier(modifier, func(json, _ string) string {
		return strings.ToUpper(json)
	})
	upstream.AddModifier(modifier, func(json, _ string) string {
		return strings.ToUpper(json)
	})
	got := forge.Get(`"hello"`, "@"+modifier)
	want := upstream.Get(`"hello"`, "@"+modifier)
	if got.Raw != want.Raw || got.String() != want.String() {
		t.Errorf("custom modifier = %#v, upstream %#v", got, want)
	}
	forge.DisableModifiers, upstream.DisableModifiers = true, true
	got = forge.Get(`"hello"`, "@"+modifier)
	want = upstream.Get(`"hello"`, "@"+modifier)
	if got.Exists() != want.Exists() || got.Raw != want.Raw {
		t.Errorf("disabled modifier = %#v, upstream %#v", got, want)
	}
	forge.DisableModifiers, upstream.DisableModifiers = false, false
}

func TestPermissiveCompatibilityParsingDifferential(t *testing.T) {
	source := `{"before":1,"broken":{"value":oops"still"},"after":2}`
	for _, path := range []string{"before", "broken", "after"} {
		got, want := forge.Get(source, path), upstream.Get(source, path)
		if got.Exists() != want.Exists() || got.Type != forge.Type(want.Type) ||
			got.Raw != want.Raw || got.String() != want.String() {
			t.Errorf("%q = %#v (%q), upstream %#v (%q)", path, got, got.String(), want, want.String())
		}
	}
	if forge.Valid(source) != upstream.Valid(source) {
		t.Errorf("Valid = %v, upstream %v", forge.Valid(source), upstream.Valid(source))
	}
	for _, source := range []string{
		" 100 trailing", " true false", ` "text" trailing`,
		` {"a":1} trailing`, ` {"unclosed":1`,
	} {
		got, want := forge.Parse(source), upstream.Parse(source)
		if got.Type != forge.Type(want.Type) || got.Raw != want.Raw || got.String() != want.String() {
			t.Errorf("Parse(%q) = %#v, upstream %#v", source, got, want)
		}
	}
}

func TestBuiltinModifiersDifferential(t *testing.T) {
	cases := []struct {
		source string
		path   string
	}{
		{`{"b":2,"a":1}`, `@pretty:{"sortKeys":true}`},
		{" { \"a\" : [ 1, 2 ] } ", "@ugly"},
		{`[1,2,3]`, "@reverse"},
		{`{"a":1,"b":2}`, "@reverse"},
		{`[1,[2],[3,[4]]]`, "@flatten"},
		{`[1,[2],[3,[4]]]`, `@flatten:{"deep":true}`},
		{`{"a":1,"b":2}`, "@keys"},
		{`{"a":1,"b":2}`, "@values"},
		{`[{"a":1,"same":1},{"b":2,"same":2}]`, "@join"},
		{`[{"a":1,"same":1},{"b":2,"same":2}]`, `@join:{"preserve":true}`},
		{`{"a":1}`, "@valid"},
		{`{"a":1}`, "@tostr"},
		{`"{\"a\":1}"`, "@fromstr"},
		{`{"a":[1,2],"b":[3,4]}`, "@group"},
		{`{"a":{"target":1},"b":[{"target":2},{"nested":{"target":3}}]}`, "@dig:target"},
	}
	for _, test := range cases {
		t.Run(test.path+"/"+test.source, func(t *testing.T) {
			got, want := forge.Get(test.source, test.path), upstream.Get(test.source, test.path)
			if got.Exists() != want.Exists() || got.Type != forge.Type(want.Type) ||
				got.Raw != want.Raw || got.String() != want.String() {
				t.Errorf("got %#v (%q), upstream %#v (%q)", got, got.String(), want, want.String())
			}
		})
	}
}

func TestQueryOperatorCorpusDifferential(t *testing.T) {
	source := `{"info":{"friends":[
		{"first":"Dale","last":"Murphy","cust1":true,"extra":[10,20]},
		{"first":"Roger","last":"Craig","cust2":false,"extra":[40,50]}
	]}}`
	paths := []string{
		"i*.f*.#[extra.0<11].first",
		"i*.f*.#[extra.0<=10].first",
		"i*.f*.#[extra.0!=10].first",
		"i*.f*.#[extra.0>10].first",
		"i*.f*.#[extra.0>=10].first",
		`i*.f*.#[extra.0<"11"].first`,
		`i*.f*.#[first>"Dale"].last`,
		`i*.f*.#[first!="Dale"].last`,
		`i*.f*.#[first%"Da*"].last`,
		`i*.f*.#[first!%"*e*"]#|#`,
		`i*.f*.#[cust1=true].first`,
		`i*.f*.#[cust2=false].first`,
		`i*.f*.#[cust1!=false].first`,
		`i*.f*.#[cust2<=false].first`,
	}
	for _, path := range paths {
		got, want := forge.Get(source, path), upstream.Get(source, path)
		if got.Exists() != want.Exists() || got.Type != forge.Type(want.Type) ||
			got.Raw != want.Raw || got.String() != want.String() {
			t.Errorf("%q = %#v (%q), upstream %#v (%q)", path, got, got.String(), want, want.String())
		}
	}
}

func TestStaticAndNestedMultipathDifferential(t *testing.T) {
	source := `{"name":{"first":"Tom","last":"Anderson"},"age":37,"friends":[
		{"first":"Dale","age":44},{"first":"Roger","age":68}
	]}`
	paths := []string{
		`!{"name":{"first":"Tom"}}.{name.first}.first`,
		`{name.last,"foo":!"bar"}`,
		`{name.last,"foo":!{"a":"b"},"that"}`,
		`{name.last,"foo":!{"c":"d"},!"that"}`,
		`friends.#.{age,first}`,
		`friends.[0.first,1.age]`,
		`{"children":friends.#.first,"name":name.first,"age":age}`,
	}
	for _, path := range paths {
		got, want := forge.Get(source, path), upstream.Get(source, path)
		if got.Exists() != want.Exists() || got.Type != forge.Type(want.Type) ||
			got.Raw != want.Raw || got.String() != want.String() {
			t.Errorf("%q = %#v (%q), upstream %#v (%q)", path, got, got.String(), want, want.String())
		}
	}
}

func TestWildcardEscapingAndUnicodeDifferential(t *testing.T) {
	source := `{"test":{
		"*":"literal-star","*v":"star-v","key*v":"middle-star",
		"keyv?":"tail-question","key?v":"middle-question",
		"keyv.":"tail-dot","key.v":"middle-dot",
		"的情况下解":{"的情况":2}
	}}`
	paths := []string{
		`test.\*`, `test.\*v`, `test.key\*v`,
		`test.keyv\?`, `test.key\?v`,
		`test.keyv\.`, `test.key\.v`,
		`test.的情?下解.的?况`,
	}
	for _, path := range paths {
		got, want := forge.Get(source, path), upstream.Get(source, path)
		if got.Exists() != want.Exists() || got.Raw != want.Raw || got.String() != want.String() {
			t.Errorf("%q = %#v, upstream %#v", path, got, want)
		}
	}
}

func TestQueryArrayAndScalarValuesDifferential(t *testing.T) {
	source := `{"artists":[["Bob Dylan"],"John Lennon","Mick Jagger",
		"Elton John","Michael Jackson","John Smith",true,123,456,false,null]}`
	paths := []string{
		`a*.#[0="Bob Dylan"]#|#`,
		`a*.#[0="Bob Dylan 2"]#|#`,
		`a*.#[%"John*"]#|#`,
		`a*.#[_%"John*"]#|#`,
		`a*.#[=true]#|#`,
		`a*.#[>200]#|#`,
		`a*.#[=null]#|#`,
	}
	for _, path := range paths {
		got, want := forge.Get(source, path), upstream.Get(source, path)
		if got.Exists() != want.Exists() || got.Type != forge.Type(want.Type) ||
			got.Raw != want.Raw || got.String() != want.String() {
			t.Errorf("%q = %#v (%q), upstream %#v (%q)", path, got, got.String(), want, want.String())
		}
	}
}

func TestExistentialTypedSchemaPath(t *testing.T) {
	document, err := forge.ParseDocument(sample)
	if err != nil {
		t.Fatal(err)
	}
	parsed := forge.ParseTypedPath(41, "meta.version", typed.IntegerKind{})
	pathResult, ok := parsed.(typed.PathParsed)
	if !ok {
		t.Fatalf("parse %T", parsed)
	}
	some, ok := pathResult.Path.(typed.SomeIntegerPath)
	if !ok {
		t.Fatalf("path %T", pathResult.Path)
	}
	lookup := forge.LookupInteger(some.Path, forge.BindJSONDocument(41, document))
	presentResult, ok := lookup.(typed.PresentLookup[int])
	if !ok {
		t.Fatalf("lookup %T", lookup)
	}
	if got := typed.PresentValue[int](presentResult.Result); got != 3 {
		t.Fatalf("got %d", got)
	}
}

func TestTypedNumberRetainsDecimalSpelling(t *testing.T) {
	document, err := forge.ParseDocument(`{"amount":1.2300e+4}`)
	if err != nil {
		t.Fatal(err)
	}
	parsed := forge.ParseTypedPath(42, "amount", typed.NumberKind{}).(typed.PathParsed)
	path := parsed.Path.(typed.SomeNumberPath).Path
	result := forge.LookupNumber(path, forge.BindJSONDocument(42, document)).(typed.PresentLookup[typed.NumberText])
	if raw := result.Result.(typed.Present[typed.NumberText]).Value.Raw; raw != "1.2300e+4" {
		t.Fatalf("raw %q", raw)
	}
}

func TestSameTypedPathQueriesJSONAndCBOR(t *testing.T) {
	parsed := forge.ParseTypedPath(77, "meta.version", typed.IntegerKind{}).(typed.PathParsed)
	path := parsed.Path.(typed.SomeIntegerPath).Path
	jsonDocument, err := forge.ParseDocument(sample)
	if err != nil {
		t.Fatal(err)
	}
	jsonResult := forge.LookupInteger(path, forge.BindJSONDocument(77, jsonDocument)).(typed.PresentLookup[int])
	cborDocument, err := cbor.Marshal(map[string]any{"meta": map[string]any{"version": 3}})
	if err != nil {
		t.Fatal(err)
	}
	cborResult := forge.LookupCBORInteger(path, forge.BindCBORDocument(77, cborDocument)).(typed.PresentLookup[int])
	jsonValue := jsonResult.Result.(typed.Present[int]).Value
	cborValue := cborResult.Result.(typed.Present[int]).Value
	if jsonValue != cborValue {
		t.Fatalf("JSON=%d CBOR=%d", jsonValue, cborValue)
	}
}

func TestSchemaPreservingPathComposition(t *testing.T) {
	prefix := typed.NewPath[int](12, []typed.Segment{typed.Field{Name: "meta"}}, typed.ObjectKind{})
	suffix := typed.NewPath[int](12, []typed.Segment{typed.Field{Name: "version"}}, typed.IntegerKind{})
	composed := typed.Compose[int, int](prefix, suffix)
	document, err := forge.ParseDocument(sample)
	if err != nil {
		t.Fatal(err)
	}
	result := forge.LookupInteger(composed, forge.BindJSONDocument(12, document)).(typed.PresentLookup[int])
	if got := result.Result.(typed.Present[int]).Value; got != 3 {
		t.Fatalf("got %d", got)
	}
}

func TestErasedGoBoundaryRechecksSchema(t *testing.T) {
	path := typed.NewPath[int](1, []typed.Segment{typed.Field{Name: "id"}}, typed.IntegerKind{})
	document, err := forge.ParseDocument(`{"id":1}`)
	if err != nil {
		t.Fatal(err)
	}
	bound := forge.BindJSONDocument(2, document)
	defer func() {
		if recover() == nil {
			t.Fatal("mismatched erased schemas did not panic")
		}
	}()
	_ = forge.LookupInteger(path, bound)
}

func TestCompatibilityScalarMethods(t *testing.T) {
	for _, source := range []string{`12`, `1.20`, `true`, `"42"`, `"TRUE"`} {
		got := forge.Parse(source)
		want := upstream.Parse(source)
		if got.String() != want.String() || got.Bool() != want.Bool() || got.Int() != want.Int() || got.Uint() != want.Uint() || got.Float() != want.Float() {
			t.Fatalf("%s: got (%q,%v,%d,%d,%g), want (%q,%v,%d,%d,%g)", source, got.String(), got.Bool(), got.Int(), got.Uint(), got.Float(), want.String(), want.Bool(), want.Int(), want.Uint(), want.Float())
		}
	}
}

func TestExhaustiveLookupStatesAndLosslessNumber(t *testing.T) {
	document, err := forge.ParseDocument(sample)
	if err != nil {
		t.Fatal(err)
	}
	if got := document.Query(forge.MustCompilePath("missing")).State(); got != forge.MissingState {
		t.Fatalf("missing state %v", got)
	}
	if got := document.Query(forge.MustCompilePath("nothing")).State(); got != forge.NullState {
		t.Fatalf("null state %v", got)
	}
	lookup := document.Query(forge.MustCompilePath("count"))
	value, ok := lookup.Value()
	if !ok {
		t.Fatalf("state %v", lookup.State())
	}
	integer, err := value.Int64()
	if err != nil {
		t.Fatal(err)
	}
	if integer != 9007199254740993 {
		t.Fatalf("integer %d", integer)
	}
	if got := forge.MustCompilePath("x").Query(`{"x":]}`).State(); got != forge.MalformedState {
		t.Fatalf("malformed state %v", got)
	}
}

func TestBorrowedStringAndByteOwnership(t *testing.T) {
	document, err := forge.ParseDocument(sample)
	if err != nil {
		t.Fatal(err)
	}
	value, _ := document.Query(forge.MustCompilePath("users.1.name")).Value()
	raw := value.Raw()
	offset := strings.Index(sample, raw)
	if offset < 0 {
		t.Fatal("raw not in source")
	}
	if unsafe.StringData(raw) != (*byte)(unsafe.Add(unsafe.Pointer(unsafe.StringData(sample)), offset)) {
		t.Fatal("raw value was copied")
	}
	document = forge.Document{}
	runtime.GC()
	if value.Raw() != raw {
		t.Fatal("borrowed value did not retain source")
	}
	buffer := make([]byte, 0, 32)
	buffer, err = value.AppendString(buffer)
	if err != nil {
		t.Fatal(err)
	}
	if string(buffer) != "Gopher\nTeam" {
		t.Fatalf("decoded %q", buffer)
	}
	bytes := []byte(`{"name":"Ada"}`)
	owned, err := forge.ParseDocumentBytes(bytes)
	if err != nil {
		t.Fatal(err)
	}
	bytes[9] = 'E'
	got, _ := owned.Query(forge.MustCompilePath("name")).Value()
	text, err := got.StringValue()
	if err != nil {
		t.Fatal(err)
	}
	if text != "Ada" {
		t.Fatalf("borrowed bytes changed: %q", text)
	}
}

func TestPathEscapingAndStreaming(t *testing.T) {
	path, err := forge.CompilePath(forge.Escape("a.b") + ".0")
	if err != nil {
		t.Fatal(err)
	}
	document, err := forge.ParseDocument(`{"a.b":[42]}`)
	if err != nil {
		t.Fatal(err)
	}
	value, _ := document.Query(path).Value()
	integer, err := value.Int64()
	if err != nil || integer != 42 {
		t.Fatalf("%d %v", integer, err)
	}
	scanner := forge.NewLineScanner(strings.NewReader("{\"id\":1}\n{\"id\":2}\n"))
	sum := int64(0)
	id := forge.MustCompilePath("id")
	for scanner.Next() {
		value, _ := scanner.Document().Query(id).Value()
		number, err := value.Int64()
		if err != nil {
			t.Fatal(err)
		}
		sum += number
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if sum != 3 {
		t.Fatalf("sum %d", sum)
	}
}

func TestConcurrentCompiledPath(t *testing.T) {
	document, err := forge.ParseDocument(sample)
	if err != nil {
		t.Fatal(err)
	}
	path := forge.MustCompilePath("users.0.name")
	var wait sync.WaitGroup
	for range 16 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for range 1000 {
				value, ok := document.Query(path).Value()
				if !ok || value.Raw() != `"Ada"` {
					t.Errorf("bad query")
					return
				}
			}
		}()
	}
	wait.Wait()
}

func TestImmutableModifierRegistry(t *testing.T) {
	empty := forge.NewRegistry()
	upper, err := empty.With("upper", func(json, argument string) (string, error) { return strings.ToUpper(json) + argument, nil })
	if err != nil {
		t.Fatal(err)
	}
	if empty.Exists("upper") {
		t.Fatal("original registry mutated")
	}
	if !upper.Exists("upper") {
		t.Fatal("modifier missing")
	}
	got, err := upper.Apply("upper", "go", "!")
	if err != nil || got != "GO!" {
		t.Fatalf("%q %v", got, err)
	}
}

var benchmarkBytes []byte
var benchmarkString string

func BenchmarkEscapedStringQuery(b *testing.B) {
	document, err := forge.ParseDocument(sample)
	if err != nil {
		b.Fatal(err)
	}
	path := forge.MustCompilePath("users.1.name")
	typedParsed := forge.ParseTypedPath(101, "users.1.name", typed.StringKind{}).(typed.PathParsed)
	typedPath := typedParsed.Path.(typed.SomeStringPath).Path
	typedDocument := forge.BindJSONDocument(101, document)
	scratch := make([]byte, 0, 32)
	b.Run("upstream", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			benchmarkString = upstream.Get(sample, "users.1.name").String()
		}
	})
	b.Run("goforge-borrowed", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			value, ok := document.Query(path).Value()
			if !ok {
				b.Fatal("missing")
			}
			scratch = scratch[:0]
			scratch, err = value.AppendString(scratch)
			if err != nil {
				b.Fatal(err)
			}
			benchmarkBytes = scratch
		}
	})
	b.Run("goforge-schema-typed", func(b *testing.B) {
		b.ReportAllocs()
		var view typed.StringView
		for b.Loop() {
			if forge.LookupStringInto(typedPath, typedDocument, &view) != forge.ValueState {
				b.Fatal("missing")
			}
			scratch = scratch[:0]
			scratch, err = forge.AppendStringView(scratch, view)
			if err != nil {
				b.Fatal(err)
			}
			benchmarkBytes = scratch
		}
	})
}

func TestQueryAllocationBudget(t *testing.T) {
	document, err := forge.ParseDocument(sample)
	if err != nil {
		t.Fatal(err)
	}
	typedParsed := forge.ParseTypedPath(101, "users.1.name", typed.StringKind{}).(typed.PathParsed)
	typedPath := typedParsed.Path.(typed.SomeStringPath).Path
	typedDocument := forge.BindJSONDocument(101, document)
	scratch := make([]byte, 0, 32)
	upstreamAllocs := testing.AllocsPerRun(1000, func() { benchmarkString = upstream.Get(sample, "users.1.name").String() })
	forgeAllocs := testing.AllocsPerRun(1000, func() {
		var view typed.StringView
		if forge.LookupStringInto(typedPath, typedDocument, &view) != forge.ValueState {
			panic("missing")
		}
		scratch = scratch[:0]
		var err error
		scratch, err = forge.AppendStringView(scratch, view)
		if err != nil {
			panic(err)
		}
		benchmarkBytes = scratch
	})
	if forgeAllocs*2 > upstreamAllocs {
		t.Fatalf("allocation reduction below 50%%: upstream=%v GoForge=%v", upstreamAllocs, forgeAllocs)
	}
}

func BenchmarkDynamicCompatibilityPaths(b *testing.B) {
	source := `{"info":{"friends":[
		{"first":"Dale","last":"Murphy","age":44},
		{"first":"Roger","last":"Craig","age":68},
		{"first":"Jane","last":"Murphy","age":47}
	]}}`
	for _, path := range []string{
		"i*.f*.0.first",
		`info.friends.#[age>=47].first`,
		"info.friends.#.last",
	} {
		b.Run(path+"/goforge", func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				benchmarkString = forge.Get(source, path).String()
			}
		})
		b.Run(path+"/upstream", func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				benchmarkString = upstream.Get(source, path).String()
			}
		})
	}
}
