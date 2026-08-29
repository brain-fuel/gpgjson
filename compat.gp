// Go+ compatibility surface for tidwall/gjson.
package gjson

import (
	"iter"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

// Result is the tier-1 migration shape. Raw and Str retain GJSON meanings;
// Num is explicitly lossy and semantic callers should prefer Borrowed.Int64.
type Result struct {
	Type    Type
	Raw     string
	Str     string
	Num     float64
	Index   int
	Indexes []int
	synthetic bool
	projectionSynthetic bool
	suppressIndexes bool
	relativeProjection bool
	arrayElement bool
}

func (r Result) Exists() bool { return r.Type != Null || r.Raw != "" }
func (r Result) String() string {
	switch r.Type {
	case String:
		return r.Str
	case Number:
		if isIntegerSpelling(r.Raw) {
			return r.Raw
		}
		return strconv.FormatFloat(r.Num, 'f', -1, 64)
	case True:
		return "true"
	case False:
		return "false"
	case JSON:
		return r.Raw
	}
	return ""
}
func (r Result) Bool() bool {
	if r.Type == String {
		value, _ := strconv.ParseBool(strings.ToLower(r.Str))
		return value
	}
	return r.Type == True || r.Type == Number && r.Num != 0
}
func (r Result) Int() int64 {
	if r.Type == True {
		return 1
	}
	if r.Type == Number {
		if value, err := strconv.ParseInt(r.Raw, 10, 64); err == nil {
			return value
		}
		return int64(r.Num)
	}
	if r.Type == String {
		value, _ := strconv.ParseInt(r.Str, 10, 64)
		return value
	}
	return 0
}
func (r Result) Uint() uint64 {
	if r.Type == True {
		return 1
	}
	if r.Type == Number {
		if value, err := strconv.ParseUint(r.Raw, 10, 64); err == nil {
			return value
		}
		if r.Num >= 0 {
			return uint64(r.Num)
		}
	}
	if r.Type == String {
		value, _ := strconv.ParseUint(r.Str, 10, 64)
		return value
	}
	return 0
}
func (r Result) Float() float64 {
	if r.Type == True {
		return 1
	}
	if r.Type == String {
		value, _ := strconv.ParseFloat(r.Str, 64)
		return value
	}
	return r.Num
}
func (r Result) IsArray() bool  { return r.Type == JSON && len(r.Raw) > 0 && r.Raw[0] == '[' }
func (r Result) IsObject() bool { return r.Type == JSON && len(r.Raw) > 0 && r.Raw[0] == '{' }
func (r Result) IsBool() bool   { return r.Type == True || r.Type == False }
func (r Result) Time() time.Time {
	value, _ := time.Parse(time.RFC3339, r.String())
	return value
}
func (r Result) Less(other Result, caseSensitive bool) bool {
	if r.Type != other.Type {
		return r.Type < other.Type
	}
	switch r.Type {
	case String:
		if caseSensitive {
			return r.Str < other.Str
		}
		return strings.ToLower(r.Str) < strings.ToLower(other.Str)
	case Number:
		return r.Num < other.Num
	default:
		return r.Raw < other.Raw
	}
}

func resultAt(raw string, index int) Result {
	result := Parse(raw)
	result.Index += index
	return result
}

func (r Result) ForEach(iterator func(key, value Result) bool) {
	if !r.Exists() {
		return
	}
	if r.Type != JSON {
		iterator(Result{}, r)
		return
	}
	offset := skipSpace(r.Raw, 0)
	if offset >= len(r.Raw) || r.Raw[offset] != '[' && r.Raw[offset] != '{' {
		return
	}
	object := r.Raw[offset] == '{'
	offset++
	arrayIndex := 0
	for {
		offset = skipSpace(r.Raw, offset)
		if offset >= len(r.Raw) || r.Raw[offset] == ']' || r.Raw[offset] == '}' {
			return
		}
		key := Result{Type: Number, Num: float64(arrayIndex)}
		if object {
			keyStart := offset
			keyEnd, _, err := scanJSONString(r.Raw, keyStart)
			if err != nil {
				return
			}
			key = resultAt(r.Raw[keyStart:keyEnd], r.Index+keyStart)
			offset = skipSpace(r.Raw, keyEnd)
			if offset >= len(r.Raw) || r.Raw[offset] != ':' {
				return
			}
			offset++
		}
		offset = skipSpace(r.Raw, offset)
		valueStart := offset
		if object && valueStart < len(r.Raw) && r.Raw[valueStart] == ',' {
			valueStart = skipSpace(r.Raw, valueStart+1)
		}
		if !object {
			for valueStart < len(r.Raw) && !compatibilityValueStart(r.Raw[valueStart]) {
				valueStart++
			}
			if valueStart >= len(r.Raw) || r.Raw[valueStart] == ']' {
				return
			}
		}
		valueEnd, kind, err := compatibilityScanValue(r.Raw, valueStart)
		if err != nil {
			return
		}
		value := resultAt(r.Raw[valueStart:valueEnd], r.Index+valueStart)
		if kind == String {
			value = compatibilityStringResult(r.Raw[valueStart:valueEnd], r.Index+valueStart)
		} else if kind == Number && value.Type != Number {
			value = compatibilityNumberResult(r.Raw[valueStart:valueEnd], r.Index+valueStart)
		} else if (kind == True || kind == False || kind == Null) &&
			value.Type != kind {
			value = Result{
				Type: kind, Raw: r.Raw[valueStart:valueEnd],
				Index: r.Index + valueStart,
			}
		}
		if r.Indexes != nil {
			if arrayIndex < len(r.Indexes) {
				value.Index = r.Indexes[arrayIndex]
			} else {
				value.Index = 0
			}
		}
		if r.synthetic {
			if !r.relativeProjection {
				value.Index = 0
			}
			value.synthetic = true
			value.suppressIndexes = r.suppressIndexes
			value.relativeProjection = r.relativeProjection
		}
		if !iterator(key, value) {
			return
		}
		arrayIndex++
		offset = skipSpace(r.Raw, valueEnd)
		if offset < len(r.Raw) && r.Raw[offset] == ',' {
			offset++
			continue
		}
		if !object && offset < len(r.Raw)-1 {
			offset++
			continue
		}
		if object && offset < len(r.Raw) && r.Raw[offset] == '"' {
			continue
		}
		return
	}
}

// compatibilityScanValue preserves GJSON's permissive array iteration without
// weakening the strict document parser used by Valid and ParseDocument.
func compatibilityScanValue(source string, start int) (int, Type, error) {
	end, kind, err := scanValue(source, start)
	if err == nil {
		return end, kind, nil
	}
	if start < len(source) && (source[start] == '{' || source[start] == '[') {
		if compositeEnd := compatibilityCompositeEnd(source, start); compositeEnd > start {
			return compositeEnd, JSON, nil
		}
	}
	if start < len(source) && source[start] == '"' {
		escaped := false
		for end = start + 1; end < len(source); end++ {
			if source[end] == '"' && !escaped {
				return end + 1, String, nil
			}
			if source[end] == '\\' {
				escaped = !escaped
			} else {
				escaped = false
			}
		}
	}
	if start < len(source) && (source[start] == 't' ||
		source[start] == 'f' ||
		source[start] == 'n' && start+1 < len(source) && source[start+1] == 'u') {
		end = start + 1
		for end < len(source) && source[end] >= 'a' && source[end] <= 'z' {
			end++
		}
		switch source[start] {
		case 't':
			return end, True, nil
		case 'f':
			return end, False, nil
		case 'n':
			if start+1 < len(source) && source[start+1] == 'u' {
				return end, Null, nil
			}
			return end, Number, nil
		}
	}
	end = start
	for end < len(source) {
		switch source[end] {
		case ',', ']', '}', ' ', '\t', '\n', '\r':
			goto token
		}
		end++
	}
token:
	raw := source[start:end]
	lower := strings.ToLower(raw)
	switch lower {
	case "inf", "+inf", "-inf", "nan", "+nan", "-nan":
		return end, Number, nil
	}
	if strings.HasPrefix(raw, "+") {
		if _, parseErr := strconv.ParseFloat(raw, 64); parseErr == nil {
			return end, Number, nil
		}
	}
	if end > start {
		// Upstream's compatibility parser classifies otherwise-unrecognized
		// bare tokens as number-like values with Num == 0. Keep that
		// permissiveness out of ParseDocument and Valid.
		return end, Number, nil
	}
	return start, Null, err
}

func compatibilityValueStart(value byte) bool {
	switch value {
	case '"', '{', '[', 't', 'f', 'n', '+', '-', 'i', 'I', 'N':
		return true
	}
	return value >= '0' && value <= '9'
}

func compatibilityCompositeEnd(source string, start int) int {
	depth := 0
	quoted := false
	escaped := false
	for index := start; index < len(source); index++ {
		value := source[index]
		if quoted {
			if escaped {
				escaped = false
			} else if value == '\\' {
				escaped = true
			} else if value == '"' {
				quoted = false
			}
			continue
		}
		switch value {
		case '"':
			quoted = true
		case '{', '[':
			depth++
		case '}', ']':
			depth--
			if depth == 0 {
				return index + 1
			}
		}
	}
	return 0
}

func compatibilityStringResult(raw string, index int) Result {
	value := raw
	if len(value) >= 2 {
		value = value[1 : len(value)-1]
	}
	decoded := value
	if strings.IndexByte(value, '\\') >= 0 {
		decoded = compatibilityUnescape(value)
	}
	return Result{Type: String, Raw: raw, Str: decoded, Index: index}
}

func compatibilityUnescape(raw string) string {
	output := make([]byte, 0, len(raw))
	for index := 0; index < len(raw); index++ {
		switch {
		case raw[index] < ' ':
			return string(output)
		case raw[index] != '\\':
			output = append(output, raw[index])
		default:
			index++
			if index >= len(raw) {
				return string(output)
			}
			switch raw[index] {
			case '\\', '/', '"':
				output = append(output, raw[index])
			case 'b':
				output = append(output, '\b')
			case 'f':
				output = append(output, '\f')
			case 'n':
				output = append(output, '\n')
			case 'r':
				output = append(output, '\r')
			case 't':
				output = append(output, '\t')
			case 'u':
				if index+4 >= len(raw) {
					return string(output)
				}
				// Upstream's runeit discards the parse error and uses the
				// zero value, so `\u0X00` contributes NUL rather than
				// truncating the string. Truncating instead turned a
				// pattern like `*\u0X00` into a bare `*`, which matches
				// everything upstream refuses.
				first, _ := strconv.ParseUint(raw[index+1:index+5], 16, 16)
				value := rune(first)
				index += 4
				if utf16.IsSurrogate(value) && index+6 < len(raw) &&
					raw[index+1:index+3] == `\u` {
					second, secondErr := strconv.ParseUint(raw[index+3:index+7], 16, 16)
					if secondErr == nil {
						value = utf16.DecodeRune(value, rune(second))
						index += 6
					}
				}
				output = utf8.AppendRune(output, value)
			default:
				return string(output)
			}
		}
	}
	return string(output)
}

func compatibilityNumberResult(raw string, index int) Result {
	lower := strings.ToLower(raw)
	var number float64
	switch lower {
	case "inf", "+inf":
		number = math.Inf(1)
	case "-inf":
		number = math.Inf(-1)
	case "nan", "+nan", "-nan":
		number = math.NaN()
	default:
		number, _ = strconv.ParseFloat(raw, 64)
	}
	return Result{Type: Number, Raw: raw, Num: number, Index: index}
}

func (r Result) Array() []Result {
	if r.Type == Null {
		return []Result{}
	}
	if !r.IsArray() {
		return []Result{r}
	}
	values := []Result{}
	r.ForEach(func(_ Result, value Result) bool {
		values = append(values, value)
		return true
	})
	return values
}
func (r Result) Map() map[string]Result {
	values := map[string]Result{}
	if !r.IsObject() {
		return values
	}
	r.ForEach(func(key, value Result) bool {
		if _, exists := values[key.Str]; !exists {
			values[key.Str] = value
		}
		return true
	})
	return values
}
func (r Result) Get(path string) Result {
	result := Get(r.Raw, path)
	if result.Indexes != nil {
		for i := range result.Indexes {
			result.Indexes[i] += r.Index
		}
	} else {
		result.Index += r.Index
	}
	return result
}
func (r Result) Value() any {
	switch r.Type {
	case String:
		return r.Str
	case False:
		return false
	case Number:
		return r.Num
	case True:
		return true
	case JSON:
		if r.IsObject() {
			values := map[string]any{}
			for key, value := range r.Map() {
				values[key] = value.Value()
			}
			return values
		}
		if r.IsArray() {
			results := r.Array()
			values := make([]any, len(results))
			for i, result := range results {
				values[i] = result.Value()
			}
			return values
		}
	}
	return nil
}
func (r Result) All() iter.Seq2[Result, Result] {
	return func(yield func(Result, Result) bool) { r.ForEach(yield) }
}
func (r Result) Keys() iter.Seq[Result] {
	return func(yield func(Result) bool) {
		r.ForEach(func(key, _ Result) bool { return yield(key) })
	}
}
func (r Result) Values() iter.Seq[Result] {
	return func(yield func(Result) bool) {
		r.ForEach(func(_ Result, value Result) bool { return yield(value) })
	}
}

func (r Result) Paths(json string) []string {
	if r.Indexes == nil {
		return nil
	}
	paths := make([]string, 0, len(r.Indexes))
	r.ForEach(func(_ Result, value Result) bool {
		paths = append(paths, value.Path(json))
		return true
	})
	if len(paths) != len(r.Indexes) {
		return nil
	}
	return paths
}

func (r Result) Path(json string) string {
	if r.Index < 0 || r.Index+len(r.Raw) > len(json) ||
		!strings.HasPrefix(json[r.Index:], r.Raw) {
		return ""
	}
	root := skipSpace(json, 0)
	if root == r.Index {
		if DisableModifiers {
			return ""
		}
		return "@this"
	}
	end, _, err := scanValue(json, root)
	if err != nil {
		return ""
	}
	path, found := findResultPath(json, root, end, r.Index, nil)
	if !found {
		return ""
	}
	return strings.Join(path, ".")
}

func findResultPath(json string, start, end, target int, path []string) ([]string, bool) {
	if start == target {
		return path, true
	}
	if start >= end || json[start] != '[' && json[start] != '{' {
		return nil, false
	}
	object := json[start] == '{'
	offset := start + 1
	index := 0
	for {
		offset = skipSpace(json, offset)
		if offset >= end || json[offset] == ']' || json[offset] == '}' {
			return nil, false
		}
		component := strconv.Itoa(index)
		if object {
			keyEnd, _, keyErr := scanJSONString(json, offset)
			if keyErr != nil {
				return nil, false
			}
			component = Escape(resultAt(json[offset:keyEnd], offset).Str)
			offset = skipSpace(json, keyEnd)
			if offset >= end || json[offset] != ':' {
				return nil, false
			}
			offset++
		}
		valueStart := skipSpace(json, offset)
		valueEnd, _, valueErr := scanValue(json, valueStart)
		if valueErr != nil {
			return nil, false
		}
		nextPath := append(append([]string(nil), path...), component)
		if result, found := findResultPath(json, valueStart, valueEnd, target, nextPath); found {
			return result, true
		}
		index++
		offset = skipSpace(json, valueEnd)
		if offset < end && json[offset] == ',' {
			offset++
			continue
		}
		return nil, false
	}
}

func resultOf(lookup Lookup) Result {
	if lookup.state == NullState {
		return Result{Type: Null, Raw: lookup.value.Raw(), Index: lookup.value.start}
	}
	value, ok := lookup.Value()
	if !ok {
		return Result{}
	}
	result := Result{Type: value.kind, Raw: value.Raw(), Index: value.start}
	switch value.kind {
	case String:
		var err error
		result.Str, err = value.StringValue()
		if err != nil && len(result.Raw) >= 2 {
			result.Str = compatibilityUnescape(result.Raw[1 : len(result.Raw)-1])
		}
	case Number:
		result.Num, _ = value.Float64()
	}
	return result
}

func Get(json, path string) Result {
	if path == "" {
		return Result{}
	}
	// Dynamic grammar is not accepted by CompilePath. Route it directly to
	// the compatibility evaluator instead of allocating a doomed diagnostic.
	switch compatibilityDynamicClass(path) {
	case 2:
		return compatibilityGetDynamic(json, path)
	case 1:
		return compatibilityGet(json, path)
	}
	compiled, err := CompilePath(path)
	if err != nil || !compatibilityCompiledPathSafe(compiled) {
		return compatibilityGet(json, path)
	}
	document, err := ParseDocument(json)
	if err != nil {
		return compatibilityGet(json, path)
	}
	return resultOf(document.Query(compiled))
}
func GetBytes(json []byte, path string) Result { return Get(string(json), path) }
func GetMany(json string, paths ...string) []Result {
	results := make([]Result, len(paths))
	document, err := ParseDocument(json)
	if err != nil {
		for i, path := range paths {
			results[i] = Get(json, path)
		}
		return results
	}
	for i, path := range paths {
		if path == "" {
			continue
		}
		compiled, err := CompilePath(path)
		if err == nil && compatibilityCompiledPathSafe(compiled) {
			results[i] = resultOf(document.Query(compiled))
		} else {
			results[i] = compatibilityGet(json, path)
		}
	}
	return results
}
func GetManyBytes(json []byte, paths ...string) []Result { return GetMany(string(json), paths...) }

func compatibilityCompiledPathSafe(path *Path) bool {
	for _, part := range path.segments {
		numeric := part.text != ""
		for index := 0; index < len(part.text); index++ {
			if part.text[index] < '0' || part.text[index] > '9' {
				numeric = false
				break
			}
		}
		if numeric {
			if _, err := strconv.Atoi(part.text); err != nil {
				return false
			}
		}
		if len(part.text) < 2 || part.text[0] != '+' && part.text[0] != '-' {
			continue
		}
		numeric = true
		for index := 1; index < len(part.text); index++ {
			if part.text[index] < '0' || part.text[index] > '9' {
				numeric = false
				break
			}
		}
		if numeric {
			return false
		}
	}
	return true
}

func Parse(json string) Result {
	start := skipSpace(json, 0)
	if start < len(json) && (json[start] == '{' || json[start] == '[') {
		return Result{Type: JSON, Raw: json[start:], Index: start}
	}
	end, kind, err := scanValue(json, start)
	if err != nil {
		return Result{}
	}
	result := Result{Type: kind, Raw: json[start:end], Index: start}
	switch kind {
	case String:
		value, valueErr := borrowedAt(json, start, end)
		if valueErr == nil {
			result.Str, _ = value.StringValue()
		}
	case Number:
		result.Num, _ = strconv.ParseFloat(result.Raw, 64)
	}
	return result
}
func ParseBytes(json []byte) Result { return Parse(string(json)) }
func Valid(json string) bool        { _, err := ParseDocument(json); return err == nil }
func ValidBytes(json []byte) bool   { _, err := ParseDocumentBytes(json); return err == nil }

var DisableEscapeHTML bool
var DisableModifiers bool

var compatibilityModifiers = map[string]func(json, argument string) string{
	"pretty": nil, "ugly": nil, "reverse": nil, "this": nil, "flatten": nil,
	"join": nil, "valid": nil, "keys": nil, "values": nil, "tostr": nil,
	"fromstr": nil, "group": nil, "dig": nil,
}

func AddModifier(name string, modifier func(json, argument string) string) {
	compatibilityModifiers[name] = modifier
}
func ModifierExists(name string, _ func(json, argument string) string) bool {
	_, exists := compatibilityModifiers[name]
	return exists
}

func ForEachLine(json string, iterator func(line Result) bool) {
	offset := 0
	for {
		offset = skipSpace(json, offset)
		if offset >= len(json) {
			return
		}
		end, _, err := scanValue(json, offset)
		if err != nil {
			return
		}
		if !iterator(resultAt(json[offset:end], offset)) {
			return
		}
		offset = end
	}
}

func AppendJSONString(dst []byte, value string) []byte {
	const hex = "0123456789abcdef"
	dst = append(dst, '"')
	for i := 0; i < len(value); i++ {
		byteValue := value[i]
		switch {
		case byteValue < ' ':
			switch byteValue {
			case '\b':
				dst = append(dst, '\\', 'b')
			case '\f':
				dst = append(dst, '\\', 'f')
			case '\n':
				dst = append(dst, '\\', 'n')
			case '\r':
				dst = append(dst, '\\', 'r')
			case '\t':
				dst = append(dst, '\\', 't')
			default:
				dst = append(dst, '\\', 'u', '0', '0', hex[byteValue>>4], hex[byteValue&15])
			}
		case !DisableEscapeHTML && (byteValue == '>' || byteValue == '<' || byteValue == '&'):
			dst = append(dst, '\\', 'u', '0', '0', hex[byteValue>>4], hex[byteValue&15])
		case byteValue == '\\' || byteValue == '"':
			dst = append(dst, '\\', byteValue)
		case byteValue > 127:
			runeValue, size := utf8.DecodeRuneInString(value[i:])
			if runeValue == utf8.RuneError && size == 1 {
				dst = append(dst, `\ufffd`...)
			} else if runeValue == '\u2028' || runeValue == '\u2029' {
				dst = append(dst, `\u202`...)
				dst = append(dst, hex[runeValue&15])
			} else {
				dst = append(dst, value[i:i+size]...)
			}
			i += size - 1
		default:
			dst = append(dst, byteValue)
		}
	}
	return append(dst, '"')
}

// Escape returns a path component with GJSON-compatible dot and backslash
// escaping for the tier-1 grammar.
func Escape(component string) string {
	size := len(component)
	for i := range len(component) {
		if !isSafePathKeyChar(component[i]) {
			size++
		}
	}
	if size == len(component) {
		return component
	}
	out := make([]byte, 0, size)
	for i := range len(component) {
		if !isSafePathKeyChar(component[i]) {
			out = append(out, '\\')
		}
		out = append(out, component[i])
	}
	return string(out)
}

func isSafePathKeyChar(value byte) bool {
	return value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' ||
		value >= '0' && value <= '9' || value <= ' ' || value > '~' ||
		value == '_' || value == '-' || value == ':'
}

func isIntegerSpelling(raw string) bool {
	if raw == "" {
		return false
	}
	start := 0
	if raw[0] == '-' {
		start = 1
	}
	if start == len(raw) {
		return true
	}
	for i := start; i < len(raw); i++ {
		if raw[i] < '0' || raw[i] > '9' {
			return false
		}
	}
	return true
}
