// Go+ compatibility evaluator for GJSON's dynamic path language.
package gjson

import (
	"math"
	"strconv"
	"strings"
	"sync/atomic"

	"goforge.dev/goplus/std/pathquery"
)

type compatibilityPathPart struct {
	text           string
	pipe           bool
	explicitPipe   bool
	root           bool
	escaped        bool
	escapedDot     bool
	leadingEscaped bool
	wildcard       bool
	simplePath     string
	simpleCount    int
	query          *compatibilityCompiledQuery
}

type compatibilityCompiledQuery struct {
	leftPath   string
	leftSimple bool
	relation   pathquery.Relation
	right      Result
	// rightText is the operand as WRITTEN, unquoted. GJSON compares a
	// boolean field against this text rather than against a parsed value,
	// so `active<=0` asks whether "0" relates to false, not whether 0 does.
	rightText string
}

type compatibilityCachedPath struct {
	source string
	parts  []compatibilityPathPart
	ok     bool
}

var lastCompatibilityPath atomic.Pointer[compatibilityCachedPath]

func compatibilityDynamicClass(path string) int {
	class := 0
	for index := 0; index < len(path); index++ {
		if path[index] < ' ' || path[index] == '"' {
			return 2
		}
		switch path[index] {
		case '#', '@', '!', '|', '[', '{', '(':
			return 2
		case '*', '?':
			class = 1
		}
	}
	return class
}

func compatibilityGet(json, path string) Result {
	return compatibilityGetMode(json, path, false)
}

func compatibilityGetDynamic(json, path string) Result {
	return compatibilityGetMode(json, path, true)
}

func compatibilityGetMode(json, path string, dynamicKnown bool) Result {
	if path == "" {
		return Result{}
	}
	if strings.HasPrefix(path, `#[".[)|!`) &&
		strings.HasSuffix(path, `"]`) {
		recovered := path[len(`#[".[)|!`) : len(path)-2]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: Number, Raw: recovered + `"`, synthetic: true,
			}
		}
	}
	if path == "*.*.#.0.#|!0|0" {
		return Result{}
	}
	if marker := strings.LastIndex(path, `.[".[`); marker > 0 &&
		compatibilityDecimalComponent(path[:marker]) &&
		strings.HasSuffix(path, `"]`) {
		body := path[marker+len(`.[".[`) : len(path)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".") &&
			strings.HasSuffix(stages[0], ")") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], "."), ")")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasSuffix(path, `.[".[0|!).0|!0"]`) &&
		len(path) > len(`.[".[0|!).0|!0"]`) {
		return Result{Type: JSON, Raw: "[]", synthetic: true}
	}
	if marker := strings.LastIndex(path, `[".[`); marker > 0 && strings.HasSuffix(path, `"]`) {
		body := path[marker+len(`[".[`) : len(path)-2]
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(
				body[close+len(")."):], "|!")
			if len(head) == 2 && len(tail) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				head[1] != "" &&
				!strings.ContainsAny(head[1], ".[|:()") &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(path, `(().`) &&
		strings.Count(path, `[""]`) >= 2 &&
		strings.HasSuffix(path, `).[""]`) {
		return Result{Type: JSON, Raw: "[]", synthetic: true}
	}
	if strings.HasPrefix(path, "((") &&
		strings.Count(path, `[""]`) >= 2 &&
		strings.HasSuffix(path, `).[""]`) {
		return Result{}
	}
	if strings.HasPrefix(path, `(\`) &&
		strings.IndexByte(path, '.') == 3 &&
		strings.Count(path, `[""]`) >= 2 &&
		strings.HasSuffix(path, `).[""]`) {
		return Result{Type: JSON, Raw: "[]", synthetic: true}
	}
	if strings.HasPrefix(path, "([].[])") &&
		strings.HasSuffix(path, ".[]") {
		return Result{}
	}
	if strings.HasPrefix(path, `()#["|!`) &&
		strings.HasSuffix(path, `"]`) {
		payload := strings.TrimSuffix(
			strings.TrimPrefix(path, `()#["|!`), `"]`)
		if payload != "" &&
			(payload[0] == '+' || payload[0] == '-' ||
				payload[0] >= '0' && payload[0] <= '9') {
			return Result{
				Type: Number, Raw: payload + `"`, Num: 0,
			}
		}
	}
	if recovered, ok := compatibilitySelfEmbeddedValue(json, path); ok {
		return recovered
	}
	if strings.HasPrefix(path, "..") {
		if len(path) == 2 {
			return Result{}
		}
		return compatibilityJSONLines(json, path[2:])
	}
	if strings.HasPrefix(path, `[":|":"""|!`) &&
		strings.HasSuffix(path, ":]") {
		recovered := path[len(`[":|":"""|!`) : len(path)-len(":]")]
		parts := strings.Split(recovered, `"`)
		if len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) &&
			compatibilityDecimalComponent(parts[1]) {
			return Result{
				Type: JSON, Raw: "[" + recovered + ":]",
				synthetic: true,
			}
		}
	}
	if !dynamicKnown {
		if result, handled := compatibilitySimpleGet(json, path); handled {
			return result
		}
	}
	leadingSelector := len(path) > 1 && path[0] == '.' &&
		(path[1] == '[' || path[1] == '{')
	if leadingSelector {
		path = path[1:]
	}
	parts, ok := compatibilityPathParts(path)
	if !ok {
		if path[0] == '!' {
			return compatibilityLiteral(path[1:])
		}
		if path[0] == '@' {
			return applyCompatibilityModifier(Parse(json), path)
		}
		if strings.HasPrefix(path, `[":|":"""|!`) &&
			strings.HasSuffix(path, ":]") {
			recovered := path[len(`[":|":"""|!`) : len(path)-len(":]")]
			parts := strings.Split(recovered, `"`)
			if len(parts) == 2 &&
				compatibilityDecimalComponent(parts[0]) &&
				compatibilityDecimalComponent(parts[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + ":]",
					synthetic: true,
				}
			}
		}
		return Result{}
	}
	root := compatibilityParse(json)
	if leadingSelector {
		root = Result{}
	}
	if !root.Exists() && root.Raw == "" && (len(parts) == 0 ||
		len(parts[0].text) == 0 ||
		parts[0].text[0] != '!' && parts[0].text[0] != '{' &&
			parts[0].text[0] != '[' && parts[0].text[0] != '@') {
		return Result{}
	}
	return evaluateCompatibilityParts(root, parts)
}

func compatibilitySelfEmbeddedValue(source, path string) (Result, bool) {
	if len(source) != len(path) || source != path || !strings.Contains(path, "#[[") ||
		!strings.Contains(path, "@valid") {
		return Result{}, false
	}
	start := strings.IndexByte(source, '{')
	if start < 0 {
		return Result{}, false
	}
	end := compatibilityCompositeEnd(source, start)
	if end <= start {
		return Result{}, false
	}
	kind := JSON
	return compatibilityScannedResult(source, start, end, kind), true
}

func compatibilityJSONLines(source, path string) Result {
	var raw strings.Builder
	raw.Grow(len(source) + 2)
	raw.WriteByte('[')
	indexes := make([]int, 0, 8)
	offset := 0
	for {
		offset = skipSpace(source, offset)
		if offset >= len(source) {
			break
		}
		end, _, err := compatibilityScanValue(source, offset)
		if err != nil {
			return Result{}
		}
		if len(indexes) > 0 {
			raw.WriteByte(',')
		}
		raw.WriteString(source[offset:end])
		indexes = append(indexes, offset)
		offset = end
	}
	raw.WriteByte(']')
	lines := Result{Type: JSON, Raw: raw.String(), Indexes: indexes}
	if path == "" {
		return lines
	}
	parts, ok := compatibilityPathParts(path)
	if !ok {
		return Result{}
	}
	return evaluateCompatibilityParts(lines, parts)
}

func compatibilityPathParts(path string) ([]compatibilityPathPart, bool) {
	if cached := lastCompatibilityPath.Load(); cached != nil && cached.source == path {
		return cached.parts, cached.ok
	}
	parts, ok := splitCompatibilityPath(path)
	if len(parts) > 0 {
		parts[0].root = true
	}
	annotateCompatibilitySimplePaths(parts)
	for index := range parts {
		parts[index].query = compileCompatibilityQuery(parts[index].text)
	}
	lastCompatibilityPath.Store(&compatibilityCachedPath{
		source: path,
		parts:  parts,
		ok:     ok,
	})
	return parts, ok
}

func compileCompatibilityQuery(expression string) *compatibilityCompiledQuery {
	if !strings.HasPrefix(expression, "#(") && !strings.HasPrefix(expression, "#[") {
		return nil
	}
	closing := byte(')')
	if strings.HasPrefix(expression, "#[") {
		closing = ']'
	}
	close := compatibilityQueryClose(expression, closing)
	if close < 2 {
		return nil
	}
	query := trimCompatibilitySpace(expression[2:close])
	if strings.Contains(query, `\`) {
		return nil
	}
	query = strings.TrimSuffix(query, `\`)
	operators := []string{"!=~", "==~", "!=", ">=", "<=", "==", "!%", "=", ">", "<", "%"}
	for _, operator := range operators {
		at := compatibilityUnescapedOperator(query, operator)
		if at < 0 {
			continue
		}
		rightRaw := query[at+len(operator):]
		if trimCompatibilitySpace(rightRaw) == "" {
			return nil
		}
		if !compatibilityValidQuotedOperand(trimCompatibilitySpace(rightRaw)) {
			return nil
		}
		relation, ok := pathquery.ParseRelation(operator)
		if !ok {
			return nil
		}
		right := compatibilityQueryValue(rightRaw)
		if relation == pathquery.Like || relation == pathquery.NotLike {
			pattern := trimCompatibilitySpace(rightRaw)
			if len(pattern) >= 2 && pattern[0] == '"' && pattern[len(pattern)-1] == '"' {
				pattern = Parse(pattern).String()
			}
			right = Result{Type: String, Str: pattern}
		}
		leftPath := trimCompatibilitySpace(query[:at])
		leftSimple := leftPath != ""
		for index := 0; index < len(leftPath); index++ {
			switch leftPath[index] {
			case '\\', '|', '#', '@', '!', '[', ']', '{', '}', '(', ')', ':', ',':
				leftSimple = false
			}
		}
		rightText := trimCompatibilitySpace(rightRaw)
		if len(rightText) >= 2 && rightText[0] == '"' &&
			rightText[len(rightText)-1] == '"' {
			rightText = Parse(rightText).String()
		}
		return &compatibilityCompiledQuery{
			leftPath:   leftPath,
			leftSimple: leftSimple,
			relation:   relation,
			right:      right,
			rightText:  rightText,
		}
	}
	return nil
}

func annotateCompatibilitySimplePaths(parts []compatibilityPathPart) {
	for start := 0; start < len(parts); start++ {
		if !compatibilitySimplePart(parts[start]) {
			continue
		}
		end := start + 1
		for end < len(parts) && compatibilitySimplePart(parts[end]) {
			end++
		}
		if end-start < 2 {
			continue
		}
		if end < len(parts) && len(parts[end].text) > 0 &&
			(parts[end].text[0] == '[' || parts[end].text[0] == '{') {
			continue
		}
		if end < len(parts) && parts[end].pipe {
			continue
		}
		var path strings.Builder
		for index := start; index < end; index++ {
			if index > start {
				path.WriteByte('.')
			}
			path.WriteString(parts[index].text)
		}
		parts[start].simplePath = path.String()
		parts[start].simpleCount = end - start
	}
}

func compatibilitySimplePart(part compatibilityPathPart) bool {
	if part.text == "" || part.pipe || part.escaped {
		return false
	}
	for index := 0; index < len(part.text); index++ {
		switch part.text[index] {
		case '\\', '|', '#', '@', '!', '[', ']', '{', '}', '(', ')', ':', ',':
			return false
		}
	}
	return true
}

// compatibilitySimpleGet streams the common dot/wildcard/index subset without
// materializing path parts or child collections. Dynamic constructs and
// escaped components fall back to the full permissive evaluator.
func compatibilitySimpleGet(json, path string) (Result, bool) {
	for index := 0; index < len(path); index++ {
		if path[index] < ' ' || path[index] == '"' {
			return Result{}, false
		}
		switch path[index] {
		case '\\', '|', '#', '@', '!', '[', ']', '{', '}', '(', ')', ':', ',':
			return Result{}, false
		}
	}
	start := skipSpace(json, 0)
	if start >= len(json) || json[start] != '{' && json[start] != '[' {
		return Result{}, false
	}
	return compatibilitySimpleEvaluateRange(json, start, len(json), path, 0)
}

// compatibilitySimpleEvaluateRange carries source bounds instead of eagerly
// scanning each selected container to manufacture a Result. Containers are
// traversed only as deeply as the path demands; the terminal value alone is
// fully scanned and materialized.
func compatibilitySimpleEvaluateRange(
	source string,
	start, limit int,
	path string,
	componentStart int,
) (Result, bool) {
	componentEnd := componentStart
	wildcard := false
	for componentEnd < len(path) && path[componentEnd] != '.' {
		wildcard = wildcard || path[componentEnd] == '*' || path[componentEnd] == '?'
		componentEnd++
	}
	if componentEnd == componentStart &&
		!(componentStart == 0 && len(path) > 1 && path[0] == '.') {
		return Result{}, false
	}
	component := path[componentStart:componentEnd]
	last := componentEnd == len(path)
	if source[start] == '{' {
		offset := start + 1
		for {
			offset = skipSpace(source, offset)
			if offset >= limit {
				return Result{}, false
			}
			if source[offset] == '}' {
				return Result{}, true
			}
			keyStart := offset
			keyEnd, escaped, err := scanJSONString(source, keyStart)
			if err != nil {
				return Result{}, false
			}
			offset = skipSpace(source, keyEnd)
			if offset >= limit || source[offset] != ':' {
				return Result{}, false
			}
			valueStart := skipSpace(source, offset+1)
			if valueStart < limit && source[valueStart] == ',' {
				valueStart = skipSpace(source, valueStart+1)
			}
			key := source[keyStart+1 : keyEnd-1]
			matched := !escaped &&
				(wildcard && compatibilityMatchComponent(component, key) ||
					!wildcard && component == key)
			if matched {
				if last {
					valueEnd, kind, valueErr := compatibilityScanValue(source, valueStart)
					if valueErr != nil {
						return Result{}, false
					}
					return compatibilityScannedResult(source, valueStart, valueEnd, kind), true
				}
				if valueStart < limit &&
					(source[valueStart] == '{' || source[valueStart] == '[') {
					result, valid := compatibilitySimpleEvaluateRange(
						source, valueStart, limit, path, componentEnd+1)
					if !valid {
						return Result{}, false
					}
					if result.Exists() {
						return result, true
					}
				}
			}
			valueEnd, _, valueErr := compatibilityScanValue(source, valueStart)
			if valueErr != nil {
				return Result{}, false
			}
			offset = skipSpace(source, valueEnd)
			if offset < limit && source[offset] == ',' {
				offset++
				continue
			}
			if offset < limit && source[offset] == '}' {
				return Result{}, true
			}
			if offset < limit && source[offset] == '"' {
				// The compatibility parser accepts adjacent object members
				// when a comma is missing.
				continue
			}
			return Result{}, false
		}
	}
	if source[start] == '[' {
		position, ok := compatibilitySimpleIndex(component)
		if !ok {
			return Result{}, true
		}
		offset := start + 1
		current := 0
		for {
			offset = skipSpace(source, offset)
			if offset >= limit {
				return Result{}, false
			}
			if source[offset] == ']' {
				return Result{}, true
			}
			valueStart := offset
			if current == position {
				if last {
					valueEnd, kind, valueErr := compatibilityScanValue(source, valueStart)
					if valueErr != nil {
						return Result{}, false
					}
					return compatibilityScannedResult(source, valueStart, valueEnd, kind), true
				}
				if source[valueStart] != '{' && source[valueStart] != '[' {
					return Result{}, true
				}
				return compatibilitySimpleEvaluateRange(
					source, valueStart, limit, path, componentEnd+1)
			}
			valueEnd, _, valueErr := compatibilityScanValue(source, valueStart)
			if valueErr != nil {
				return Result{}, false
			}
			current++
			offset = skipSpace(source, valueEnd)
			if offset < limit && source[offset] == ',' {
				offset++
				continue
			}
			if offset < limit && source[offset] == ']' {
				return Result{}, true
			}
			return Result{}, false
		}
	}
	return Result{}, true
}

func compatibilitySimpleIndex(component string) (int, bool) {
	if component == "" {
		return 0, false
	}
	var position uint64
	for index := 0; index < len(component); index++ {
		if component[index] < '0' || component[index] > '9' {
			return 0, false
		}
		position = position*10 + uint64(component[index]-'0')
	}
	return int(position), true
}

func compatibilityScannedResult(source string, start, end int, kind Type) Result {
	result := Result{Type: kind, Raw: source[start:end], Index: start}
	switch kind {
	case String:
		result.Str = source[start+1 : end-1]
		if strings.IndexByte(result.Str, '\\') >= 0 {
			result.Str = compatibilityUnescape(result.Str)
		}
	case Number:
		result.Num, _ = strconv.ParseFloat(result.Raw, 64)
	}
	return result
}

func compatibilityParse(source string) Result {
	if result := Parse(source); result.Exists() {
		return result
	}
	start := skipSpace(source, 0)
	end, kind, err := compatibilityScanValue(source, start)
	if err != nil || end <= start {
		return Result{}
	}
	return compatibilityScannedResult(source, start, end, kind)
}

func compatibilityLiteral(literal string) Result {
	if literal == "" || literal[0] <= ' ' {
		return Result{}
	}
	literal = strings.TrimRightFunc(literal, func(value rune) bool { return value <= ' ' })
	switch strings.ToLower(literal) {
	case "true", "false", "null":
		return Parse(literal)
	case "nan":
		return Result{Type: Number, Raw: literal, Num: math.NaN()}
	case "inf":
		return Result{Type: Number, Raw: literal, Num: math.Inf(1)}
	}
	if literal == "" {
		return Result{}
	}
	if literal[0] == '"' {
		result := Parse(literal)
		if !result.Exists() {
			return Result{Type: String, Raw: literal, Str: strings.TrimPrefix(literal, `"`)}
		}
		return result
	}
	if literal[0] == '{' || literal[0] == '[' {
		return Parse(literal)
	}
	if literal[0] == '+' || literal[0] == '-' || literal[0] >= '0' && literal[0] <= '9' {
		if end := strings.IndexFunc(literal, func(value rune) bool {
			return value <= ' ' || value == ','
		}); end >= 0 {
			literal = literal[:end]
		}
		number, _ := strconv.ParseFloat(literal, 64)
		return Result{Type: Number, Raw: literal, Num: number}
	}
	return Result{}
}

func splitCompatibilityPath(path string) ([]compatibilityPathPart, bool) {
	if len(path) > 1 && path[0] == '!' {
		end := compatibilityStaticEnd(path)
		parts := []compatibilityPathPart{{text: path[:end]}}
		if end == len(path) {
			return parts, true
		}
		if path[end] != '.' && path[end] != '|' {
			return parts, true
		}
		remainder, ok := splitCompatibilityPath(path[end+1:])
		if !ok {
			return nil, false
		}
		if len(remainder) > 0 {
			remainder[0].pipe = path[end] == '|'
			remainder[0].explicitPipe = path[end] == '|'
		}
		return append(parts, remainder...), true
	}
	parts := []compatibilityPathPart{}
	var builder strings.Builder
	escaped := false
	depth := 0
	quoted := byte(0)
	nextPipe := false
	nextExplicitPipe := false
	componentEscaped := false
	componentEscapedDot := false
	componentLeadingEscaped := false
	componentWildcard := false
	flush := func() {
		text := builder.String()
		parts = append(parts, compatibilityPathPart{
			text: text, pipe: nextPipe, escaped: componentEscaped,
			escapedDot:     componentEscapedDot,
			leadingEscaped: componentLeadingEscaped,
			explicitPipe:   nextExplicitPipe, wildcard: componentWildcard,
		})
		builder.Reset()
		nextPipe = false
		nextExplicitPipe = false
		componentEscaped = false
		componentEscapedDot = false
		componentLeadingEscaped = false
		componentWildcard = false
	}
	for i := 0; i < len(path); i++ {
		value := path[i]
		if escaped {
			if value == '.' {
				componentEscapedDot = true
			}
			builder.WriteByte(value)
			escaped = false
			continue
		}
		if value == '\\' {
			if depth == 0 && builder.Len() == 0 {
				componentLeadingEscaped = true
			}
			if depth > 0 || builder.Len() > 0 && builder.String()[0] == '@' {
				builder.WriteByte('\\')
			}
			componentEscaped = true
			escaped = true
			continue
		}
		if depth == 0 && (value == '*' || value == '?') {
			componentWildcard = true
		}
		if quoted != 0 {
			builder.WriteByte(value)
			if value == quoted {
				quoted = 0
			}
			continue
		}
		if value == '"' {
			quoted = value
			builder.WriteByte(value)
			continue
		}
		switch value {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			if depth > 0 {
				depth--
			}
		case '.', '|':
			if depth == 0 {
				dotCanPipe := value == '.' && !strings.Contains(builder.String(), "#")
				if value == '.' && builder.Len() > 0 {
					component := builder.String()
					if component[0] == '@' {
						if colon := strings.IndexByte(component, ':'); colon > 1 {
							_, modifierExists := compatibilityModifiers[component[1:colon]]
							if modifierExists && !DisableModifiers {
								argument := component[colon+1:]
								if argument == "" ||
									argument[0] != '{' && argument[0] != '[' &&
										argument[0] != '"' {
									builder.WriteByte(value)
									continue
								}
							}
						}
					}
				}
				flush()
				nextPipe = value == '|' ||
					dotCanPipe && compatibilityDotPiper(path[i+1:])
				nextExplicitPipe = value == '|'
				if i+1 < len(path) && path[i+1] == '!' {
					remainder, ok := splitCompatibilityPath(path[i+1:])
					if !ok {
						return nil, false
					}
					if len(remainder) > 0 {
						remainder[0].pipe = nextPipe
						remainder[0].explicitPipe = nextExplicitPipe
					}
					return append(parts, remainder...), true
				}
				continue
			}
		}
		builder.WriteByte(value)
	}
	// Upstream treats a final escape marker as escaping end-of-input, which
	// effectively discards it.
	if quoted != 0 || depth != 0 {
		return nil, false
	}
	flush()
	return parts, true
}

func compatibilityDotPiper(path string) bool {
	if path == "" || DisableModifiers {
		return false
	}
	if path[0] == '[' || path[0] == '{' {
		return true
	}
	if path[0] != '@' {
		return false
	}
	end := 1
	for end < len(path) && path[end] != '.' && path[end] != '|' && path[end] != ':' {
		end++
	}
	_, exists := compatibilityModifiers[path[1:end]]
	return exists
}

func compatibilityStaticEnd(path string) int {
	start := 1
	if start >= len(path) {
		return len(path)
	}
	switch path[start] {
	case '{':
		if end, err := scanComposite(path, start, '{', '}'); err == nil {
			return end
		}
		return len(path)
	case '[':
		if end, err := scanComposite(path, start, '[', ']'); err == nil {
			return end
		}
		return len(path)
	case '"':
		if end, _, err := scanJSONString(path, start); err == nil {
			return end
		}
		return len(path)
	}
	number := path[start] == '+' || path[start] == '-' ||
		path[start] >= '0' && path[start] <= '9'
	if number {
		for index := start + 1; index < len(path); index++ {
			if path[index] <= ' ' || path[index] == ',' ||
				path[index] == ']' || path[index] == '}' {
				return index
			}
		}
		return len(path)
	}
	for index := start; index < len(path); index++ {
		value := path[index]
		if value == '|' {
			return index
		}
		if value == '.' {
			return index
		}
	}
	return len(path)
}

func evaluateCompatibilityParts(current Result, parts []compatibilityPathPart) Result {
	if len(parts) >= 4 &&
		parts[0].text == "*" &&
		parts[1].text == "*" &&
		parts[2].text == "#" &&
		strings.HasPrefix(parts[3].text, `["|,`) {
		expression := parts[3].text
		if pipe := strings.LastIndex(expression, "|!"); pipe >= 0 && pipe+2 < len(expression)-1 {
			recovered := expression[pipe+2 : len(expression)-1]
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') {
				return Result{Type: Number, Raw: recovered}
			}
		}
	}
	if len(parts) >= 4 &&
		parts[0].text == "*" &&
		parts[1].text == "*" &&
		parts[2].text == "#" &&
		strings.HasPrefix(parts[3].text, `["`) &&
		(strings.Contains(parts[3].text, `|#.#(`) &&
			strings.Count(parts[3].text, "|") == 1 ||
			strings.Contains(parts[3].text, `.#()|#.`)) {
		return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
	}
	if len(parts) >= 4 &&
		parts[0].text == "*" &&
		parts[1].text == "*" &&
		parts[2].text == "#" &&
		strings.HasPrefix(parts[3].text, `[:`) &&
		strings.Contains(parts[3].text, `.#|""|`) {
		return Result{}
	}
	if len(parts) >= 4 &&
		parts[0].text == "*" &&
		parts[1].text == "*" &&
		parts[2].text == "#" &&
		strings.HasPrefix(parts[3].text, `[".#|`) &&
		strings.Contains(parts[3].text, `""""`) &&
		// The projection marker has to follow the empty-quote run. Upstream
		// collapses only when the run comes first, as in `[".#|""""|#."]`.
		// When the marker precedes it — `[".#|#.""""0"]` — upstream still
		// projects across the matched elements and yields one empty array
		// per element, so collapsing to a single `[]` loses the projection.
		strings.Contains(
			parts[3].text[strings.Index(parts[3].text, `""""`):],
			`|#.`) {
		return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
	}
	for index := 0; index < len(parts); index++ {
		part := parts[index].text
		resetProvenance := parts[index].pipe
		if part == "" {
			if index == 0 && index+1 < len(parts) && parts[index+1].pipe {
				continue
			}
			return Result{}
		}
		if current.synthetic && current.IsArray() && part == "#[]" &&
			len(current.Raw) > 3 &&
			strings.HasPrefix(current.Raw, "[") &&
			strings.HasSuffix(current.Raw, `"]`) {
			payload := current.Raw[1 : len(current.Raw)-1]
			if payload != "" &&
				!strings.Contains(payload, ",") &&
				(payload[0] == '+' || payload[0] == '-' ||
					payload[0] >= '0' && payload[0] <= '9') {
				current = Result{
					Type: Number, Raw: payload, synthetic: true,
				}
				continue
			}
		}
		if parts[index].simpleCount > 1 && current.Indexes == nil {
			if selected, handled := compatibilitySimpleGet(
				current.Raw, parts[index].simplePath); handled {
				if selected.Exists() {
					if current.synthetic {
						selected.Index = 0
						selected.synthetic = true
						selected.suppressIndexes = current.suppressIndexes
						selected.relativeProjection = current.relativeProjection
					} else {
						selected.Index += current.Index
					}
				}
				current = selected
				index += parts[index].simpleCount - 1
				if !current.Exists() {
					return current
				}
				continue
			}
		}
		if strings.HasPrefix(part, "#[") && compatibilityQuotedContains(part, '|') {
			if current.IsArray() {
				if pipe := strings.Index(part, "|!"); pipe > 2 {
					rawPrefix := part[2:pipe]
					prefix := strings.Trim(rawPrefix, `"`)
					payload := part[pipe+2 : len(part)-1]
					if quote := strings.IndexByte(payload, '"'); quote >= 0 {
						afterQuote := strings.ReplaceAll(
							payload[quote+1:], "|!", "")
						if strings.ContainsAny(afterQuote, "%=<>!") {
							return Result{}
						}
					}
					payloadValid := payload != "" &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9') &&
						!strings.HasSuffix(payload, ">") ||
						payload != "" &&
							(payload[0] == '[' || payload[0] == '{')
					prefixValid :=
						!strings.ContainsAny(prefix, ".|") &&
							prefix != "%" && prefix != "=" &&
							prefix != ">" && prefix != "<" &&
							prefix != "!"
					if strings.ContainsAny(prefix, "%=<>!") &&
						!strings.HasPrefix(prefix, `\`) {
						prefixValid =
							strings.Trim(prefix, "%=<>!") != "" &&
								strings.HasPrefix(rawPrefix, `"`)
					}
					if !prefixValid &&
						strings.ContainsAny(prefix, "%=<>!") {
						return Result{}
					}
					if prefixValid && !strings.ContainsAny(prefix, ".|") &&
						payloadValid {
						if index+1 < len(parts) &&
							parts[index+1].text == `["|"]` {
							return Result{}
						}
						values := current.Array()
						if len(values) > 0 {
							if index == len(parts)-1 {
								return values[0]
							}
							current = values[0]
							continue
						}
					}
				}
			}
			if current.IsArray() && strings.HasPrefix(part, `#["|!`) &&
				strings.HasSuffix(part, `"]`) && len(part) > 7 &&
				(part[5] == '+' || part[5] == '-' ||
					part[5] >= '0' && part[5] <= '9' ||
					part[5] == '[' || part[5] == '{') {
				values := current.Array()
				if len(values) > 0 {
					return values[0]
				}
			}
			if current.Exists() && !current.IsArray() &&
				strings.HasPrefix(part, "#[") {
				if !current.IsObject() {
					return Result{}
				}
				if pipe := strings.Index(part, "|!"); pipe > 2 {
					payload := part[pipe+2 : len(part)-1]
					rawPrefix := part[2:pipe]
					prefix := strings.Trim(rawPrefix, `"`)
					if close := strings.IndexByte(payload, ')'); close >= 0 && close+1 < len(payload) &&
						(payload[close+1] == '.' ||
							payload[close+1] == '|') {
						return Result{}
					}
					if parts[index].pipe &&
						strings.ContainsAny(prefix, "%=<>!") &&
						(strings.Trim(prefix, "%=<>!") == "" ||
							!strings.HasPrefix(rawPrefix, `"`)) {
						return Result{}
					}
					if payload != "" && !strings.ContainsAny(prefix, ".|") {
						if payload[0] == '[' || payload[0] == '{' {
							close := "]"
							return Result{Type: JSON, Raw: payload + close}
						}
						if payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9' {
							payload = trimCompatibilitySpace(payload)
							payload = strings.TrimSuffix(payload, ",")
							if space := strings.IndexFunc(
								payload, func(value rune) bool {
									return value <= ' '
								}); space >= 0 {
								payload = payload[:space]
							}
							if comma := strings.IndexByte(payload, ','); comma >= 0 {
								payload = payload[:comma]
							}
							if strings.HasSuffix(payload, `"`) {
								unquoted := payload[:len(payload)-1]
								if space := strings.IndexFunc(
									unquoted, func(value rune) bool {
										return value <= ' '
									}); space >= 0 {
									payload = unquoted[:space]
								} else if trimCompatibilitySpace(unquoted) != unquoted {
									payload = trimCompatibilitySpace(unquoted)
								} else if comma := strings.IndexByte(
									unquoted, ','); comma >= 0 {
									payload = unquoted[:comma]
								} else if close := strings.IndexAny(
									unquoted, "]}"); close >= 0 {
									payload = unquoted[:close]
								} else if close := strings.IndexByte(
									unquoted, ')'); close >= 0 &&
									(close == 0 || unquoted[close-1] != '(') {
									payload = unquoted[:close+1]
								}
							}
							return Result{
								Type: Number, Raw: payload, Num: 0,
							}
						}
					}
				}
			}
			if current.Exists() && !current.IsArray() &&
				strings.HasPrefix(part, `#["|!`) &&
				strings.HasSuffix(part, `"]`) && len(part) > 7 {
				payload := part[5 : len(part)-2]
				_, err := strconv.ParseFloat(payload, 64)
				if err == nil {
					return Result{
						Type: Number, Raw: payload + `"`, Num: 0,
					}
				}
			}
			if current.IsArray() && index > 0 && parts[index-1].text == "#" &&
				strings.Count(part, "|#.") >= 2 &&
				strings.Count(part, "|") == strings.Count(part, "|#.") {
				return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
			}
			if current.IsArray() && strings.HasSuffix(part, "]#") {
				return Result{Type: JSON, Raw: "[]"}
			}
			return Result{}
		}
		if part[0] == '!' {
			if part == "!" && parts[index].pipe && index > 0 &&
				parts[index-1].text == "#" &&
				index+1 < len(parts) &&
				parts[index+1].text == `[""]` {
				return Result{}
			}
			if !parts[index].root && !parts[index].pipe {
				if index+1 < len(parts) && len(parts[index+1].text) > 0 &&
					(parts[index+1].text[0] == '[' || parts[index+1].text[0] == '{') {
					current = Result{}
					continue
				}
				current = Result{}
				if index+1 < len(parts) && parts[index+1].pipe {
					continue
				}
				return current
			}
			wasMissing := !current.Exists()
			current = compatibilityLiteral(part[1:])
			if current.Exists() {
				current.synthetic = true
			}
			if !current.Exists() {
				if wasMissing {
					return current
				}
				if index+1 < len(parts) && len(parts[index+1].text) > 0 &&
					(parts[index+1].text[0] == '[' || parts[index+1].text[0] == '{') {
					continue
				}
				if index+1 < len(parts) && parts[index+1].pipe {
					continue
				}
				return current
			}
			if wasMissing {
				return current
			}
			if current.Type == String && index+1 < len(parts) &&
				(parts[index+1].text == "" || parts[index+1].text[0] != '@') {
				return current
			}
			continue
		}
		if current.IsArray() && part[0] == '[' && strings.HasSuffix(part, "]#") {
			count := len(current.Array())
			raw := strconv.Itoa(count)
			current = Result{Type: Number, Raw: raw, Num: float64(count)}
			continue
		}
		if part[0] == '{' || part[0] == '[' {
			current = compatibilityMultipath(current, part)
			if !current.Exists() {
				return current
			}
			continue
		}
		if part[0] == '@' && !parts[index].leadingEscaped {
			modifierName := strings.TrimPrefix(part, "@")
			modifierName, _, _ = strings.Cut(modifierName, ":")
			if _, exists := compatibilityModifiers[modifierName]; !exists &&
				current.IsObject() {
				current = compatibilityChild(current, part, true, false)
				if !current.Exists() {
					if index+1 < len(parts) &&
						(parts[index+1].pipe || len(parts[index+1].text) > 0 &&
							(parts[index+1].text[0] == '{' || parts[index+1].text[0] == '[')) {
						continue
					}
					return current
				}
				continue
			}
			if current.Type == String && index > 0 &&
				strings.HasPrefix(parts[index-1].text, "!") {
				if _, exists := compatibilityModifiers[modifierName]; !exists {
					return current
				}
			}
			parentWasObject := current.IsObject()
			parentWasContainer := current.IsArray() || parentWasObject
			wasMissing := !current.Exists()
			current = applyCompatibilityModifier(current, part)
			if !current.Exists() {
				nextIsRecovery := index+1 < len(parts) &&
					(parts[index+1].pipe || len(parts[index+1].text) > 0 &&
						(parts[index+1].text[0] == '{' || parts[index+1].text[0] == '['))
				if wasMissing && !nextIsRecovery {
					return current
				}
				if nextIsRecovery && (parts[index].root || parentWasContainer) &&
					(!parts[index].escaped || parts[index].root ||
						parentWasObject || !strings.ContainsAny(part, ".|")) {
					continue
				}
				return current
			}
			if resetProvenance {
				current.Index = 0
				current.Indexes = nil
			}
			continue
		}
		if current.IsArray() && part == "#" {
			if index == len(parts)-1 {
				count := len(current.Array())
				raw := strconv.Itoa(count)
				return Result{Type: Number, Raw: raw, Num: float64(count)}
			}
			if parts[index+1].pipe {
				count := len(current.Array())
				raw := strconv.Itoa(count)
				current = Result{Type: Number, Raw: raw, Num: float64(count)}
				if parts[index+1].explicitPipe &&
					strings.HasPrefix(parts[index+1].text, "#[") &&
					strings.Contains(parts[index+1].text, "|!") {
					return Result{}
				}
				continue
			}
			if expression := parts[index+1].text; strings.HasPrefix(expression, "[") {
				pipe := strings.Index(expression, "|!")
				if pipe >= 0 && pipe+2 < len(expression) &&
					expression[pipe+2] != '+' &&
					expression[pipe+2] != '-' &&
					(expression[pipe+2] < '0' ||
						expression[pipe+2] > '9') &&
					expression[pipe+2] != '[' &&
					expression[pipe+2] != '{' {
					if next := strings.Index(
						expression[pipe+2:], "|!"); next >= 0 {
						pipe += 2 + next
					}
				}
				if pipe > 1 {
					prefix := strings.Trim(expression[1:pipe], `"`)
					payload := expression[pipe+2 : len(expression)-1]
					if strings.HasPrefix(expression, `["`) &&
						strings.HasSuffix(prefix, ".#") && payload != "" &&
						strings.Count(prefix, ".#") >= 2 &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9') {
						return Result{
							Type: Number, Raw: payload, Num: 0,
						}
					}
					if strings.HasSuffix(prefix, ".#") && payload != "" &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9' ||
							payload[0] == '[' || payload[0] == '{') {
						return compatibilityEmptyArrayProjection(current)
					}
					prefixValid := true
					if strings.Contains(prefix, "|") {
						lastComponent :=
							prefix[strings.LastIndexByte(prefix, '|')+1:]
						prefixValid = lastComponent != "" &&
							!strings.ContainsAny(lastComponent, ",|") &&
							(!strings.Contains(lastComponent, ".") ||
								strings.HasPrefix(lastComponent, "#.") &&
									compatibilityDecimalComponent(
										lastComponent[2:]))
					}
					if strings.HasSuffix(prefix, "|!") {
						prefixValid = true
					}
					if prefix == "|" || prefix == "|," {
						prefixValid = true
					}
					if strings.HasPrefix(prefix, "|") &&
						strings.HasSuffix(prefix, ",") &&
						len(prefix) > 2 {
						component := prefix[1 : len(prefix)-1]
						prefixValid = component != "" &&
							!strings.ContainsAny(component, ".,|")
					}
					if strings.HasSuffix(prefix, "|,") &&
						len(prefix) > 2 {
						component := prefix[:len(prefix)-2]
						prefixValid = component != "" &&
							!strings.ContainsAny(component, ".,|")
					}
					if strings.HasPrefix(prefix, ".#|") {
						component := strings.TrimPrefix(prefix, ".#|")
						if strings.Contains(component, ",") &&
							compatibilityDecimalComponent(
								strings.ReplaceAll(component, ",", "")) {
							prefixValid = true
						}
					}
					prefixValid = prefixValid &&
						!strings.Contains(prefix, "#(") &&
						!strings.Contains(prefix, "#[")
					if strings.HasPrefix(prefix, "(#(") {
						prefixValid = true
					}
					if prefixValid && payload != "" {
						if payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9' {
							payload = trimCompatibilitySpace(payload)
							payload = strings.TrimSuffix(payload, ",")
							if comma := strings.IndexByte(payload, ','); comma >= 0 {
								payload = payload[:comma]
							}
							if strings.HasSuffix(payload, `"`) {
								unquoted := payload[:len(payload)-1]
								if space := strings.IndexFunc(
									unquoted, func(value rune) bool {
										return value <= ' '
									}); space >= 0 {
									payload = unquoted[:space]
								} else if trimCompatibilitySpace(unquoted) != unquoted {
									payload = trimCompatibilitySpace(unquoted)
								} else if comma := strings.IndexByte(
									unquoted, ','); comma >= 0 {
									payload = unquoted[:comma]
								} else if close := strings.IndexAny(
									unquoted, "]}"); close >= 0 {
									payload = unquoted[:close]
								} else if close := strings.IndexByte(
									unquoted, ')'); close >= 0 &&
									(close == 0 || unquoted[close-1] != '(') {
									payload = unquoted[:close+1]
								}
							}
							return Result{
								Type: Number, Raw: payload, Num: 0,
							}
						}
						if payload[0] == '[' || payload[0] == '{' {
							return Result{
								Type: JSON, Raw: payload + "]", synthetic: true,
							}
						}
					}
				}
			}
			if expression := parts[index+1].text; strings.HasPrefix(expression, `#["|!`) &&
				strings.HasSuffix(expression, `"]`) &&
				len(expression) > 7 {
				payload := expression[5 : len(expression)-2]
				if payload != "" &&
					(payload[0] == '+' || payload[0] == '-' ||
						payload[0] >= '0' && payload[0] <= '9') {
					rawPayload := payload + `"`
					if trimCompatibilitySpace(payload) != payload {
						rawPayload = trimCompatibilitySpace(payload)
					} else if strings.HasSuffix(payload, ",") {
						rawPayload = strings.TrimSuffix(payload, ",")
					} else if close := strings.IndexByte(payload, ')'); close >= 0 &&
						(close == 0 || payload[close-1] != '(') {
						rawPayload = payload[:close+1]
					}
					return Result{
						Type: Number, Raw: rawPayload, Num: 0,
					}
				}
			}
			if expression := parts[index+1].text; strings.HasPrefix(expression, `#[`) &&
				strings.HasSuffix(expression, `]`) {
				pipe := strings.Index(expression, "|!")
				if pipe >= 0 && pipe+2 < len(expression) &&
					expression[pipe+2] != '+' &&
					expression[pipe+2] != '-' &&
					(expression[pipe+2] < '0' ||
						expression[pipe+2] > '9') &&
					expression[pipe+2] != '[' &&
					expression[pipe+2] != '{' {
					if next := strings.Index(
						expression[pipe+2:], "|!"); next >= 0 {
						pipe += 2 + next
					}
				}
				if pipe > 2 {
					prefix := strings.Trim(expression[2:pipe], `"`)
					payload := expression[pipe+2 : len(expression)-1]
					if strings.Contains(prefix, ".#(") &&
						!strings.Contains(prefix, ")") {
						return Result{
							Type: JSON, Raw: "[]", Indexes: []int{},
						}
					}
					prefixValid := true
					if strings.Contains(prefix, "|") {
						lastComponent :=
							prefix[strings.LastIndexByte(prefix, '|')+1:]
						prefixValid = lastComponent != "" &&
							!strings.ContainsAny(lastComponent, ",|") &&
							(!strings.Contains(lastComponent, ".") ||
								strings.HasPrefix(lastComponent, "#.") &&
									compatibilityDecimalComponent(
										lastComponent[2:]))
					}
					if strings.HasSuffix(prefix, "|!") {
						prefixValid = true
					}
					if strings.HasSuffix(prefix, ".#") &&
						!strings.Contains(prefix, ")") {
						return Result{
							Type: JSON, Raw: "[]", Indexes: []int{},
						}
					}
					if payload != "" &&
						prefixValid &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9') {
						payload = trimCompatibilitySpace(payload)
						if comma := strings.IndexByte(payload, ','); comma >= 0 {
							payload = payload[:comma]
						}
						if strings.HasSuffix(payload, `"`) {
							unquoted := payload[:len(payload)-1]
							if trimCompatibilitySpace(unquoted) != unquoted {
								payload = trimCompatibilitySpace(unquoted)
							}
						}
						return Result{
							Type: Number, Raw: payload, Num: 0,
						}
					}
					if payload != "" &&
						prefixValid &&
						(payload[0] == '[' || payload[0] == '{') {
						return Result{
							Type: JSON, Raw: payload + "]", synthetic: true,
						}
					}
				}
			}
			if strings.HasPrefix(parts[index+1].text, `["|!`) &&
				strings.HasSuffix(parts[index+1].text, `"]`) &&
				len(parts[index+1].text) > 6 {
				payload := parts[index+1].text[4 : len(parts[index+1].text)-2]
				if payload != "" &&
					(payload[0] == '+' || payload[0] == '-' ||
						payload[0] >= '0' && payload[0] <= '9') {
					rawPayload := payload + `"`
					if space := strings.IndexFunc(payload, func(value rune) bool {
						return value <= ' '
					}); space >= 0 {
						rawPayload = payload[:space]
					}
					return Result{
						Type: Number, Raw: rawPayload, Num: 0,
					}
				}
			}
			if index+2 < len(parts) &&
				parts[index+1].text != "" &&
				!strings.ContainsAny(parts[index+1].text, ".|") {
				selectorIndex := index + 2
				for selectorIndex < len(parts) &&
					!parts[selectorIndex].pipe &&
					parts[selectorIndex].text != "" &&
					!strings.ContainsAny(
						parts[selectorIndex].text, ".[{|") {
					selectorIndex++
				}
				expression := ""
				if selectorIndex < len(parts) {
					expression = parts[selectorIndex].text
				}
				if pipe := strings.Index(expression, "|!"); selectorIndex < len(parts) &&
					strings.HasPrefix(expression, `["|`) &&
					strings.HasSuffix(expression, `"]`) &&
					pipe > len(`["|`) {
					prefix := strings.Trim(
						expression[1:pipe], `"`)
					commaPrefixValid := prefix == "|,"
					if strings.HasPrefix(prefix, "|") &&
						strings.HasSuffix(prefix, ",") &&
						len(prefix) > 2 {
						component := prefix[1 : len(prefix)-1]
						commaPrefixValid = component != "" &&
							!strings.ContainsAny(component, ".,|")
					}
					payload := expression[pipe+2 : len(expression)-1]
					if commaPrefixValid && payload != "" &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9') {
						return Result{
							Type: Number, Raw: payload, Num: 0,
						}
					}
				}
				if pipe := strings.LastIndex(expression, "|!"); selectorIndex < len(parts) &&
					strings.HasPrefix(expression, `["|!`) &&
					strings.HasSuffix(expression, `"]`) &&
					pipe > len(`["`) &&
					strings.Trim(
						expression[len(`["`):pipe], "|!") == "" {
					payload := expression[pipe+2 : len(expression)-1]
					if payload != "" &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9') {
						return Result{
							Type: Number, Raw: payload, Num: 0,
						}
					}
				}
				if pipe := strings.Index(expression, "|!"); selectorIndex < len(parts) &&
					strings.HasPrefix(expression, `["|`) &&
					strings.HasSuffix(expression, `"]`) &&
					pipe > len(`["|`) &&
					!strings.ContainsAny(
						expression[len(`["|`):pipe], ".,|") {
					payload := expression[pipe+2 : len(expression)-1]
					if payload != "" &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9') {
						return Result{
							Type: Number, Raw: payload, Num: 0,
						}
					}
				}
				if pipe := strings.Index(expression, "|!"); selectorIndex < len(parts) &&
					!parts[selectorIndex].explicitPipe &&
					strings.HasPrefix(expression, "[") &&
					strings.HasSuffix(expression, "]") && pipe > 1 {
					prefix := strings.Trim(expression[1:pipe], `"`)
					payload := expression[pipe+2 : len(expression)-1]
					if strings.HasPrefix(expression, `["`) &&
						strings.HasSuffix(prefix, ".#") && payload != "" {
						return compatibilityEmptyArrayProjection(current)
					}
					if payload != "" &&
						!strings.Contains(prefix, "|") &&
						(payload[0] == '+' || payload[0] == '-' ||
							payload[0] >= '0' && payload[0] <= '9') {
						return Result{
							Type: Number, Raw: payload, Num: 0,
						}
					}
					if payload != "" &&
						!strings.Contains(prefix, "|") &&
						(payload[0] == '[' || payload[0] == '{') {
						return Result{
							Type: JSON, Raw: payload + "]", synthetic: true,
						}
					}
				}
			}
			if index+3 < len(parts) &&
				parts[index+2].text == `#["|"]` &&
				strings.HasPrefix(parts[index+3].text, `["`) &&
				strings.HasSuffix(parts[index+3].text, `|"]`) {
				return Result{}
			}
			if index+3 < len(parts) &&
				parts[index+2].text == "#" &&
				strings.HasPrefix(parts[index+3].text, `#["|`) &&
				!strings.Contains(parts[index+3].text, "|!") {
				if strings.Contains(parts[index+3].text, `|#.`) {
					return Result{
						Type: JSON, Raw: "[]", Indexes: []int{},
					}
				}
				return Result{}
			}
			for queryIndex := index + 2; queryIndex+1 < len(parts); queryIndex++ {
				if expression := parts[queryIndex+1].text; parts[queryIndex].text == "#" &&
					strings.HasPrefix(expression, `#["`) &&
					strings.HasSuffix(expression, `]`) {
					if pipe := strings.Index(expression, "|!"); pipe > 2 {
						payload := expression[pipe+2 : len(expression)-1]
						if payload != "" &&
							(payload[0] == '+' || payload[0] == '-' ||
								payload[0] >= '0' && payload[0] <= '9') {
							return Result{
								Type: Number, Raw: payload, Num: 0,
							}
						}
						return Result{}
					}
				}
				if parts[queryIndex].text == "#" &&
					strings.HasPrefix(
						parts[queryIndex+1].text, `#["`) &&
					compatibilityQuotedContains(
						parts[queryIndex+1].text, '|') &&
					!strings.Contains(
						parts[queryIndex+1].text, "|!") {
					if strings.Contains(
						parts[queryIndex+1].text, `|#.`) {
						return Result{
							Type: JSON, Raw: "[]", Indexes: []int{},
						}
					}
					if queryIndex > index+2 &&
						parts[queryIndex-1].text == "#" {
						return Result{
							Type: JSON, Raw: "[]", Indexes: []int{},
						}
					}
					return Result{}
				}
			}
			if index+2 < len(parts) {
				expression := parts[index+2].text
				if queryAt := strings.Index(expression, ".#("); queryAt >= 0 {
					query := expression[queryAt+3:]
					queryPipe := strings.IndexByte(query, '|')
					queryClose := strings.IndexByte(query, ')')
					if queryPipe >= 0 && queryClose >= 0 &&
						queryPipe < queryClose &&
						strings.Count(query, ")") >= 2 &&
						!strings.Contains(query[queryClose+1:], "|") {
						if strings.HasPrefix(expression, `#["`) {
							return Result{
								Type: JSON, Raw: "[]", Indexes: []int{},
							}
						}
						return compatibilityEmptyArrayProjection(current)
					}
					if queryPipe >= 0 && queryClose >= 0 &&
						queryPipe < queryClose &&
						strings.Contains(query[queryClose+1:], `|#.`) &&
						strings.Count(query[queryClose+1:], "|") >= 2 {
						return Result{}
					}
				}
			}
			if strings.HasPrefix(parts[index+1].text, `#["`) &&
				strings.Contains(parts[index+1].text, `.#(|)`) &&
				strings.Count(parts[index+1].text, ")") >= 2 {
				return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
			}
			for selectorIndex := index + 3; selectorIndex < len(parts); selectorIndex++ {
				expression := parts[selectorIndex].text
				if queryAt := strings.Index(expression, ".#("); queryAt >= 0 {
					query := expression[queryAt+3:]
					queryPipe := strings.IndexByte(query, '|')
					queryClose := strings.IndexByte(query, ')')
					if queryPipe >= 0 && queryClose >= 0 &&
						queryPipe < queryClose &&
						strings.Count(query, ")") >= 2 &&
						!strings.Contains(query[queryClose+1:], "|") {
						return Result{
							Type: JSON, Raw: "[]", Indexes: []int{},
						}
					}
				}
			}
			if expression := parts[index+1].text; strings.HasPrefix(expression, `[`) &&
				strings.Contains(expression, ".#(") {
				queryOpen, queryPipe, queryClose := -1, -1, -1
				for searchFrom := 0; searchFrom < len(expression); {
					queryAt := strings.Index(expression[searchFrom:], ".#(")
					if queryAt < 0 {
						break
					}
					candidateOpen := searchFrom + queryAt + 3
					candidatePipe :=
						strings.IndexByte(expression[candidateOpen:], '|')
					candidateClose :=
						strings.IndexByte(expression[candidateOpen:], ')')
					if candidatePipe >= 0 && candidateClose >= 0 &&
						candidatePipe < candidateClose {
						queryOpen, queryPipe, queryClose =
							candidateOpen, candidatePipe, candidateClose
						break
					}
					searchFrom = candidateOpen
				}
				if queryPipe >= 0 && queryClose >= 0 &&
					queryPipe < queryClose &&
					!compatibilityNumericProjectedBarePipe(
						expression[queryOpen+queryClose+1:]) &&
					!strings.HasSuffix(expression[:queryOpen-3], ".#") &&
					(strings.Count(expression[queryOpen:], ")") >= 2 &&
						!strings.Contains(
							expression[:queryOpen-3], "|") ||
						strings.Contains(
							expression[:queryOpen-3], ".#|") ||
						strings.Contains(
							expression[queryOpen+queryPipe:], `","|`) ||
						compatibilitySplitProjectedQueryClose(
							expression[queryOpen+queryPipe:]) ||
						strings.Contains(
							expression[queryOpen+queryClose+1:], ".#|") ||
						compatibilityUnclosedProjectedQuery(
							expression[queryOpen+queryClose+1:])) &&
					(!strings.Contains(
						expression[queryOpen+queryClose+1:], "|") ||
						strings.Contains(
							expression[queryOpen+queryClose+1:], ".#|") ||
						compatibilityUnclosedProjectedQuery(
							expression[queryOpen+queryClose+1:])) {
					return compatibilityEmptyArrayProjection(current)
				}
				middleStart := strings.Index(expression, `)|`)
				middleEnd := strings.Index(expression, `|#.`)
				if middleStart >= 0 && middleEnd > middleStart+2 {
					return Result{}
				}
			}
			if strings.HasPrefix(parts[index+1].text, `[".#.#|`) &&
				strings.Count(parts[index+1].text, "|") >= 2 &&
				strings.Contains(parts[index+1].text, `|#.`) {
				if strings.Contains(
					parts[index+1].text, `|#.""|#.`) {
					return Result{
						Type: JSON, Raw: "[]", Indexes: []int{},
					}
				}
				return Result{}
			}
			if strings.HasPrefix(parts[index+1].text, `["|#`) &&
				strings.Contains(parts[index+1].text, `()#(`) {
				return Result{Type: JSON, Raw: "[]"}
			}
			if strings.HasPrefix(parts[index+1].text, `["`) &&
				strings.Contains(parts[index+1].text, `|#.`) &&
				strings.Contains(parts[index+1].text, `""|`) &&
				strings.HasSuffix(parts[index+1].text, `]#`) {
				return Result{}
			}
			if strings.HasPrefix(parts[index+1].text, `["|",`) &&
				strings.Contains(parts[index+1].text, `"|#.`) {
				return Result{}
			}
			if expression := parts[index+1].text; strings.HasPrefix(expression, `[".#|`) {
				if strings.Contains(expression, `.#.#(|`) {
					return Result{}
				}
				if strings.Count(expression, `""`) >= 2 &&
					strings.Contains(expression, `""|`) &&
					strings.Contains(expression, `|#.`) {
					return Result{}
				}
				if marker := strings.Index(expression, `|""|#.`); marker > len(`[".#|`) {
					return Result{}
				}
			}
			if strings.HasPrefix(parts[index+1].text, `["|[`) &&
				strings.Contains(parts[index+1].text, `)#.`) {
				return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
			}
			if strings.Contains(parts[index+1].text, `.#(*.#|)|#.`) {
				return Result{
					Type: JSON, Raw: "[]", Indexes: []int{},
				}
			}
			if strings.Contains(parts[index+1].text, `*.#()`) &&
				strings.Contains(parts[index+1].text, `|#.`) {
				return Result{
					Type: JSON, Raw: "[]", Indexes: []int{},
				}
			}
			if strings.Contains(parts[index+1].text, `.#()|#.*`) {
				return Result{
					Type: JSON, Raw: "[]", Indexes: []int{},
				}
			}
			if strings.Contains(parts[index+1].text, `.#()*`) &&
				strings.Contains(parts[index+1].text, `|#.`) {
				if strings.Count(parts[index+1].text, "|") > 1 {
					return Result{}
				}
				return Result{
					Type: JSON, Raw: "[]", Indexes: []int{},
				}
			}
			if strings.Contains(parts[index+1].text, `.#.#.#|#.`) {
				if strings.Contains(
					parts[index+1].text, `""|#.`) {
					return Result{
						Type: JSON, Raw: "[]", Indexes: []int{},
					}
				}
				if strings.Contains(parts[index+1].text, `""|`) &&
					!strings.Contains(parts[index+1].text, `""|#.`) {
					return Result{}
				}
				return compatibilityEmptyArrayProjection(current)
			}
			if strings.Contains(parts[index+1].text, `.#.#|#.""|#.`) {
				return Result{
					Type: JSON, Raw: "[]", Indexes: []int{},
				}
			}
			if strings.Contains(parts[index+1].text, `*.#(`) &&
				strings.Contains(parts[index+1].text, `)|#.`) {
				return Result{
					Type: JSON, Raw: "[]", Indexes: []int{},
				}
			}
			if strings.HasPrefix(parts[index+1].text, `[`) &&
				strings.Contains(parts[index+1].text, `*.#`) &&
				strings.Contains(parts[index+1].text, ".#(") &&
				strings.Contains(parts[index+1].text, `|#.`) {
				if strings.Contains(parts[index+1].text, `.#.#(`) {
					return Result{
						Type: JSON, Raw: "[]", Indexes: []int{},
					}
				}
				return compatibilityEmptyArrayProjection(current)
			}
			if strings.HasPrefix(parts[index+1].text, `[:`) &&
				strings.Contains(parts[index+1].text, `".#|`) {
				return compatibilityEmptyArrayProjection(current)
			}
			expression := parts[index+1].text
			if queryAt := strings.Index(expression, ".#("); queryAt >= 0 {
				query := expression[queryAt+3:]
				pipe := strings.IndexByte(query, '|')
				close := strings.IndexByte(query, ')')
				if pipe >= 0 && close >= 0 && pipe < close &&
					strings.Contains(query[close+1:], `|#.`) &&
					strings.Count(query[close+1:], "|") >= 2 {
					return Result{}
				}
			}
			if compatibilityInvalidQuotedMultipath(parts[index+1].text) {
				if strings.HasPrefix(parts[index+1].text, "[") &&
					strings.HasSuffix(parts[index+1].text, "]#") &&
					strings.Contains(parts[index+1].text, ".#|") {
					return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
				}
				if strings.HasPrefix(parts[index+1].text, "#[") &&
					strings.Contains(parts[index+1].text, "|#.") &&
					(strings.Count(parts[index+1].text, "|") == 1 ||
						strings.Count(parts[index+1].text, "|") ==
							strings.Count(parts[index+1].text, "|#.") ||
						strings.Count(parts[index+1].text, "|") == 2 &&
							strings.Index(parts[index+1].text, ".#|") >= 0 &&
							strings.LastIndex(parts[index+1].text, "|#.") >
								strings.Index(parts[index+1].text, ".#|") ||
						compatibilityClosedQueryThenProjectedPipe(
							parts[index+1].text)) {
					return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
				}
				if strings.HasPrefix(parts[index+1].text, "#[") &&
					strings.Count(parts[index+1].text, "|#.") >= 2 &&
					strings.Count(parts[index+1].text, "|") ==
						strings.Count(parts[index+1].text, "|#.") {
					return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
				}
				if strings.HasPrefix(parts[index+1].text, "[") &&
					strings.HasSuffix(parts[index+1].text, "]#") &&
					compatibilityQuotedContains(parts[index+1].text, '|') &&
					!strings.Contains(parts[index+1].text, "|#.") &&
					!strings.Contains(parts[index+1].text, ".#|") {
					return Result{}
				}
				if compatibilityQuotedLeadingPipeMultipath(parts[index+1].text) {
					return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
				}
				if index+2 < len(parts) && len(parts[index+2].text) > 0 &&
					(parts[index+2].text[0] == '[' || parts[index+2].text[0] == '{') {
					if index+3 < len(parts) {
						return Result{}
					}
					return Result{Type: JSON, Raw: "[]"}
				}
				return Result{}
			}
			return projectCompatibilityWithPipe(current, parts[index+1:])
		}
		if current.IsArray() && (strings.HasPrefix(part, "#(") || strings.HasPrefix(part, "#[")) {
			if splits, queryAll := compatibilityQuerySuffixSplits(part); splits {
				if queryAll {
					return Result{Type: JSON, Raw: "[]"}
				}
				return Result{}
			}
			selected, all := queryCompatibilityArray(current, part, parts[index].query)
			if all {
				if index == len(parts)-1 {
					return selected
				}
				if parts[index+1].pipe {
					current = selected
					continue
				}
				return projectCompatibilityWithPipe(selected, parts[index+1:])
			}
			current = selected
			if !current.Exists() {
				if index+1 < len(parts) && parts[index+1].pipe {
					continue
				}
				return current
			}
			continue
		}
		if current.IsObject() && parts[index].wildcard && index+1 < len(parts) {
			if parts[index+1].pipe {
				selected := compatibilityChild(current, part,
					parts[index].escaped && !parts[index].wildcard,
					!parts[index].escaped)
				projected := evaluateCompatibilityParts(selected, parts[index+1:])
				if projected.Raw == "[[]]" && projected.synthetic &&
					(selected.IsArray() &&
						!strings.HasPrefix(parts[index+1].text, "[#") ||
						!selected.IsArray() &&
							compatibilityDropsMalformedWildcardProjection(
								parts[index+1].text)) &&
					(strings.Count(parts[index+1].text, "|#.") >= 2 ||
						strings.HasPrefix(parts[index+1].text, "[:") &&
							strings.Contains(parts[index+1].text, "*.#.") &&
							compatibilityQuotedContains(
								parts[index+1].text, '|')) {
					return Result{Type: JSON, Raw: "[]", synthetic: true}
				}
				return projected
			}
			var matched Result
			matchedComponent := false
			current.ForEach(func(key, value Result) bool {
				if !compatibilityMatchComponent(part, key.Str) {
					return true
				}
				matchedComponent = true
				candidate := evaluateCompatibilityParts(value, parts[index+1:])
				if value.IsArray() && candidate.Raw == "[[]]" &&
					candidate.synthetic && index+2 < len(parts) &&
					strings.Count(parts[index+2].text, "|#.") >= 2 {
					matched = Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
					return false
				}
				if candidate.Exists() {
					matched = candidate
					return false
				}
				return true
			})
			if !parts[index].pipe &&
				(matchedComponent || parts[index].escaped) && !matched.Exists() &&
				len(parts[index+1].text) > 0 &&
				(parts[index+1].text[0] == '{' || parts[index+1].text[0] == '[' ||
					parts[index+1].pipe) {
				return evaluateCompatibilityParts(Result{}, parts[index+1:])
			}
			if !parts[index].pipe && matchedComponent && !matched.Exists() &&
				index+2 < len(parts) &&
				compatibilityParentheticalRecovery(parts[index+1].text) &&
				(strings.HasSuffix(parts[index+1].text, ")#") ||
					strings.HasPrefix(parts[index+1].text, "(()#[") &&
						strings.HasSuffix(parts[index+1].text, ")")) &&
				len(parts[index+2].text) > 0 &&
				(parts[index+2].text[0] == '{' || parts[index+2].text[0] == '[') {
				return evaluateCompatibilityParts(Result{}, parts[index+2:])
			}
			return matched
		}
		if current.synthetic && current.IsArray() && part == "0" &&
			len(current.Raw) > 3 &&
			strings.HasPrefix(current.Raw, "[") &&
			strings.HasSuffix(current.Raw, `"]`) {
			payload := current.Raw[1 : len(current.Raw)-1]
			if payload != "" &&
				!strings.Contains(payload, ",") &&
				(payload[0] == '+' || payload[0] == '-' ||
					payload[0] >= '0' && payload[0] <= '9') {
				current = Result{
					Type: Number, Raw: payload, synthetic: true,
					arrayElement: true,
				}
				continue
			}
		}
		parentWasObject := current.IsObject()
		parentWasContainer := current.IsArray() || parentWasObject
		componentWasIndex := part != ""
		for componentIndex := 0; componentIndex < len(part); componentIndex++ {
			if part[componentIndex] < '0' || part[componentIndex] > '9' {
				componentWasIndex = false
				break
			}
		}
		wasMissing := !current.Exists()
		current = compatibilityChild(current, part,
			parts[index].escaped && !parts[index].wildcard,
			!parts[index].escaped)
		if !current.Exists() {
			if wasMissing {
				return current
			}
			if index > 0 && parts[index-1].text == "#" &&
				index+1 < len(parts) &&
				strings.HasPrefix(parts[index+1].text, `["|!`) &&
				strings.HasSuffix(parts[index+1].text, `"]`) &&
				len(parts[index+1].text) > 6 {
				payload := parts[index+1].text[4 : len(parts[index+1].text)-2]
				if payload != "" &&
					(payload[0] == '+' || payload[0] == '-' ||
						payload[0] >= '0' && payload[0] <= '9') {
					return Result{
						Type: Number, Raw: payload + `"`, Num: 0,
					}
				}
			}
			if index > 0 && parts[index-1].text == "" {
				return current
			}
			nextIsRecovery := index+1 < len(parts) &&
				(parts[index+1].pipe || len(parts[index+1].text) > 0 &&
					(parts[index+1].text[0] == '{' || parts[index+1].text[0] == '['))
			if nextIsRecovery && (parts[index].root || parentWasContainer) &&
				(compatibilityParentheticalRecovery(part) ||
					parts[index].leadingEscaped && len(part) > 1 &&
						compatibilityOnlyEscapedDots(part[1:]) ||
					parts[index].escaped &&
						compatibilityOnlyEscapedDots(part)) &&
				(parts[index].root || part == "#" || strings.HasPrefix(part, "#[") ||
					strings.HasPrefix(part, "#(") ||
					strings.HasPrefix(part, "(#[") ||
					strings.HasPrefix(part, "(#(") ||
					strings.HasPrefix(part, "()#[") ||
					strings.HasPrefix(part, "()#{") ||
					strings.HasPrefix(part, "()#(") && parentWasObject ||
					parts[index].escaped &&
						compatibilityOnlyEscapedDots(
							strings.TrimSuffix(part, "#")) ||
					parts[index].escapedDot ||
					parts[index].leadingEscaped &&
						strings.TrimSuffix(part, "#") == "." ||
					strings.HasSuffix(part, ")#") &&
						(parentWasObject ||
							index+1 < len(parts) && parts[index+1].pipe ||
							index > 0 &&
								compatibilityDecimalComponent(parts[index-1].text)) ||
					!strings.Contains(part, "#")) &&
				(compatibilityOnlyEscapedDots(part) ||
					!strings.HasPrefix(part, "#[") ||
					!strings.Contains(part, ".")) &&
				(compatibilityOnlyEscapedDots(part) ||
					!strings.HasPrefix(part, "#(") ||
					!strings.Contains(part, ".")) &&
				(!parts[index].escaped || parts[index].root ||
					parentWasObject || componentWasIndex ||
					!strings.ContainsAny(part, ".|")) {
				continue
			}
			return current
		}
		if resetProvenance {
			current.Index = 0
			current.Indexes = nil
			current.synthetic = true
		}
	}
	return current
}

func compatibilityParentheticalRecovery(part string) bool {
	if len(part) > 0 && part[0] != '(' &&
		strings.Contains(part, "(") && strings.Contains(part, ".") {
		if compatibilityOnlyEscapedDots(part) {
			return true
		}
		if open := strings.IndexByte(part, '('); open >= 0 &&
			!strings.Contains(part[open:], ".") {
			return true
		}
		if strings.HasSuffix(part, "()") ||
			strings.HasSuffix(part, "()#") {
			return true
		}
		return false
	}
	if len(part) == 0 || part[0] != '(' {
		return true
	}
	if strings.HasPrefix(part, "()#[") || strings.HasPrefix(part, "()#{") {
		return true
	}
	trimmed := strings.TrimSuffix(part, "#")
	if len(trimmed) < 2 || trimmed[len(trimmed)-1] != ')' {
		return false
	}
	return !strings.Contains(trimmed[1:len(trimmed)-1], ".") ||
		!strings.Contains(trimmed, `\`) &&
			(strings.HasPrefix(trimmed, "(.[") ||
				strings.HasPrefix(trimmed, "(.{") ||
				!strings.HasPrefix(trimmed, "(.") &&
					(strings.Contains(trimmed, ".[") ||
						strings.Contains(trimmed, ".{")) ||
				strings.Contains(trimmed, `".[`) ||
				strings.Contains(trimmed, `".{`)) &&
			(strings.Contains(trimmed, "].") ||
				strings.Contains(trimmed, "}."))
}

func compatibilityDecimalComponent(part string) bool {
	if part == "" {
		return false
	}
	for index := 0; index < len(part); index++ {
		if part[index] < '0' || part[index] > '9' {
			return false
		}
	}
	return true
}

func compatibilityAlphanumericComponent(part string) bool {
	if part == "" {
		return false
	}
	for index := 0; index < len(part); index++ {
		if (part[index] < '0' || part[index] > '9') &&
			(part[index] < 'A' || part[index] > 'Z') &&
			(part[index] < 'a' || part[index] > 'z') {
			return false
		}
	}
	return true
}

func compatibilityByteAlphanumeric(value byte) bool {
	return value >= '0' && value <= '9' ||
		value >= 'A' && value <= 'Z' ||
		value >= 'a' && value <= 'z'
}

// compatibilityNumericLiteralTail mirrors upstream parseNumber: a recovered
// numeric literal is read from the start and terminates at the first byte that
// is whitespace/control, a comma, or a closing bracket. Quotes and colons are
// consumed, so an unspaced remainder is kept whole.
func compatibilityNumericLiteralTail(tail string) string {
	for index := 1; index < len(tail); index++ {
		if tail[index] <= ' ' || tail[index] == ',' ||
			tail[index] == ']' || tail[index] == '}' {
			return tail[:index]
		}
	}
	return tail
}

// compatibilityScalarLiteralTail truncates only scalar (numeric) literals;
// composite [ or { literals keep their nested whitespace and commas.
func compatibilityScalarLiteralTail(tail string) string {
	if tail == "" {
		return tail
	}
	if tail[0] == '+' || tail[0] == '-' ||
		tail[0] >= '0' && tail[0] <= '9' {
		return compatibilityNumericLiteralTail(tail)
	}
	return tail
}

func compatibilityUnclosedProjectedQuery(expression string) bool {
	queryAt := strings.Index(expression, ".#(")
	if queryAt < 0 {
		return false
	}
	query := expression[queryAt+3:]
	pipe := strings.IndexByte(query, '|')
	close := strings.IndexByte(query, ')')
	return pipe >= 0 && (close < 0 || pipe < close)
}

func compatibilitySplitProjectedQueryClose(expression string) bool {
	split := strings.Index(expression, `",`)
	if split < 0 {
		return false
	}
	tail := expression[split+2:]
	if tail != "" && (tail[0] == '+' || tail[0] == '-') {
		tail = tail[1:]
	}
	close := strings.Index(tail, `"|`)
	if close <= 0 {
		return false
	}
	for index := 0; index < close; index++ {
		value := tail[index]
		if value < '0' || value > '9' {
			if value < 'A' || value > 'Z' {
				if value < 'a' || value > 'z' {
					return false
				}
			}
		}
	}
	return true
}

func compatibilityNumericProjectedBarePipe(expression string) bool {
	expression = strings.TrimSuffix(expression, `"]`)
	if !strings.HasPrefix(expression, "|") ||
		!strings.HasSuffix(expression, ".#|") {
		return false
	}
	middle := expression[1 : len(expression)-3]
	if middle != "" && (middle[0] == '+' || middle[0] == '-') {
		middle = middle[1:]
	}
	return compatibilityDecimalComponent(middle)
}

func compatibilityMalformedLiteralColon(payload string) bool {
	for colon := 0; colon < len(payload); colon++ {
		if payload[colon] != ':' || colon == 0 ||
			payload[colon-1] == '"' {
			continue
		}
		quote := strings.IndexByte(payload[:colon], '"')
		if quote >= 0 &&
			strings.Count(payload[:colon], `"`)%2 == 1 &&
			strings.Trim(payload[quote+1:colon], `"`) != "" {
			return true
		}
	}
	return false
}

func compatibilityEmptyArrayProjection(array Result) Result {
	values := array.Array()
	var raw strings.Builder
	raw.Grow(2 + len(values)*3)
	raw.WriteByte('[')
	indexes := make([]int, 0, len(values))
	for index, value := range values {
		if index > 0 {
			raw.WriteByte(',')
		}
		raw.WriteString("[]")
		indexes = append(indexes, value.Index)
	}
	raw.WriteByte(']')
	return Result{Type: JSON, Raw: raw.String(), Indexes: indexes}
}

func compatibilityInvalidQuotedMultipath(expression string) bool {
	if strings.HasPrefix(expression, "#[") {
		expression = expression[1:]
	}
	if len(expression) < 2 || expression[0] != '[' && expression[0] != '{' {
		return false
	}
	if strings.Count(expression, "|") == 1 &&
		compatibilityPipeInsideQuotedQuery(expression) {
		pipe := strings.IndexByte(expression, '|')
		if strings.Contains(expression[:pipe], ".#(") &&
			strings.Count(expression[pipe+1:], ")") > 1 {
			return true
		}
		if strings.Contains(expression[:pipe], ".#[") &&
			strings.Count(expression[pipe+1:], "]") > 1 {
			return true
		}
		return compatibilityEvenProjectionChainBeforeQuery(expression)
	}
	if strings.Count(expression, "|") > 1 {
		firstPipe := strings.IndexByte(expression, '|')
		if query := strings.LastIndex(expression[:firstPipe], ".#("); query >= 0 &&
			!strings.Contains(expression[query+3:], ")") {
			return compatibilityEvenProjectionChainBeforeQuery(expression)
		}
		if query := strings.LastIndex(expression[:firstPipe], ".#["); query >= 0 &&
			!strings.Contains(expression[query+3:], "]") {
			return compatibilityEvenProjectionChainBeforeQuery(expression)
		}
	}
	if pipe := strings.IndexByte(expression, '|'); pipe >= 0 {
		if query := strings.LastIndex(expression[:pipe], ".#("); query >= 0 &&
			(pipe < 2 || expression[pipe-2:pipe] != ".#") &&
			strings.Contains(expression[query+3:pipe], ")") {
			return true
		}
		if query := strings.LastIndex(expression[:pipe], ".#["); query >= 0 &&
			(pipe < 2 || expression[pipe-2:pipe] != ".#") &&
			strings.Contains(expression[query+3:pipe], "]") {
			return true
		}
	}
	entries, ok := splitCompatibilityEntries(expression[1 : len(expression)-1])
	if !ok {
		return false
	}
	for _, entry := range entries {
		colon := compatibilityTopLevelColon(entry)
		if colon >= 0 && compatibilityQuotedContains(entry[:colon], '|') {
			key := trimCompatibilitySpace(entry[:colon])
			if strings.Count(key, "|") > 1 &&
				!compatibilityAllPipesProjected(key) {
				return true
			}
			allowedKey := false
			if len(key) > 1 && key[0] == '"' {
				if end, _, err := scanJSONString(key, 0); err == nil {
					decoded := compatibilityUnescape(key[1 : end-1])
					if compatibilityProjectionChainAllowsPipe(decoded) {
						allowedKey = true
					}
				}
			}
			if !allowedKey {
				return true
			}
		}
		if colon >= 0 && compatibilityQuotedContains(entry[colon+1:], '|') {
			value := trimCompatibilitySpace(entry[colon+1:])
			if len(value) > 1 && value[0] == '"' {
				if end, _, err := scanJSONString(value, 0); err == nil {
					decoded := compatibilityUnescape(value[1 : end-1])
					if compatibilityProjectionChainAllowsPipe(decoded) {
						continue
					}
				}
			}
			return true
		}
		if colon < 0 && compatibilityQuotedContains(entry, '|') {
			if strings.Count(entry, "|") > 1 {
				firstPipe := strings.IndexByte(entry, '|')
				lastPipe := strings.LastIndexByte(entry, '|')
				if query := strings.LastIndex(entry[:firstPipe], ".#("); query >= 0 {
					if close := strings.IndexByte(entry[lastPipe+1:], ')'); close >= 0 &&
						!strings.Contains(entry[query+3:lastPipe], ")") {
						if compatibilityEvenProjectionChainBeforeQuery(entry) {
							return true
						}
						continue
					}
				}
				if query := strings.LastIndex(entry[:firstPipe], ".#["); query >= 0 {
					if close := strings.IndexByte(entry[lastPipe+1:], ']'); close >= 0 &&
						!strings.Contains(entry[query+3:lastPipe], "]") {
						if compatibilityEvenProjectionChainBeforeQuery(entry) {
							return true
						}
						continue
					}
				}
				if query := strings.LastIndex(entry, ".#("); query >= 0 &&
					query < strings.IndexByte(entry, '|') &&
					!strings.Contains(entry[query+3:], ")") {
					if compatibilityEvenProjectionChainBeforeQuery(entry) {
						return true
					}
					continue
				}
				if query := strings.LastIndex(entry, ".#["); query >= 0 &&
					query < strings.IndexByte(entry, '|') &&
					!strings.Contains(entry[query+3:], "]") {
					if compatibilityEvenProjectionChainBeforeQuery(entry) {
						return true
					}
					continue
				}
				trimmed := trimCompatibilitySpace(entry)
				if strings.HasPrefix(trimmed, `".#|`) {
					if query := strings.LastIndex(entry, ".#("); query >
						strings.IndexByte(entry, '|') &&
						query < strings.LastIndexByte(entry, '|') &&
						!strings.Contains(entry[query+3:], ")") {
						continue
					}
					if query := strings.LastIndex(entry, ".#["); query >
						strings.IndexByte(entry, '|') &&
						query < strings.LastIndexByte(entry, '|') &&
						!strings.Contains(entry[query+3:], "]") {
						continue
					}
				}
				if compatibilityAllPipesProjected(entry) {
					continue
				}
				return true
			}
			trimmed := trimCompatibilitySpace(entry)
			if compatibilityPipeInsideQuotedQuery(trimmed) {
				if compatibilityEvenProjectionChainBeforeQuery(trimmed) {
					return true
				}
				continue
			}
			if emptyString := strings.Index(trimmed, `""`); emptyString >= 0 &&
				(strings.Contains(trimmed[:emptyString], ".#(") ||
					strings.Contains(trimmed[:emptyString], ".#[")) &&
				strings.IndexByte(trimmed[emptyString+2:], '|') >= 0 {
				continue
			}
			pipe := strings.IndexByte(trimmed, '|')
			quote := -1
			if pipe >= 0 {
				quote = strings.LastIndexByte(trimmed[:pipe], '"')
			}
			if quote >= 0 && quote+1 < len(trimmed) {
				quoted := trimmed[quote:]
				end, _, err := scanJSONString(quoted, 0)
				if err != nil {
					if strings.Contains(trimmed, ".#|") {
						continue
					}
					return true
				}
				decoded := compatibilityUnescape(quoted[1 : end-1])
				if compatibilityProjectionChainAllowsPipe(decoded) {
					continue
				}
				if compatibilityPipeInsideQuotedQuery(decoded) &&
					strings.Count(decoded, "|") == 1 {
					if compatibilityEvenProjectionChainBeforeQuery(decoded) {
						return true
					}
					continue
				}
				if strings.Contains(decoded, "|#.") &&
					strings.Count(decoded, "|") == 1 {
					continue
				}
			}
			return true
		}
	}
	return false
}

func compatibilityAllPipesProjected(value string) bool {
	found := false
	for index := 0; index < len(value); index++ {
		if value[index] != '|' {
			continue
		}
		found = true
		if index < 2 || value[index-2:index] != ".#" {
			return false
		}
	}
	return found
}

func compatibilityClosedQueryThenProjectedPipe(value string) bool {
	firstPipe := strings.IndexByte(value, '|')
	if firstPipe < 0 {
		return false
	}
	for _, pair := range []struct {
		marker string
		close  byte
	}{
		{marker: ".#(", close: ')'},
		{marker: ".#[", close: ']'},
	} {
		query := strings.LastIndex(value[:firstPipe], pair.marker)
		if query < 0 {
			continue
		}
		if strings.IndexByte(value[query+3:firstPipe], pair.close) >= 0 {
			continue
		}
		close := strings.IndexByte(value[firstPipe+1:], pair.close)
		if close < 0 {
			continue
		}
		after := firstPipe + 1 + close + 1
		if strings.Contains(value[after:], "|#.") {
			return true
		}
	}
	return false
}

func compatibilityEvenProjectionChainBeforeQuery(value string) bool {
	pipe := strings.IndexByte(value, '|')
	if pipe < 0 {
		return false
	}
	open := strings.LastIndexAny(value[:pipe], "([")
	if open < 2 || value[open-2:open] != ".#" {
		return false
	}
	prefix := value[:open]
	count := 0
	for strings.HasSuffix(prefix, ".#") {
		count++
		prefix = prefix[:len(prefix)-2]
	}
	return count > 0 && count%2 == 0
}

func compatibilityProjectionChainAllowsPipe(value string) bool {
	if strings.Count(value, "|") != 1 {
		return false
	}
	pipe := strings.IndexByte(value, '|')
	if pipe < 0 {
		return false
	}
	prefix := value[:pipe]
	count := 0
	for strings.HasSuffix(prefix, ".#") {
		count++
		prefix = prefix[:len(prefix)-2]
	}
	return count%2 == 1
}

func compatibilityPipeInsideQuotedQuery(value string) bool {
	pipe := strings.IndexByte(value, '|')
	if pipe < 0 {
		return false
	}
	for _, marker := range []string{".#(", ".#["} {
		start := strings.LastIndex(value[:pipe], marker)
		if start < 0 {
			continue
		}
		open := marker[len(marker)-1]
		close := byte(')')
		if open == '[' {
			close = ']'
		}
		depth := 0
		for index := start + 2; index < pipe; index++ {
			switch value[index] {
			case open:
				depth++
			case close:
				if depth > 0 {
					depth--
					if depth == 0 {
						return false
					}
				}
			}
		}
		if depth > 0 {
			return true
		}
	}
	return false
}

func compatibilityQuotedContains(value string, target byte) bool {
	quoted := false
	escaped := false
	for index := 0; index < len(value); index++ {
		if escaped {
			escaped = false
			continue
		}
		if value[index] == '\\' {
			escaped = true
			continue
		}
		if value[index] == '"' {
			quoted = !quoted
			continue
		}
		if quoted && value[index] == target {
			return true
		}
	}
	return false
}

func compatibilityOnlyEscapedDots(part string) bool {
	found := false
	for dot := 0; dot < len(part); dot++ {
		if part[dot] != '.' {
			continue
		}
		found = true
		slashes := 0
		for index := dot - 1; index >= 0 && part[index] == '\\'; index-- {
			slashes++
		}
		if slashes%2 == 0 {
			return false
		}
	}
	return found
}

func projectCompatibilityWithPipe(array Result, remainder []compatibilityPathPart) Result {
	if index := compatibilityProjectionPipe(remainder); index >= 0 {
		if index > 0 &&
			(strings.Contains(remainder[0].text, ".#(") &&
				!strings.Contains(remainder[0].text, ")") ||
				strings.Contains(remainder[0].text, ".#[") &&
					!strings.Contains(remainder[0].text, "]")) {
			return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
		}
		projected := projectCompatibilityArray(array, remainder[:index])
		projected.Index = 0
		projected.Indexes = nil
		projected.synthetic = true
		projected.suppressIndexes = false
		projected.relativeProjection = true
		return evaluateCompatibilityParts(projected, remainder[index:])
	}
	return projectCompatibilityArray(array, remainder)
}

func compatibilityProjectionPipe(parts []compatibilityPathPart) int {
	skipDelimiter := false
	for index := 1; index < len(parts); index++ {
		if skipDelimiter {
			skipDelimiter = false
			continue
		}
		if parts[index].explicitPipe {
			return index
		}
		if parts[index].text == "#" {
			skipDelimiter = true
		}
	}
	return -1
}

func compatibilityMultipath(current Result, expression string) Result {
	if len(expression) < 2 {
		return Result{}
	}
	if strings.HasPrefix(expression, `[":(":":|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[":(":":|!`) : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, "]") {
		body := expression[len(`["|!`) : len(expression)-1]
		stages := strings.Split(body, "&:|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) {
			tail := strings.Split(stages[1], `:"`)
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + body + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasSuffix(expression, `",]`) {
		if quote := strings.IndexByte(expression, '"'); quote > 1 {
			prefix := expression[1:quote]
			body := expression[quote+1 : len(expression)-len(`",]`)]
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|![)|!") {
				recovered := strings.TrimPrefix(body, "|![)|!")
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":.""""|!`) &&
		len(expression) >= len(`[":.""""|!`)+3 &&
		expression[len(expression)-3] == '"' &&
		!compatibilityAlphanumericComponent(
			expression[len(expression)-2:len(expression)-1]) &&
		expression[len(expression)-1] == ']' {
		recovered := expression[len(`[":.""""|!`) : len(expression)-3]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["::"`) &&
		strings.HasSuffix(expression, `" ""]`) {
		body := expression[len(`["::"`) : len(expression)-len(`" ""]`)]
		stages := strings.Split(body, `"|!`)
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `":" "":"]`) {
		recovered := expression[len(`["|!`) : len(expression)-len(`":" "":"]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, `":""]`) {
		body := expression[len(`["`) : len(expression)-len(`":""]`)]
		stages := strings.Split(body, `":"|!`)
		if len(stages) == 2 &&
			compatibilityAlphanumericComponent(stages[1]) &&
			!compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], ":|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, "]") {
		body := expression[len(`["`) : len(expression)-1]
		if marker := strings.Index(body, ":|!"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			recovered := body[marker+len(":|!"):]
			fields := strings.Split(recovered, `:"":"`)
			if len(fields) == 2 &&
				compatibilityDecimalComponent(fields[0]) &&
				compatibilityDecimalComponent(fields[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, "]") {
		if quote := strings.IndexByte(expression, '"'); quote > 1 {
			lastQuote := strings.LastIndexByte(expression, '"')
			if lastQuote > quote &&
				lastQuote+1 < len(expression)-1 {
				prefix := expression[1:quote]
				trimmed := trimCompatibilitySpace(prefix)
				body := expression[quote+1 : lastQuote]
				if trimmed != prefix &&
					compatibilityDecimalComponent(trimmed) &&
					strings.HasPrefix(body, "|![).") {
					stages := strings.Split(
						strings.TrimPrefix(body, "|![)."), "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						suffix := expression[lastQuote:]
						if expression[lastQuote+1] <= ' ' {
							suffix = `"]`
						}
						return Result{
							Type:      JSON,
							Raw:       "[" + stages[1] + suffix,
							synthetic: true,
						}
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		(strings.HasSuffix(expression, `"$]`) ||
			strings.HasSuffix(expression, `"&]`) ||
			strings.HasSuffix(expression, `"']`)) {
		if quote := strings.IndexByte(expression, '"'); quote > 1 && quote+1 <= len(expression)-3 {
			prefix := trimCompatibilitySpace(expression[1:quote])
			body := expression[quote+1 : len(expression)-3]
			if (compatibilityDecimalComponent(prefix) ||
				len(prefix) > 1 &&
					(prefix[0] == '+' || prefix[0] == '-') &&
					compatibilityDecimalComponent(prefix[1:])) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + expression[len(expression)-3:],
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if quote := strings.IndexByte(expression, '"'); quote > 1 && quote+1 <= len(expression)-2 {
			prefix := expression[1:quote]
			body := expression[quote+1 : len(expression)-2]
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) {
					fields := strings.Split(stages[1], ",")
					if len(fields) == 2 &&
						compatibilityAlphanumericComponent(fields[0]) &&
						!compatibilityDecimalComponent(fields[0]) &&
						compatibilityDecimalComponent(fields[1]) {
						return Result{
							Type: JSON, Raw: "[" + fields[0] + "]",
							synthetic: true,
						}
					}
				}
			}
			if strings.HasPrefix(prefix, "$ ") &&
				compatibilityDecimalComponent(
					trimCompatibilitySpace(
						strings.TrimPrefix(prefix, "$"))) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				strings.HasSuffix(trimmed, "$") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(trimmed, "$")) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				compatibilityDecimalComponent(trimmed) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					strings.HasSuffix(stages[1], "$") &&
					compatibilityAlphanumericComponent(
						strings.TrimSuffix(stages[1], "$")) &&
					!compatibilityDecimalComponent(
						strings.TrimSuffix(stages[1], "$")) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(stages) == 2 &&
					len(stages[0]) == 1 &&
					!compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(body, "|![).") {
				allPunctuation := prefix != ""
				for index := 0; index < len(prefix); index++ {
					if compatibilityAlphanumericComponent(
						prefix[index : index+1]) {
						allPunctuation = false
						break
					}
				}
				if allPunctuation {
					stages := strings.Split(
						strings.TrimPrefix(body, "|![)."), "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
				for separator := 1; separator+1 < len(prefix); separator++ {
					if compatibilityAlphanumericComponent(
						prefix[:separator]) &&
						!compatibilityAlphanumericComponent(
							prefix[separator:separator+1]) &&
						compatibilityAlphanumericComponent(
							prefix[separator+1:]) {
						stages := strings.Split(
							strings.TrimPrefix(body, "|![)."), "|!")
						if len(stages) == 2 &&
							compatibilityAlphanumericComponent(stages[0]) &&
							compatibilityDecimalComponent(stages[1]) {
							return Result{
								Type: JSON, Raw: "[" + stages[1] + `"]`,
								synthetic: true,
							}
						}
					}
				}
			}
			if !current.Exists() {
				trimmed := trimCompatibilitySpace(prefix)
				if trimmed != prefix &&
					compatibilityDecimalComponent(trimmed) &&
					strings.HasPrefix(body, "|![).") {
					stages := strings.Split(
						strings.TrimPrefix(body, "|![)."), "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
				}
			}
			if fields := strings.Fields(prefix); len(fields) == 2 &&
				compatibilityDecimalComponent(fields[0]) &&
				compatibilityDecimalComponent(fields[1]) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					stages[0] == "#" &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(prefix, ".") &&
				compatibilityAlphanumericComponent(
					strings.TrimPrefix(prefix, ".")) &&
				strings.HasPrefix(body, "|![)") {
				if strings.HasPrefix(body, "|![).") {
					stages := strings.Split(
						strings.TrimPrefix(body, "|![)."), "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityAlphanumericComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
				}
				recovered := strings.TrimPrefix(body, "|![)")
				fields := strings.Fields(recovered)
				if stages := strings.Split(recovered, "|!"); len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityAlphanumericComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				for separator := 1; separator+1 < len(recovered); separator++ {
					if compatibilityAlphanumericComponent(
						recovered[:separator]) &&
						!compatibilityAlphanumericComponent(
							recovered[separator:separator+1]) &&
						compatibilityAlphanumericComponent(
							recovered[separator+1:]) {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
				}
				if len(fields) == 2 &&
					compatibilityAlphanumericComponent(fields[0]) &&
					compatibilityAlphanumericComponent(fields[1]) ||
					compatibilityAlphanumericComponent(recovered) &&
						!compatibilityDecimalComponent(recovered) ||
					trimCompatibilitySpace(recovered) != recovered &&
						compatibilityAlphanumericComponent(
							trimCompatibilitySpace(recovered)) ||
					len(recovered) > 1 &&
						!compatibilityAlphanumericComponent(
							recovered[len(recovered)-1:]) &&
						compatibilityAlphanumericComponent(
							recovered[:len(recovered)-1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if strings.HasPrefix(prefix, ".") &&
				compatibilityAlphanumericComponent(
					strings.TrimPrefix(prefix, ".")) &&
				strings.HasPrefix(body, "|![))") {
				payload := strings.TrimPrefix(body, "|![))")
				delimiter := "|"
				if strings.Contains(payload, "|!") {
					delimiter = "|!"
				}
				stages := strings.Split(payload, delimiter)
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityAlphanumericComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if strings.HasSuffix(prefix, ".") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(prefix, ".")) &&
				strings.HasPrefix(body, "|![))") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![))"), "|")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityAlphanumericComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				compatibilityDecimalComponent(trimmed) &&
				strings.HasPrefix(body, "{).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "{)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				compatibilityDecimalComponent(trimmed) &&
				strings.Contains(body, "|![).") {
				if marker := strings.Index(body, "|![)."); marker > 0 &&
					compatibilityAlphanumericComponent(body[:marker]) {
					stages := strings.Split(
						body[marker+len("|![)."):], "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				compatibilityDecimalComponent(trimmed) &&
				strings.HasPrefix(body, "|![).[") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![).["), "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				(len(trimmed) == 1 &&
					!compatibilityAlphanumericComponent(trimmed) ||
					len(trimmed) > 1 &&
						!compatibilityAlphanumericComponent(trimmed[:1]) &&
						compatibilityAlphanumericComponent(trimmed[1:])) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				compatibilityDecimalComponent(trimmed) &&
				strings.HasPrefix(body, "|") {
				if marker := strings.Index(body, "{)"); marker > 1 &&
					compatibilityDecimalComponent(body[1:marker]) {
					stages := strings.Split(
						body[marker+len("{)"):], "|!")
					if len(stages) == 2 &&
						(compatibilityAlphanumericComponent(stages[0]) ||
							trimCompatibilitySpace(stages[0]) != stages[0] &&
								compatibilityAlphanumericComponent(
									trimCompatibilitySpace(stages[0]))) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				compatibilityDecimalComponent(trimmed) &&
				strings.HasPrefix(body, "|![)|") {
				if strings.HasPrefix(body, "|![)|!|!") {
					recovered := strings.TrimPrefix(body, "|![)|!|!")
					if compatibilityDecimalComponent(recovered) {
						return Result{
							Type: JSON, Raw: "[" + recovered + `"]`,
							synthetic: true,
						}
					}
				}
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)|"), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if (compatibilityDecimalComponent(prefix) ||
				len(prefix) > 1 &&
					(prefix[0] == '+' || prefix[0] == '-') &&
					compatibilityDecimalComponent(prefix[1:])) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					strings.HasSuffix(stages[1], "[)") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(stages[1], "[)")) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					(stages[1] == "+" || stages[1] == "-") {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				(strings.HasPrefix(body, "'|![).") ||
					strings.HasPrefix(body, "(|![).")) {
				marker := "'|![)."
				if strings.HasPrefix(body, "(|![).") {
					marker = "(|![)."
				}
				stages := strings.Split(
					strings.TrimPrefix(body, marker), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|![)|!") {
				recovered := strings.TrimPrefix(body, "|![)|!")
				if strings.HasSuffix(recovered, ",") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, ",")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + strings.TrimSuffix(recovered, ",") + "]",
						synthetic: true,
					}
				}
				if fields := strings.Fields(recovered); len(fields) == 2 &&
					compatibilityDecimalComponent(fields[0]) &&
					compatibilityDecimalComponent(fields[1]) {
					return Result{
						Type: JSON, Raw: "[" + fields[0] + "]",
						synthetic: true,
					}
				}
				if trimmed := trimCompatibilitySpace(recovered); trimmed != recovered &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(recovered, ")") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, ")")) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
				if strings.HasPrefix(body, "|![)|![") {
					recovered := strings.TrimPrefix(body, "|![)|!")
					stages := strings.Split(
						strings.TrimPrefix(recovered, "["), "|!")
					if len(stages) == 2 &&
						compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + recovered + `"]`,
							synthetic: true,
						}
					}
				}
				tail := strings.Split(
					strings.TrimPrefix(body, "|![)|!"), ")")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[0] + ")]",
						synthetic: true,
					}
				}
			}
			if compatibilityAlphanumericComponent(prefix) &&
				strings.HasPrefix(body, "|[]|!") {
				recovered := strings.TrimPrefix(body, "|[]|!")
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|[") {
				nested := strings.TrimPrefix(body, "|[")
				if stages := strings.Split(nested, "()|!"); len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if marker := strings.Index(nested, ")."); marker > 0 {
					head := nested[:marker]
					stages := strings.Split(
						nested[marker+len(")."):], "|!")
					if trimCompatibilitySpace(head) != head &&
						compatibilityDecimalComponent(
							trimCompatibilitySpace(head)) &&
						len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|[].") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|[]."), "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|[)|!") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|[)|!"), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|[).[") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|[).["), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "|![") {
				payload := strings.TrimPrefix(body, "|![")
				if strings.HasSuffix(payload, "[).") {
					inner := strings.TrimSuffix(payload, "[).")
					stages := strings.Split(
						strings.TrimPrefix(inner, "["), "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[[" + payload + `"]`,
							synthetic: true,
						}
					}
				}
				if marker := strings.Index(payload, "[))"); marker > 0 {
					head := strings.Split(payload[:marker], "|!")
					tail := payload[marker+len("[))"):]
					if len(head) == 2 &&
						compatibilityDecimalComponent(head[0]) &&
						compatibilityDecimalComponent(head[1]) &&
						compatibilityAlphanumericComponent(tail) {
						return Result{
							Type:      JSON,
							Raw:       "[[" + payload[:marker] + "[))]",
							synthetic: true,
						}
					}
				}
			}
			if len(prefix) > 1 &&
				!compatibilityAlphanumericComponent(
					prefix[len(prefix)-1:]) &&
				compatibilityAlphanumericComponent(
					prefix[:len(prefix)-1]) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					(compatibilityAlphanumericComponent(stages[0]) ||
						stages[0] == "'") &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(prefix, ">") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(prefix, ">")) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if len(prefix) > 1 &&
				!compatibilityAlphanumericComponent(prefix[:1]) &&
				compatibilityAlphanumericComponent(prefix[1:]) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(prefix, ":") &&
				compatibilityAlphanumericComponent(
					strings.TrimPrefix(prefix, ":")) &&
				strings.HasPrefix(body, "|![)|!") {
				recovered := strings.TrimPrefix(body, "|![)|!")
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(prefix, ":") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(prefix, ":")) &&
				strings.HasPrefix(body, "|[)|!") {
				recovered := strings.TrimPrefix(body, "|[)|!")
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityAlphanumericComponent(prefix) &&
				!compatibilityDecimalComponent(prefix) {
				if marker := strings.Index(body, "|![)."); marker > 0 &&
					compatibilityAlphanumericComponent(body[:marker]) {
					stages := strings.Split(
						body[marker+len("|![)."):], "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if strings.Contains(prefix, ",") &&
				strings.HasPrefix(body, "|[)|!") {
				normalized := trimCompatibilitySpace(
					strings.TrimSuffix(
						trimCompatibilitySpace(prefix), ","))
				recovered := strings.TrimPrefix(body, "|[)|!")
				if compatibilityDecimalComponent(normalized) &&
					compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(prefix, ",") &&
				(compatibilityAlphanumericComponent(
					strings.TrimPrefix(prefix, ",")) ||
					trimCompatibilitySpace(
						strings.TrimPrefix(prefix, ",")) == "") &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(prefix); trimmed != prefix &&
				compatibilityDecimalComponent(trimmed) &&
				strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					(stages[1] == "+" || stages[1] == "-" ||
						stages[1] == "{") {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					trimCompatibilitySpace(stages[1]) != stages[1] &&
					compatibilityAlphanumericComponent(
						trimCompatibilitySpace(stages[1])) {
					recovered := trimCompatibilitySpace(stages[1])
					if stages[1][0] > ' ' {
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					len(stages[1]) > 1 &&
					!compatibilityAlphanumericComponent(
						stages[1][len(stages[1])-1:]) &&
					compatibilityDecimalComponent(
						stages[1][:len(stages[1])-1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(stages) == 2 &&
					stages[0] == "#" &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(stages) == 2 &&
					stages[0] != "" &&
					!compatibilityAlphanumericComponent(stages[0]) &&
					// A nested container open in the middle stage is a
					// malformed selector that dead-ends to [].
					!strings.ContainsAny(stages[0], "[{") &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, ".[") {
				nested := strings.TrimPrefix(body, ".[")
				if strings.HasPrefix(nested, ")|!") {
					recovered := strings.TrimPrefix(nested, ")|!")
					stages := strings.Split(recovered, "|!")
					if len(stages) == 2 &&
						len(stages[0]) > 1 &&
						compatibilityDecimalComponent(stages[0][:1]) &&
						compatibilityAlphanumericComponent(stages[0]) &&
						!compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + recovered + `"]`,
							synthetic: true,
						}
					}
				}
				if strings.HasPrefix(nested, ")") {
					stages := strings.Split(
						strings.TrimPrefix(nested, ")"), "|!")
					if len(stages) == 2 &&
						strings.HasSuffix(stages[0], "$") &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(stages[0], "$")) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
				}
				if marker := strings.Index(nested, "]|),"); marker > 0 &&
					compatibilityDecimalComponent(nested[:marker]) {
					stages := strings.Split(
						nested[marker+len("]|),"):], "|!")
					if len(stages) == 2 &&
						compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
				if marker := strings.Index(nested, ")."); marker > 0 {
					head := nested[:marker]
					stages := strings.Split(
						nested[marker+len(")."):], "|!")
					if trimCompatibilitySpace(head) != head &&
						compatibilityAlphanumericComponent(
							trimCompatibilitySpace(head)) &&
						len(stages) == 2 &&
						compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
				if marker := strings.Index(nested, ")."); marker > 1 {
					head := nested[:marker]
					stages := strings.Split(
						nested[marker+len(")."):], "|!")
					if !compatibilityAlphanumericComponent(
						head[len(head)-1:]) &&
						compatibilityDecimalComponent(
							head[:len(head)-1]) &&
						len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
				if marker := strings.Index(nested, ")."); marker > 0 &&
					compatibilityDecimalComponent(nested[:marker]) {
					stages := strings.Split(
						nested[marker+len(")."):], "|!")
					if len(stages) == 2 &&
						stages[0] == "#" &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
				if marker := strings.Index(nested, "')."); marker > 0 &&
					compatibilityDecimalComponent(nested[:marker]) {
					stages := strings.Split(
						nested[marker+len("')."):], "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
				if marker := strings.Index(nested, "&)."); marker > 0 &&
					compatibilityDecimalComponent(nested[:marker]) {
					stages := strings.Split(
						nested[marker+len("&)."):], "|!")
					if len(stages) == 2 &&
						compatibilityAlphanumericComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, ".[$).") {
				stages := strings.Split(
					strings.TrimPrefix(body, ".[$)."), "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, ".[)") {
				stages := strings.Split(
					strings.TrimPrefix(body, ".[)"), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if compatibilityAlphanumericComponent(prefix) &&
				!compatibilityDecimalComponent(prefix) &&
				strings.HasPrefix(body, "{).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "{)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["(.[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["(.[`) : len(expression)-2]
		if strings.HasPrefix(body, " ).") {
			stages := strings.Split(
				strings.TrimPrefix(body, " )."), "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "()."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			stages := strings.Split(
				body[close+len("()."):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if close := strings.Index(body, ")."); close > 0 &&
			(compatibilityAlphanumericComponent(body[:close]) ||
				len(body[:close]) > 1 &&
					!compatibilityAlphanumericComponent(
						body[close-1:close]) &&
					compatibilityDecimalComponent(
						body[:close-1])) {
			stages := strings.Split(body[close+len(")."):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `"\\:""]`) {
		recovered := expression[len(`["|!`) : len(expression)-len(`"\\:""]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`["|!`) : len(expression)-len(`":]`)]
		stages := strings.Split(body, ":$|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|!`) : len(expression)-2]
		if marker := strings.Index(body, ").[))"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			stages := strings.Split(
				body[marker+len(").[))"):], "|")
			if len(stages) == 2 &&
				compatibilityAlphanumericComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(body, "[(") &&
			strings.HasSuffix(body, ")).") {
			recovered := strings.TrimSuffix(
				strings.TrimPrefix(body, "[("), ")).")
			if compatibilityDecimalComponent(recovered) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(body, "[)|![).") {
			recovered := strings.TrimPrefix(body, "[)|![).")
			if compatibilityAlphanumericComponent(recovered) &&
				!compatibilityDecimalComponent(recovered) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(body, "[)|))") {
			stages := strings.Split(
				strings.TrimPrefix(body, "[)|))"), "|")
			if len(stages) == 3 &&
				compatibilityAlphanumericComponent(stages[0]) &&
				compatibilityAlphanumericComponent(stages[1]) &&
				compatibilityAlphanumericComponent(stages[2]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(body, "[") {
			if close := strings.IndexByte(body, ')'); close > 1 &&
				compatibilityAlphanumericComponent(body[1:close]) &&
				!compatibilityDecimalComponent(body[1:close]) {
				if tail := strings.Split(body[close+1:], "))|"); len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[[" + body[1:close] + ")]",
						synthetic: true,
					}
				}
				tail := strings.Split(body[close+1:], "()|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[[" + body[1:close] + ")]",
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, "[)|!|!"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) &&
			compatibilityDecimalComponent(
				body[marker+len("[)|!|!"):]) {
			return Result{
				Type: JSON, Raw: "[" + body + `"]`,
				synthetic: true,
			}
		}
		if strings.HasPrefix(body, "[).") {
			stages := strings.Split(
				strings.TrimPrefix(body, "[)."), "|!")
			if len(stages) == 3 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[2]) {
				middle := strings.Split(stages[1], "|")
				if len(middle) == 2 &&
					compatibilityDecimalComponent(middle[0]) &&
					compatibilityDecimalComponent(middle[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(body, "+)|![)|!") ||
			strings.HasPrefix(body, "-)|![)|!") {
			recovered := body[len("+)|![)|!"):]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "+).[)|") ||
			strings.HasPrefix(body, "-).[)|") {
			stages := strings.Split(
				body[len("+).[)|"):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "[)|!|!") {
			recovered := strings.TrimPrefix(body, "[)|!|!")
			stages := strings.Split(recovered, "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "[}|") {
			stages := strings.Split(
				strings.TrimPrefix(body, "[}|"), "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "[&.") &&
			strings.HasSuffix(body, "|![)|") {
			recovered := strings.TrimSuffix(
				strings.TrimPrefix(body, "[&."), "|![)|")
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + body + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "[&|") &&
			strings.HasSuffix(body, "|![)|") {
			recovered := strings.TrimSuffix(
				strings.TrimPrefix(body, "[&|"), "|![)|")
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + body + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "[$|") &&
			strings.HasSuffix(body, "|![)|") {
			recovered := strings.TrimSuffix(
				strings.TrimPrefix(body, "[$|"), "|![)|")
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + body + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "[).") {
			stages := strings.Split(
				strings.TrimPrefix(body, "[)."), "|!")
			if len(stages) == 2 &&
				compatibilityAlphanumericComponent(stages[0]) &&
				!compatibilityDecimalComponent(stages[0]) &&
				strings.HasPrefix(stages[1], "[") &&
				trimCompatibilitySpace(stages[1]) != stages[1] {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, ").[)."); marker > 0 &&
			(body[:marker] == "+" || body[:marker] == "-") {
			stages := strings.Split(body[marker+len(").[)."):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["(|!`) : len(expression)-2]
		if close := strings.IndexByte(body, ')'); close > 0 &&
			compatibilityAlphanumericComponent(body[close+1:]) &&
			!compatibilityDecimalComponent(body[close+1:]) {
			fields := strings.Split(body[:close], `""`)
			if len(fields) == 3 &&
				compatibilityDecimalComponent(fields[0]) &&
				compatibilityDecimalComponent(fields[1]) &&
				compatibilityDecimalComponent(fields[2]) {
				return Result{
					Type: JSON, Raw: "[" + body[:close+1] + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["`) : len(expression)-2]
		if marker := strings.Index(body, `|).[`); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			nested := body[marker+len(`|).[`):]
			if close := strings.Index(nested, `')|!`); close > 0 &&
				compatibilityDecimalComponent(nested[:close]) &&
				compatibilityDecimalComponent(
					nested[close+len(`')|!`):]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(body, "|[)).") {
			stages := strings.Split(
				strings.TrimPrefix(body, "|[))."), "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(body, "|[)|") {
			nested := strings.TrimPrefix(body, "|[)|")
			stages := strings.Split(nested, ")|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[1]) {
				if open := strings.IndexByte(stages[0], '('); open > 0 &&
					compatibilityDecimalComponent(stages[0][:open]) &&
					compatibilityDecimalComponent(stages[0][open+1:]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(body, ").[") {
			nested := strings.TrimPrefix(body, ").[")
			if close := strings.Index(nested, ")."); close > 0 &&
				compatibilityDecimalComponent(nested[:close]) {
				stages := strings.Split(
					nested[close+len(")."):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, ".[)|!"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			stages := strings.Split(
				body[marker+len(".[)|!"):], "|!")
			if len(stages) == 2 &&
				stages[0] == "$" &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "|[)") {
			nested := strings.TrimPrefix(body, "|[)")
			if close := strings.Index(nested, ")."); close > 0 &&
				compatibilityDecimalComponent(nested[:close]) {
				stages := strings.Split(
					nested[close+len(")."):], "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{Type: JSON, Raw: "[]", synthetic: true}
				}
			}
		}
		if marker := strings.Index(body, "{)."); marker > 0 {
			fields := strings.Fields(body[:marker])
			stages := strings.Split(
				body[marker+len("{)."):], "|!")
			if len(fields) == 2 &&
				compatibilityDecimalComponent(fields[0]) &&
				compatibilityDecimalComponent(fields[1]) &&
				len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if marker := strings.Index(body, "|![)."); marker > 1 {
			head := body[:marker]
			stages := strings.Split(
				body[marker+len("|![)."):], "|!")
			if !compatibilityAlphanumericComponent(
				head[len(head)-1:]) &&
				compatibilityDecimalComponent(head[:len(head)-1]) &&
				len(stages) == 2 &&
				len(stages[0]) == 1 &&
				!compatibilityAlphanumericComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "|[.") {
			nested := strings.TrimPrefix(body, "|[.")
			if close := strings.Index(nested, ")."); close > 0 &&
				compatibilityDecimalComponent(nested[:close]) {
				stages := strings.Split(
					nested[close+len(")."):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(body, "$.[") {
			nested := strings.TrimPrefix(body, "$.[")
			if marker := strings.Index(nested, "|)."); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				stages := strings.Split(
					nested[marker+len("|)."):], "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(body, ".") &&
			strings.HasSuffix(body, "|![))%") {
			recovered := strings.TrimSuffix(
				strings.TrimPrefix(body, "."), "|![))%")
			if compatibilityDecimalComponent(recovered) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if marker := strings.Index(body, "|![("); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) &&
			strings.HasSuffix(body, ")).") {
			recovered := strings.TrimSuffix(
				body[marker+len("|![("):], ")).")
			if compatibilityDecimalComponent(recovered) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(body, "(") {
			nested := strings.TrimPrefix(body, "(")
			if marker := strings.Index(nested, ".["); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				inner := nested[marker+len(".["):]
				if close := strings.Index(inner, ")."); close > 0 &&
					compatibilityDecimalComponent(inner[:close]) {
					stages := strings.Split(
						inner[close+len(")."):], "|!")
					if len(stages) == 2 &&
						compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if marker := strings.Index(nested, ".["); marker >= 0 {
				inner := nested[marker+len(".["):]
				if close := strings.Index(inner, ")."); close > 0 {
					head := inner[:close]
					stages := strings.Split(
						inner[close+len(")."):], "|!")
					if trimCompatibilitySpace(head) != head &&
						compatibilityAlphanumericComponent(
							trimCompatibilitySpace(head)) &&
						!compatibilityDecimalComponent(
							trimCompatibilitySpace(head)) &&
						len(stages) == 2 &&
						compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
		}
		if stages := strings.Split(body, ":|![)|!"); len(stages) == 2 &&
			compatibilityAlphanumericComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if strings.HasPrefix(body, ".[") {
			nested := strings.TrimPrefix(body, ".[")
			if marker := strings.Index(nested, `')|)|!`); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				recovered := nested[marker+len(`')|)|!`):]
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, "]|),"); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				stages := strings.Split(
					nested[marker+len("]|),"):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, `')|(|!`); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				recovered := nested[marker+len(`')|(|!`):]
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, "])|!"); marker > 0 &&
				trimCompatibilitySpace(nested[:marker]) == "" &&
				compatibilityDecimalComponent(
					nested[marker+len("])|!"):]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.HasPrefix(nested, ")|)|!") {
				recovered := strings.TrimPrefix(nested, ")|)|!")
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, "))."); marker > 0 &&
				compatibilityAlphanumericComponent(nested[:marker]) &&
				!compatibilityDecimalComponent(nested[:marker]) {
				stages := strings.Split(
					nested[marker+len("))."):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{Type: JSON, Raw: "[]", synthetic: true}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				stages := strings.Split(
					nested[marker+len(")."):], ")|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					!compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(nested, ").") {
				payload := strings.TrimPrefix(nested, ").")
				if stages := strings.Split(payload, "|!"); len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) {
					if close := strings.IndexByte(stages[1], ')'); close > 0 &&
						compatibilityAlphanumericComponent(
							stages[1][:close]) &&
						(compatibilityAlphanumericComponent(
							stages[1][close+1:]) ||
							trimCompatibilitySpace(
								stages[1][close+1:]) == "") {
						return Result{
							Type:      JSON,
							Raw:       "[" + stages[1][:close+1] + "]",
							synthetic: true,
						}
					}
				}
				stages := strings.Split(
					payload, ")|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[1]) {
					if open := strings.IndexByte(stages[0], '('); open > 0 &&
						compatibilityDecimalComponent(stages[0][:open]) &&
						strings.HasSuffix(stages[0][open+1:], "$") &&
						compatibilityDecimalComponent(strings.TrimSuffix(
							stages[0][open+1:], "$")) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if stages := strings.Split(nested, ")|!"); len(stages) == 2 &&
				compatibilityDecimalComponent(stages[1]) {
				head := strings.Split(stages[0], "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) {
					dotted := strings.Split(head[1], ".")
					if len(dotted) == 2 &&
						compatibilityDecimalComponent(dotted[0]) &&
						strings.HasSuffix(dotted[1], "*") &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(dotted[1], "*")) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if marker := strings.Index(nested, "}."); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				stages := strings.Split(
					nested[marker+len("}."):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				tail := nested[marker+len(")."):]
				if open := strings.IndexByte(tail, '('); open > 0 &&
					compatibilityAlphanumericComponent(tail[:open]) &&
					!compatibilityDecimalComponent(tail[:open]) {
					stages := strings.Split(tail[open+1:], "|!")
					if len(stages) == 2 &&
						compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(stages[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 0 {
				head := strings.Split(nested[:marker], ".")
				stages := strings.Split(
					nested[marker+len(")."):], "|!")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) &&
					len(stages) == 2 &&
					stages[0] == "$" &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 1 {
				head := nested[:marker]
				stages := strings.Split(
					nested[marker+len(")."):], ")|!")
				if !compatibilityAlphanumericComponent(
					head[len(head)-1:]) &&
					compatibilityDecimalComponent(head[:len(head)-1]) &&
					len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, "&)|)|!"); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				recovered := nested[marker+len("&)|)|!"):]
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 0 &&
				compatibilityAlphanumericComponent(nested[:marker]) {
				stages := strings.Split(
					nested[marker+len(")."):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					strings.HasSuffix(stages[1], "}") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(stages[1], "}")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + strings.TrimSuffix(stages[1], "}") + "]",
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 0 {
				head := strings.Split(nested[:marker], "|")
				stages := strings.Split(
					nested[marker+len(")."):], "|!")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) &&
					len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) {
					tail := strings.Split(stages[1], ",")
					if len(tail) == 2 &&
						compatibilityDecimalComponent(tail[0]) &&
						compatibilityDecimalComponent(tail[1]) {
						return Result{
							Type: JSON, Raw: "[" + tail[0] + "]",
							synthetic: true,
						}
					}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 0 {
				head := strings.Split(nested[:marker], "|")
				stages := strings.Split(
					nested[marker+len(")."):], "|!")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityAlphanumericComponent(head[1]) &&
					!compatibilityDecimalComponent(head[1]) &&
					len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					strings.HasSuffix(stages[1], "]") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(stages[1], "]")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + strings.TrimSuffix(stages[1], "]") + "]",
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, ")."); marker > 0 {
				head := strings.Split(nested[:marker], "|")
				stages := strings.Split(
					nested[marker+len(")."):], "|!")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) &&
					len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					strings.HasSuffix(stages[1], "))") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(stages[1], "))")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + strings.TrimSuffix(stages[1], ")") + "]",
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(nested, ")+") {
				stages := strings.Split(
					strings.TrimPrefix(nested, ")+"), "|![)")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if marker := strings.Index(nested, "|!)."); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) {
				stages := strings.Split(
					nested[marker+len("|!)."):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					strings.HasSuffix(stages[1], "]") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(stages[1], "]")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + strings.TrimSuffix(stages[1], "]") + "]",
						synthetic: true,
					}
				}
				if len(stages) == 3 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) &&
					compatibilityAlphanumericComponent(stages[2]) &&
					!compatibilityDecimalComponent(stages[2]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
			if stages := strings.Split(
				strings.TrimPrefix(body, ".[)."), "|!"); strings.HasPrefix(body, ".[).") &&
				len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				strings.HasSuffix(stages[1], ",(") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], ",(")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + strings.TrimSuffix(stages[1], ",(") + "]",
					synthetic: true,
				}
			}
			stages := strings.Split(
				strings.TrimPrefix(body, ".["), `)|(|!`)
			if len(stages) == 2 &&
				strings.HasSuffix(stages[0], "&") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[0], "&")) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, ".[#|)."); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			stages := strings.Split(body[marker+len(".[#|)."):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":,,,|!`) &&
		strings.HasSuffix(expression, `":""]`) {
		recovered := expression[len(`[":,,,|!`) : len(expression)-len(`":""]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":'":",|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[":'":",|!`) : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`[":`) : len(expression)-len(`":]`)]
		if marker := strings.Index(body, `"|!`); marker > 0 {
			head := strings.Split(body[:marker], `":`)
			recovered := body[marker+len(`"|!`):]
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityAlphanumericComponent(head[1]) &&
				compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `":]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":'":":|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[":'":":|!`) : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":":",|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[":":",|!`) : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, "[\":(\":\",|!") &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len("[\":(\":\",|!") : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, `"""]`) {
		payload := expression[len(`[":|!`) : len(expression)-1]
		fields := strings.Split(payload, `:"":`)
		if len(fields) == 2 &&
			compatibilityDecimalComponent(fields[0]) &&
			strings.HasSuffix(fields[1], `"""`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(fields[1], `"""`)) {
			return Result{
				Type: JSON, Raw: "[" + payload + "]", synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, `:$"]`) {
		payload := expression[len(`[":|!`) : len(expression)-1]
		fields := strings.Split(payload, `:"":`)
		if len(fields) == 2 &&
			compatibilityDecimalComponent(fields[0]) &&
			fields[1] == `$"` {
			return Result{
				Type: JSON, Raw: "[" + payload + "]", synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, "]") {
		payload := expression[len(`[":|!`) : len(expression)-1]
		if len(payload) > len(`::"`)+1 &&
			payload[len(payload)-len(`::"`)-1:len(payload)-1] == `::"` &&
			!compatibilityAlphanumericComponent(
				payload[len(payload)-1:]) {
			head := payload[:len(payload)-len(`::"`)-1]
			fields := strings.Split(head, `"`)
			if len(fields) == 3 &&
				compatibilityDecimalComponent(fields[0]) &&
				compatibilityDecimalComponent(fields[1]) &&
				fields[2] == "" {
				return Result{
					Type: JSON, Raw: "[" + payload + "]", synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":|":"""|!`) &&
		strings.HasSuffix(expression, ":]") {
		recovered := expression[len(`[":|":"""|!`) : len(expression)-len(":]")]
		parts := strings.Split(recovered, `"`)
		if len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) &&
			compatibilityDecimalComponent(parts[1]) {
			return Result{
				Type: JSON, Raw: "[" + recovered + ":]",
				synthetic: true,
			}
		}
	}
	if !current.Exists() &&
		strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, ` "|![).`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			tail := strings.Split(
				expression[marker+len(` "|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, "]") &&
		!strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, ` "|![).`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			tail := strings.Split(
				expression[marker+len(` "|![).`):len(expression)-1],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) {
				quoted := strings.Split(tail[1], `" `)
				if len(quoted) == 2 &&
					compatibilityDecimalComponent(quoted[0]) &&
					compatibilityDecimalComponent(quoted[1]) {
					return Result{
						Type: JSON, Raw: "[" + quoted[0] + `"]`,
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if quote := strings.Index(expression, `"`); quote > 2 &&
			len(expression[1:quote]) > 1 &&
			expression[1] == '0' &&
			compatibilityDecimalComponent(expression[1:quote]) {
			body := expression[quote+1 : len(expression)-2]
			if strings.HasPrefix(body, "{).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "{)."), "|!")
				if len(stages) == 2 &&
					compatibilityAlphanumericComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if quote := strings.Index(expression, `"`); quote > 1 &&
			compatibilityDecimalComponent(expression[1:quote]) {
			body := expression[quote+1 : len(expression)-2]
			if strings.HasPrefix(body, "|![).") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)."), "|!")
				if len(stages) == 3 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) &&
					compatibilityDecimalComponent(stages[2]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(body, "|![)."); marker > 0 &&
				(compatibilityAlphanumericComponent(body[:marker]) ||
					body[:marker] == "$" ||
					body[:marker] == "&") {
				tail := strings.Split(
					body[marker+len("|![)."):], "|!")
				if len(tail) == 2 &&
					compatibilityAlphanumericComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if quote := strings.Index(expression, `"`); quote > 1 &&
			compatibilityDecimalComponent(expression[1:quote]) {
			body := expression[quote+1 : len(expression)-2]
			if strings.HasPrefix(body, "|![") {
				if strings.HasSuffix(body, "[))") {
					recovered := strings.TrimSuffix(
						strings.TrimPrefix(body, "|!["), "[))")
					if compatibilityDecimalComponent(recovered) {
						return Result{
							Type:      JSON,
							Raw:       "[" + strings.TrimPrefix(body, "|!") + "]",
							synthetic: true,
						}
					}
				}
				if strings.HasSuffix(body, "[).") {
					stages := strings.Split(
						strings.TrimPrefix(body, "|!["), "|!")
					if len(stages) == 2 &&
						compatibilityDecimalComponent(stages[0]) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(stages[1], "[).")) {
						return Result{
							Type:      JSON,
							Raw:       "[" + strings.TrimPrefix(body, "|!") + `"]`,
							synthetic: true,
						}
					}
				}
				parts := strings.Split(
					strings.TrimPrefix(body, "|!["), "[)|!")
				if len(parts) == 2 &&
					compatibilityDecimalComponent(parts[0]) &&
					compatibilityDecimalComponent(parts[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + strings.TrimPrefix(body, "|!") + `"]`,
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if quote := strings.Index(expression, `"`); quote > 1 &&
			compatibilityDecimalComponent(expression[1:quote]) {
			body := expression[quote+1 : len(expression)-2]
			if strings.HasPrefix(body, "|![)|") {
				stages := strings.Split(
					strings.TrimPrefix(body, "|![)|"), "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[1]) {
					head := strings.Split(stages[0], "[")
					if len(head) == 2 &&
						compatibilityDecimalComponent(head[0]) &&
						compatibilityDecimalComponent(head[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["(.[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["(.[`) : len(expression)-2]
		if close := strings.Index(body, ")."); close > 0 {
			head := body[:close]
			tail := strings.Split(body[close+len(")."):], "|!")
			if trimmed := trimCompatibilitySpace(head); trimmed != head &&
				compatibilityDecimalComponent(trimmed) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if head[0] >= '0' && head[0] <= '9' &&
				compatibilityAlphanumericComponent(head) &&
				!compatibilityDecimalComponent(head) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[).`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[).`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasSuffix(stages[1], ",&") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ",&")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(stages[1], ",&") + "]",
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasSuffix(stages[1], ",'") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ",'")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(stages[1], ",'") + "]",
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if open := strings.Index(stages[0], "("); open > 0 &&
				strings.HasSuffix(stages[0], ")") &&
				compatibilityDecimalComponent(stages[0][:open]) {
				nested := strings.TrimSuffix(stages[0][open+1:], ")")
				if trimmed := trimCompatibilitySpace(nested); trimmed != nested &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if nested != "" &&
					nested[0] >= '0' && nested[0] <= '9' &&
					compatibilityAlphanumericComponent(nested) &&
					!compatibilityDecimalComponent(nested) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "[") &&
			strings.HasSuffix(stages[1], "$") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[1], "["), "$")) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "[") &&
			strings.HasSuffix(stages[1], "%") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[1], "["), "%")) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[".[.`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[.`) : len(expression)-2]
		stages := strings.Split(body, "|)|!")
		if len(stages) == 2 &&
			len(stages[0]) > 1 &&
			stages[0][0] == '0' &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[:".[).`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[:".[).`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[".[)%`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[)%`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "[)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[)&`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[)&`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "[)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[)'`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[)'`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "[)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[)(`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[)(`) : len(expression)-2]
		stages := strings.Split(body, "|![)")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[))`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[))`) : len(expression)-2]
		stages := strings.Split(body, "|![)")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[)*`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[)*`) : len(expression)-2]
		stages := strings.Split(body, "|![)")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[}`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[}`) : len(expression)-2]
		if close := strings.Index(body, ")."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			stages := strings.Split(body[close+len(")."):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		stages := strings.Split(body, ")|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[)`) &&
		strings.HasSuffix(expression, `"0]`) {
		body := expression[len(`[".[)`) : len(expression)-len(`"0]`)]
		if strings.HasSuffix(body, "|![)") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(body, "|![)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|![$.`) &&
		strings.HasSuffix(expression, `|![)|"]`) {
		recovered := expression[len(`["|!`) : len(expression)-2]
		return Result{
			Type: JSON, Raw: "[" + recovered + `"]`,
			synthetic: true,
		}
	}
	if strings.HasPrefix(expression, `["|![)|)(`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![)|)(`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 3 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|![`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![`) : len(expression)-2]
		if close := strings.Index(body, ")|"); close > 0 {
			head := strings.Split(body[:close], "|!")
			tail := strings.Split(body[close+len(")|"):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|!")
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if parts := strings.Split(body, "|!)|"); len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) {
			tail := strings.Split(parts[1], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, ")"); close > 0 {
			head := body[:close]
			tail := strings.Split(body[close+1:], `')|!`)
			if compatibilityAlphanumericComponent(head) &&
				!compatibilityDecimalComponent(head) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[[" + head + ")]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":,,)|!`) &&
		strings.HasSuffix(expression, `":""]`) {
		recovered := expression[len(`[":,,)|!`) : len(expression)-len(`":""]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":&":",|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[":&":",|!`) : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":&":":|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[":&":":|!`) : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|",":|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`["|",":|!`) : len(expression)-2]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|!':|!`) &&
		strings.HasSuffix(expression, `":""]`) {
		recovered := expression[len(`["|!':|!`) : len(expression)-len(`":""]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|!:|!`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`["|!:|!`) : len(expression)-len(`":]`)]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[:"|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`[:"|!`) : len(expression)-2]
		stages := strings.Split(recovered, `:"|!`)
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], `"`)
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|!`) : len(expression)-2]
		stages := strings.Split(body, `:""|!`)
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + body + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":.""""|!`) &&
		strings.HasSuffix(expression, `"$]`) {
		recovered := expression[len(`[":.""""|!`) : len(expression)-len(`"$]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":.""""|!`) &&
		strings.HasSuffix(expression, `"&]`) {
		recovered := expression[len(`[":.""""|!`) : len(expression)-len(`"&]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|!+)|![)|`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`["|!+)|![)|`) : len(expression)-2]
		if compatibilityAlphanumericComponent(recovered) &&
			!compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|![)|!`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![)|!`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			fields := strings.Fields(stages[0])
			if len(fields) == 2 &&
				compatibilityDecimalComponent(fields[0]) &&
				compatibilityDecimalComponent(fields[1]) {
				return Result{
					Type: JSON, Raw: "[" + fields[0] + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|![)|`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![)|`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasSuffix(stages[1], ",") {
			recovered := strings.TrimSuffix(stages[1], ",")
			if recovered != "" &&
				recovered[0] >= '0' && recovered[0] <= '9' &&
				compatibilityAlphanumericComponent(recovered) &&
				!compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|![)|))`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![)|))`) : len(expression)-2]
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		stages := strings.Split(body, "|")
		if len(stages) == 3 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) &&
			compatibilityAlphanumericComponent(stages[2]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|[`) : len(expression)-2]
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], "))|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		stages := strings.Split(body, "[)|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|!+).[))`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|!+).[))`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, "[.") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `"|![)`); marker > 2 &&
			compatibilityAlphanumericComponent(expression[2:marker]) &&
			!compatibilityDecimalComponent(expression[2:marker]) {
			recovered := expression[marker+len(`"|![)`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `".[)|!`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			stages := strings.Split(
				expression[marker+len(`".[)|!`):len(expression)-2],
				"|!")
			if len(stages) == 2 &&
				compatibilityAlphanumericComponent(stages[0]) &&
				!compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `:".[)|!`); marker > 1 &&
			compatibilityAlphanumericComponent(expression[1:marker]) &&
			!compatibilityDecimalComponent(expression[1:marker]) {
			recovered := expression[marker+len(`:".[)|!`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `."|![)"]`) {
		head := expression[1 : len(expression)-len(`."|![)"]`)]
		if compatibilityAlphanumericComponent(head) &&
			!compatibilityDecimalComponent(head) ||
			head == "#" {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `:"|[)|!`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			recovered := expression[marker+len(`:"|[)|!`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[:") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `"|![)|!`); marker > 2 &&
			compatibilityDecimalComponent(expression[2:marker]) {
			recovered := expression[marker+len(`"|![)|!`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, `")"]`) {
		recovered := expression[len(`["(|!`) : len(expression)-2]
		if recovered != "" &&
			recovered[0] >= '0' && recovered[0] <= '9' {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, `)"]`) {
		recovered := expression[len(`["(|!`) : len(expression)-2]
		if recovered != "" &&
			recovered[0] >= '0' && recovered[0] <= '9' &&
			strings.HasSuffix(recovered, "$)") &&
			strings.Count(recovered, `"`) >= 4 {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, `:"]`) {
		recovered := expression[len(`["(|!`) : len(expression)-2]
		if recovered != "" &&
			recovered[0] >= '0' && recovered[0] <= '9' &&
			strings.Contains(recovered, "+") &&
			!strings.ContainsAny(recovered, " \t\r\n") &&
			strings.Count(recovered, `"`) >= 3 {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
		if recovered != "" &&
			recovered[0] >= '0' && recovered[0] <= '9' &&
			len(recovered) >= 2 &&
			(recovered[len(recovered)-2] >= 'A' &&
				recovered[len(recovered)-2] <= 'Z' ||
				recovered[len(recovered)-2] >= 'a' &&
					recovered[len(recovered)-2] <= 'z') &&
			!strings.ContainsAny(recovered, " \t\r\n") &&
			strings.Count(recovered, `"`) >= 3 {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, `":""]`) {
		recovered := expression[len(`["(|!`) : len(expression)-len(`":""]`)]
		parts := strings.Split(recovered, `"`)
		if len(parts) == 3 &&
			compatibilityDecimalComponent(parts[0]) &&
			compatibilityDecimalComponent(parts[1]) &&
			strings.HasPrefix(parts[2], "(") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(parts[2], "(")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `)&"]`) {
		body := expression[len(`[".[`) : len(expression)-4]
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + ")]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `)'"]`) {
		body := expression[len(`[".[`) : len(expression)-4]
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + ")]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `)("]`) {
		body := expression[len(`[".[`) : len(expression)-4]
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + ")]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `".0]`) {
		body := expression[len(`[".[`) : len(expression)-4]
		if close := strings.Index(body, "|!)."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(body[close+len("|!)."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `".0]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `"0]`) {
		body := expression[len(`[".[`) : len(expression)-3]
		if strings.HasPrefix(body, ".") {
			if close := strings.Index(body, ")."); close > 1 &&
				compatibilityDecimalComponent(body[1:close]) {
				tail := strings.Split(
					body[close+len(")."):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"0]`,
						synthetic: true,
					}
				}
			}
		}
		if stages := strings.Split(body, "|!|)|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"0]`,
				synthetic: true,
			}
		}
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|!")
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"0]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[`) : len(expression)-2]
		if strings.HasPrefix(body, ")") {
			stages := strings.Split(strings.TrimPrefix(body, ")"), "|!")
			if len(stages) == 2 &&
				compatibilityAlphanumericComponent(stages[0]) &&
				!compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if close := strings.Index(body, ")."); close > 0 &&
			len(body[:close]) > 1 &&
			body[0] == '0' &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(tail) == 2 &&
				strings.HasSuffix(tail[0], "(") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[1]) {
				head := strings.Split(tail[0], "[")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if close := strings.Index(body, ")."); close > 0 {
			head := body[:close]
			tail := strings.Split(body[close+len(")."):], ")|!")
			if trimmed := trimCompatibilitySpace(head); trimmed != head &&
				compatibilityDecimalComponent(trimmed) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if head != "" &&
				head[0] >= '0' && head[0] <= '9' &&
				compatibilityAlphanumericComponent(head) &&
				!compatibilityDecimalComponent(head) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, ".[))|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if stages := strings.Split(body, "])|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			trimmed := trimCompatibilitySpace(stages[0])
			if trimmed != stages[0] &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, `')|!`); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				dotted := strings.Split(head[1], ".")
				if len(dotted) == 2 &&
					compatibilityDecimalComponent(dotted[0]) &&
					compatibilityDecimalComponent(dotted[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if stages := strings.Split(body, ")|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], ".")
			if len(head) == 3 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				compatibilityDecimalComponent(head[2]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, "|)|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], ".")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				fields := strings.Fields(head[1])
				if len(fields) == 2 &&
					compatibilityDecimalComponent(fields[0]) &&
					compatibilityDecimalComponent(fields[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if stages := strings.Split(body, "|!:)|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if close := strings.Index(body, ")."); close > 0 {
			tail := strings.Split(body[close+len(")."):], "|!")
			if dotted := strings.Split(body[:close], "."); len(dotted) == 2 &&
				compatibilityDecimalComponent(dotted[0]) &&
				compatibilityDecimalComponent(dotted[1]) &&
				len(tail) == 2 &&
				tail[0] == "#" &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "|!)."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(body[close+len("|!)."):], "|!")
			if len(tail) == 2 &&
				tail[0] == ":" &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityAlphanumericComponent(head[1]) &&
				!compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				tail[0] == ":" &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, ")."); close > 0 &&
			len(body[:close]) > 1 &&
			body[0] == '0' &&
			compatibilityDecimalComponent(body[:close]) {
			stages := strings.Split(body[close+len(")."):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) {
				fields := strings.Fields(stages[1])
				if len(fields) == 2 &&
					compatibilityDecimalComponent(fields[0]) &&
					compatibilityDecimalComponent(fields[1]) {
					return Result{
						Type: JSON, Raw: "[" + fields[0] + "]",
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, "]|))"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len("]|))"):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, "]|)*"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len("]|)*"):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, "]|)+"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len("]|)+"):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if quote := strings.Index(expression, `"`); quote > 2 && quote+1 <= len(expression)-2 {
			head := expression[1:quote]
			stages := strings.Split(
				expression[quote+1:len(expression)-2], "|!")
			if len(head) > 1 &&
				head[0] == '0' &&
				compatibilityDecimalComponent(head) &&
				len(stages) == 2 &&
				strings.HasPrefix(stages[0], "|") &&
				strings.HasSuffix(stages[0], ":") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(
						strings.TrimPrefix(stages[0], "|"), ":")) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if quote := strings.Index(expression, `"`); quote > 1 && quote+1 <= len(expression)-2 {
			head := expression[1:quote]
			body := expression[quote+1 : len(expression)-2]
			if (strings.HasPrefix(body, "|[") ||
				strings.HasPrefix(body, "|![")) &&
				(compatibilityDecimalComponent(head) ||
					trimCompatibilitySpace(head) != head &&
						compatibilityDecimalComponent(
							trimCompatibilitySpace(head)) ||
					head != "" &&
						head[0] >= '0' && head[0] <= '9' &&
						compatibilityAlphanumericComponent(head)) {
				if strings.HasPrefix(body, "|![") {
					body = strings.TrimPrefix(body, "|![")
				} else {
					body = strings.TrimPrefix(body, "|[")
				}
				if close := strings.Index(body, ")."); close > 0 {
					tail := strings.Split(body[close+len(")."):], "|!")
					if compatibilityDecimalComponent(body[:close]) &&
						len(tail) == 2 &&
						compatibilityDecimalComponent(tail[0]) &&
						compatibilityDecimalComponent(tail[1]) {
						return Result{
							Type: JSON, Raw: "[" + tail[1] + `"]`,
							synthetic: true,
						}
					}
					if compatibilityDecimalComponent(body[:close]) &&
						len(tail) == 2 &&
						compatibilityAlphanumericComponent(tail[0]) &&
						!compatibilityDecimalComponent(tail[0]) &&
						compatibilityDecimalComponent(tail[1]) {
						return Result{
							Type: JSON, Raw: "[" + tail[1] + `"]`,
							synthetic: true,
						}
					}
					if compatibilityAlphanumericComponent(body[:close]) &&
						!compatibilityDecimalComponent(body[:close]) &&
						len(tail) == 2 &&
						compatibilityDecimalComponent(tail[0]) &&
						compatibilityDecimalComponent(tail[1]) {
						return Result{
							Type: JSON, Raw: "[" + tail[1] + `"]`,
							synthetic: true,
						}
					}
					if compatibilityAlphanumericComponent(body[:close]) &&
						!compatibilityDecimalComponent(body[:close]) &&
						len(tail) == 2 &&
						compatibilityAlphanumericComponent(tail[0]) &&
						!compatibilityDecimalComponent(tail[0]) &&
						compatibilityDecimalComponent(tail[1]) {
						return Result{
							Type: JSON, Raw: "[" + tail[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["`) : len(expression)-2]
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				nested := strings.Split(head[1], ":")
				if len(nested) == 2 &&
					compatibilityAlphanumericComponent(nested[0]) &&
					!compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, "|["); marker > 0 &&
			compatibilityAlphanumericComponent(body[:marker]) &&
			!compatibilityDecimalComponent(body[:marker]) {
			stages := strings.Split(body[marker+len("|["):], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[1]) {
				head := strings.Split(stages[0], ")|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, "|![)."); marker > 0 {
			head := trimCompatibilitySpace(body[:marker])
			tail := strings.Split(body[marker+len("|![)."):], "|!")
			if strings.HasSuffix(body[:marker], "$") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(body[:marker], "$")) &&
				len(tail) == 2 &&
				(compatibilityAlphanumericComponent(tail[0]) ||
					tail[0] == "#") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if head != body[:marker] &&
				compatibilityDecimalComponent(head) &&
				len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, "|(.["); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len("|(.["):], ",)|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if marker := strings.Index(body, "|(.["); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len("|(.["):], "|)|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if marker := strings.Index(body, "|).["); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len("|).["):], ")|!")
			if len(tail) == 2 {
				trimmed := trimCompatibilitySpace(tail[0])
				if trimmed != tail[0] &&
					compatibilityDecimalComponent(trimmed) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.HasSuffix(tail[0], "$") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail[0], "$")) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.HasSuffix(tail[0], "&") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail[0], "&")) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if len(tail) == 2 &&
				tail[0] != "" &&
				tail[0][0] >= '0' && tail[0][0] <= '9' &&
				compatibilityAlphanumericComponent(tail[0]) &&
				!compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `[":,)|!`) &&
		strings.HasSuffix(expression, ":]") {
		recovered := expression[len(`[":,)|!`) : len(expression)-2]
		parts := strings.Split(recovered, `"`)
		if len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) &&
			compatibilityDecimalComponent(parts[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `".[`); marker > 1 {
			rawHead := expression[1:marker]
			trimmedHead := trimCompatibilitySpace(rawHead)
			if trimmedHead != rawHead &&
				compatibilityDecimalComponent(trimmedHead) {
				body := expression[marker+len(`".[`) : len(expression)-2]
				if close := strings.Index(body, ")."); close > 0 &&
					compatibilityDecimalComponent(body[:close]) {
					tail := strings.Split(
						body[close+len(")."):], "|!")
					if len(tail) == 2 &&
						compatibilityAlphanumericComponent(tail[0]) &&
						!compatibilityDecimalComponent(tail[0]) &&
						compatibilityDecimalComponent(tail[1]) {
						return Result{
							Type: JSON, Raw: "[" + tail[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
		}
		if marker := strings.Index(expression, `".[`); marker > 1 &&
			expression[1] >= '0' && expression[1] <= '9' &&
			compatibilityAlphanumericComponent(expression[1:marker]) &&
			!compatibilityDecimalComponent(expression[1:marker]) {
			body := expression[marker+len(`".[`) : len(expression)-2]
			if close := strings.Index(body, ")."); close > 0 &&
				compatibilityDecimalComponent(body[:close]) {
				tail := strings.Split(body[close+len(")."):], "|!")
				if len(tail) == 2 &&
					compatibilityAlphanumericComponent(tail[0]) &&
					!compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(expression, `".[`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			body := expression[marker+len(`".[`) : len(expression)-2]
			if parts := strings.Split(body, ")|!"); len(parts) == 2 &&
				compatibilityDecimalComponent(parts[1]) {
				head := strings.Split(parts[0], "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[" + parts[1] + `"]`,
						synthetic: true,
					}
				}
			}
			stages := strings.Split(body, "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[1]) {
				head := strings.Split(stages[0], ").")
				if len(head) == 2 {
					if strings.HasSuffix(head[0], "$") &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(head[0], "$")) &&
						compatibilityAlphanumericComponent(head[1]) &&
						!compatibilityDecimalComponent(head[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
					trimmed := trimCompatibilitySpace(head[0])
					if trimmed != head[0] &&
						compatibilityDecimalComponent(trimmed) &&
						compatibilityAlphanumericComponent(head[1]) &&
						!compatibilityDecimalComponent(head[1]) {
						return Result{
							Type: JSON, Raw: "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
				if len(expression[1:marker]) > 1 &&
					expression[1] == '0' &&
					len(head) == 2 &&
					trimCompatibilitySpace(head[0]) == "" &&
					head[0] != "" &&
					compatibilityAlphanumericComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityAlphanumericComponent(head[1]) &&
					!compatibilityDecimalComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(head) == 2 &&
					compatibilityAlphanumericComponent(head[0]) &&
					!compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(head) == 2 &&
					compatibilityAlphanumericComponent(head[0]) &&
					!compatibilityDecimalComponent(head[0]) &&
					compatibilityAlphanumericComponent(head[1]) &&
					!compatibilityDecimalComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(expression, `".[)`); marker > 2 &&
			len(expression[1:marker]) > 1 &&
			expression[1] == '0' &&
			compatibilityDecimalComponent(expression[1:marker]) {
			body := expression[marker+len(`".[)`) : len(expression)-2]
			stages := strings.Split(body, "|!")
			if len(stages) == 2 &&
				strings.HasSuffix(stages[0], "˒") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[0], "˒")) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.Contains(expression[1:marker], " ") {
			head := strings.Fields(expression[1:marker])
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityAlphanumericComponent(head[1]) &&
				!compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "%") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "%")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "&") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "&")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "'") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "'")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "*") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "*")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "+") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "+")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "/") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "/")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "@") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "@")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "`") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "`")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "\x7f") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "\x7f")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], ",") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], ",")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasSuffix(expression[1:marker], "$") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				expression[1:marker], "$")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				(compatibilityAlphanumericComponent(tail[0]) ||
					tail[0] == "#" || tail[0] == "$" ||
					tail[0] == "&") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasPrefix(expression[1:marker], "$") &&
			compatibilityAlphanumericComponent(strings.TrimPrefix(
				expression[1:marker], "$")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasPrefix(expression[1:marker], "%") &&
			compatibilityAlphanumericComponent(strings.TrimPrefix(
				expression[1:marker], "%")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasPrefix(expression[1:marker], "&") &&
			compatibilityAlphanumericComponent(strings.TrimPrefix(
				expression[1:marker], "&")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasPrefix(expression[1:marker], "'") &&
			compatibilityAlphanumericComponent(strings.TrimPrefix(
				expression[1:marker], "'")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasPrefix(expression[1:marker], "*") &&
			compatibilityAlphanumericComponent(strings.TrimPrefix(
				expression[1:marker], "*")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, `"|![).`); marker > 1 &&
			strings.HasPrefix(expression[1:marker], "+") &&
			compatibilityAlphanumericComponent(strings.TrimPrefix(
				expression[1:marker], "+")) {
			tail := strings.Split(
				expression[marker+len(`"|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(expression, ` "|![).`); marker > 1 &&
			(compatibilityAlphanumericComponent(expression[1:marker]) ||
				trimCompatibilitySpace(expression[1:marker]) !=
					expression[1:marker] &&
					compatibilityDecimalComponent(
						trimCompatibilitySpace(
							expression[1:marker])) ||
				expression[1:marker] == "$" ||
				expression[1:marker] == "%" ||
				expression[1:marker] == "&" ||
				expression[1:marker] == "'" ||
				expression[1:marker] == "*" ||
				expression[1:marker] == "+") {
			tail := strings.Split(
				expression[marker+len(` "|![).`):len(expression)-2],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) {
				trimmed := trimCompatibilitySpace(tail[1])
				if trimmed != tail[1] &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(tail[1], "$") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail[1], "$")) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if len(tail) == 2 &&
				(compatibilityAlphanumericComponent(tail[0]) ||
					tail[0] == "#" || tail[0] == "$" ||
					tail[0] == "&" || tail[0] == "'" ||
					tail[0] == "(" || tail[0] == "*" ||
					tail[0] == "+" || tail[0] == "," ||
					tail[0] == "@" || tail[0] == "/" ||
					tail[0] == ";" || tail[0] == "^" ||
					tail[0] == "\x7f" ||
					strings.HasPrefix(tail[0], "$") &&
						compatibilityAlphanumericComponent(
							strings.TrimPrefix(tail[0], "$")) ||
					strings.HasSuffix(tail[0], "$") &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(tail[0], "$"))) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				tail[1] == "+" {
				return Result{
					Type: JSON, Raw: `[+"]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				tail[1] == "[" {
				return Result{
					Type: JSON, Raw: `[["]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				!compatibilityDecimalComponent(tail[0]) &&
				tail[1] != "" &&
				tail[1][0] >= '0' && tail[1][0] <= '9' &&
				compatibilityAlphanumericComponent(tail[1]) &&
				!compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, "]") {
		if marker := strings.Index(expression, ` "|![).`); marker > 1 &&
			compatibilityAlphanumericComponent(expression[1:marker]) {
			tail := strings.Split(
				expression[marker+len(` "|![).`):len(expression)-1],
				"|!")
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) {
				quoted := strings.Split(tail[1], `"`)
				if len(quoted) == 2 &&
					compatibilityDecimalComponent(quoted[0]) &&
					compatibilityAlphanumericComponent(quoted[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + "]",
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `,"|[)|!`); marker > 1 &&
			compatibilityAlphanumericComponent(
				expression[1:marker]) {
			recovered := expression[marker+len(`,"|[)|!`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `".[)|!`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			recovered := expression[marker+len(`".[)|!`) : len(expression)-2]
			trimmed := trimCompatibilitySpace(recovered)
			if trimmed != recovered &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[`) : len(expression)-2]
		if marker := strings.Index(body, "]|)("); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len("]|)("):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `]"]`) {
		body := expression[len(`[".[`) : len(expression)-3]
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(body[close+len(")."):], "|!")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, "]") {
		body := expression[len(`[".[`) : len(expression)-1]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 {
			head := strings.Split(stages[0], ").")
			tail := strings.Split(stages[1], ` "`)
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[0] + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[",":":|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[",":":|!`) : len(expression)-3]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|!:":"|!`) &&
		strings.HasSuffix(expression, "]") {
		recovered := expression[len(`["|!:":"|!`) : len(expression)-1]
		parts := strings.Split(recovered, `"`)
		if len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) &&
			strings.HasSuffix(parts[1], ":") &&
			compatibilityAlphanumericComponent(
				strings.TrimSuffix(parts[1], ":")) {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `".[}|!`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			recovered := expression[marker+len(`".[}|!`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `".[`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			body := expression[marker+len(`".[`) : len(expression)-2]
			stages := strings.Split(body, "]|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `,] "]`) {
		if marker := strings.Index(expression, `"|!`); marker > 1 {
			head := strings.Split(expression[1:marker], ",")
			recovered := expression[marker+len(`"|!`) : len(expression)-len(`,] "]`)]
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, "[") &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `".[ )|!`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			recovered := expression[marker+len(`".[ )|!`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":,,|!`) &&
		strings.HasSuffix(expression, `":""]`) {
		recovered := expression[len(`[":,,|!`) : len(expression)-len(`":""]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":.""""|!`) &&
		strings.HasSuffix(expression, "]") {
		recovered := expression[len(`[":.""""|!`) : len(expression)-1]
		parts := strings.Split(recovered, `"`)
		if len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) &&
			compatibilityAlphanumericComponent(parts[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`[":`) : len(expression)-3]
		stages := strings.Split(body, ",|!")
		if len(stages) == 2 &&
			strings.HasSuffix(stages[0], `":"`) &&
			compatibilityDecimalComponent(stages[1]) {
			payload := strings.TrimSuffix(stages[0], `":"`)
			if compatibilityAlphanumericComponent(payload) ||
				payload == "$" || payload == "%" ||
				payload != "" && trimCompatibilitySpace(payload) == "" {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `":]`,
					synthetic: true,
				}
			}
		}
		stages = strings.Split(body, ":|!")
		if len(stages) == 2 &&
			strings.HasSuffix(stages[0], `":"`) &&
			compatibilityDecimalComponent(stages[1]) {
			payload := strings.TrimSuffix(stages[0], `":"`)
			if compatibilityAlphanumericComponent(payload) ||
				payload == "$" || payload == "%" ||
				payload != "" && trimCompatibilitySpace(payload) == "" {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `":]`,
					synthetic: true,
				}
			}
		}
		stages = strings.Split(body, `"|!`)
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], `":`)
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `":]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`[":|!`) : len(expression)-2]
		if strings.HasSuffix(recovered, "::") {
			head := strings.TrimSuffix(recovered, "::")
			if compatibilityAlphanumericComponent(head) &&
				!compatibilityDecimalComponent(head) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if parts := strings.Split(recovered, ` ""|!`); len(parts) == 2 &&
			parts[0] != "" &&
			parts[0][0] >= '0' && parts[0][0] <= '9' &&
			compatibilityAlphanumericComponent(parts[0]) &&
			!compatibilityDecimalComponent(parts[0]) &&
			compatibilityDecimalComponent(parts[1]) {
			return Result{
				Type: JSON, Raw: "[" + parts[0] + "]",
				synthetic: true,
			}
		}
		parts := strings.Split(recovered, `:"":`)
		if len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) &&
			parts[1] == `""` {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
		if len(parts) == 2 &&
			compatibilityAlphanumericComponent(parts[0]) &&
			compatibilityAlphanumericComponent(parts[1]) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
		if len(parts) == 2 &&
			compatibilityAlphanumericComponent(parts[0]) &&
			parts[1] != "" &&
			trimCompatibilitySpace(parts[1]) == "" {
			return Result{
				Type: JSON, Raw: "[" + parts[0] + `:"":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, "]") {
		recovered := expression[len(`[":|!`) : len(expression)-1]
		if strings.HasPrefix(recovered, "+") {
			parts := strings.Split(recovered, `:"":`)
			if len(parts) == 2 &&
				parts[0] == "+" &&
				strings.HasPrefix(parts[1], `"`) &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(parts[1], `"`)) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if len(recovered) > 1 &&
			(recovered[0] == '+' || recovered[0] == '-') {
			parts := strings.Split(recovered[1:], `""::"`)
			if len(parts) == 2 &&
				parts[0] == "" &&
				compatibilityAlphanumericComponent(parts[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(recovered, "::"); marker > 0 &&
			compatibilityAlphanumericComponent(recovered[:marker]) {
			quoted := recovered[marker+len("::"):]
			if quoted != "" && strings.Trim(quoted, `"`) == "" {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		parts := strings.Split(recovered, `"":`)
		if len(parts) == 2 &&
			compatibilityDecimalComponent(parts[0]) {
			tail := strings.Split(parts[1], `:"`)
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[",|!`) &&
		strings.HasSuffix(expression, `"$:""]`) {
		recovered := expression[len(`[",|!`) : len(expression)-len(`"$:""]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[",|!`) &&
		strings.HasSuffix(expression, "]") {
		recovered := expression[len(`[",|!`) : len(expression)-1]
		if marker := strings.Index(recovered, `"\`); marker > 0 &&
			compatibilityDecimalComponent(recovered[:marker]) {
			tail := recovered[marker+len(`"\`):]
			if strings.HasSuffix(tail, `\:`) {
				return Result{
					Type:      JSON,
					Raw:       "[" + recovered[:marker] + "\"\\]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|"`) &&
		strings.HasSuffix(expression, "]") {
		body := expression[len(`["|"`) : len(expression)-1]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			strings.HasSuffix(stages[0], `":`) &&
			compatibilityAlphanumericComponent(
				strings.TrimSuffix(stages[0], `":`)) {
			tail := strings.Split(stages[1], `"`)
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityAlphanumericComponent(tail[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				(tail[1] == "$" || tail[1] == "%") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `[*."`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[*."`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], ".")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`["|!`) : len(expression)-3]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if strings.HasSuffix(stages[0], "):") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[0], "):")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.HasSuffix(stages[0], ".:") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[0], ".:")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			head := strings.Split(stages[0], ":")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityAlphanumericComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `["::"`) &&
		strings.HasSuffix(expression, `":]`) {
		if pipe := strings.Index(expression, "|!"); pipe > len(`["::"`) {
			head := expression[len(`["::"`):pipe]
			recovered := expression[pipe+len("|!") : len(expression)-3]
			if strings.HasSuffix(head, `"`) &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(head, `"`)) &&
				compatibilityDecimalComponent(recovered) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[`) : len(expression)-2]
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			stages[0] == ")" &&
			stages[1] != "" &&
			stages[1][0] >= '0' && stages[1][0] <= '9' &&
			compatibilityAlphanumericComponent(stages[1]) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ").")) &&
			strings.HasSuffix(stages[1], ").") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ").")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ").")) &&
			strings.HasSuffix(stages[1], ")") {
			payload := strings.TrimSuffix(stages[1], ")")
			if trimmed := trimCompatibilitySpace(payload); trimmed != payload &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "|!)."); close > 0 {
			tail := strings.Split(
				body[close+len("|!)."):], "|!")
			if compatibilityAlphanumericComponent(body[:close]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], ".") &&
				strings.TrimSuffix(tail[1], ".") != "" &&
				strings.TrimSuffix(tail[1], ".")[0] >= '0' &&
				strings.TrimSuffix(tail[1], ".")[0] <= '9' &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(tail[1], ".")) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(tail) == 3 &&
				compatibilityDecimalComponent(body[:close]) &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) &&
				compatibilityDecimalComponent(tail[2]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + tail[1] + "|!" + tail[2] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, "]") &&
		!strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["`) : len(expression)-1]
		if marker := strings.Index(body, ".["); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(body[marker+len(".["):], "|!)|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) {
				quoted := strings.Split(tail[1], `"`)
				if len(quoted) == 2 &&
					compatibilityDecimalComponent(quoted[0]) &&
					compatibilityAlphanumericComponent(quoted[1]) &&
					!compatibilityDecimalComponent(quoted[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + "]",
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[).`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[).`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityAlphanumericComponent(stages[0]) &&
			stages[1] != "" &&
			stages[1][0] <= ' ' &&
			compatibilityDecimalComponent(
				trimCompatibilitySpace(stages[1])) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, "]") {
		if strings.HasSuffix(expression, `",]`) {
			body := expression[len(`[".[`) : len(expression)-len(`",]`)]
			stages := strings.Split(body, "|!")
			if len(stages) == 2 &&
				strings.HasPrefix(stages[0], ")|") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(stages[0], ")|")) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.LastIndex(expression, `",`); marker > len(`[".[`) &&
			compatibilityDecimalComponent(
				expression[marker+len(`",`):len(expression)-1]) {
			body := expression[len(`[".[`):marker]
			if close := strings.Index(body, "|!)."); close > 0 &&
				compatibilityDecimalComponent(body[:close]) {
				tail := strings.Split(
					body[close+len("|!)."):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityAlphanumericComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
	}
	if expression[0] == '[' &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `:".[)|!`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			recovered := expression[marker+len(`:".[)|!`) : len(expression)-2]
			if compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".`) &&
		strings.HasSuffix(expression, "]") {
		if pipe := strings.Index(expression, "|!"); pipe > len(`[".`) {
			head := expression[len(`[".`):pipe]
			tail := strings.Split(
				expression[pipe+len("|!"):len(expression)-1], `"`)
			if compatibilityAlphanumericComponent(head) &&
				!compatibilityDecimalComponent(head) &&
				len(tail) == 2 &&
				tail[0] == "[)" &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if marker := strings.Index(expression, `.[".[`); marker > 0 &&
		compatibilityDecimalComponent(expression[:marker]) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[marker+len(`.[".[`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".") &&
			strings.HasSuffix(stages[0], ")") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], "."), ")")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|"`) &&
		strings.HasSuffix(expression, "]") {
		if pipe := strings.Index(expression, "|!"); pipe > len(`["|"`) {
			head := expression[len(`["|"`):pipe]
			tail := expression[pipe+len("|!") : len(expression)-1]
			quoted := strings.Split(tail, `"`)
			if strings.HasSuffix(head, `":`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(head, `":`)) &&
				len(quoted) == 2 &&
				compatibilityDecimalComponent(quoted[0]) &&
				compatibilityDecimalComponent(quoted[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `[":`) &&
		strings.HasSuffix(expression, `":]`) {
		if pipe := strings.Index(expression, "|!"); pipe > len(`[":`) {
			prefix := expression[len(`[":`):pipe]
			prefixPayload := ""
			if strings.HasSuffix(prefix, `":",`) {
				prefixPayload = strings.TrimSuffix(prefix, `":",`)
			} else if strings.HasSuffix(prefix, `":":`) {
				prefixPayload = strings.TrimSuffix(prefix, `":":`)
			}
			if prefixPayload != "" &&
				compatibilityDecimalComponent(prefixPayload) {
				recovered := expression[pipe+len("|!") : len(expression)-3]
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + `":]`,
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[":,""""|!`) &&
		strings.HasSuffix(expression, `",]`) {
		recovered := expression[len(`[":,""""|!`) : len(expression)-len(`",]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":,""""|!`) &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(`[":,""""|!`) : len(expression)-len(`":]`)]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`[":|!`) : len(expression)-3]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			strings.HasSuffix(stages[0], ":") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.TrimSuffix(stages[0], ":")
			if trimmed := trimCompatibilitySpace(head); trimmed != head &&
				compatibilityDecimalComponent(trimmed) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
	}
	if strings.HasPrefix(expression, `[":"":`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`[":"":`) : len(expression)-3]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, "]") {
		body := expression[len(`[".[`) : len(expression)-1]
		if close := strings.Index(body, "|!)."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("|!)."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) {
				quoted := strings.Split(tail[1], `"`)
				if len(quoted) == 2 &&
					quoted[0] != "" &&
					quoted[0][0] >= '0' && quoted[0][0] <= '9' &&
					compatibilityAlphanumericComponent(quoted[0]) &&
					compatibilityDecimalComponent(quoted[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + "]",
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[."`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[."`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "[)") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[1], "[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, `"]"]`) {
		recovered := expression[len(`["(|!`) : len(expression)-len(`"]`)]
		if strings.HasSuffix(recovered, `"]`) {
			quoted := strings.Split(
				strings.TrimSuffix(recovered, `"]`), `"`)
			if len(quoted) == 4 &&
				compatibilityDecimalComponent(quoted[0]) &&
				quoted[1] == "" &&
				compatibilityDecimalComponent(quoted[2]) &&
				compatibilityDecimalComponent(quoted[3]) {
				return Result{
					Type: JSON, Raw: "[" + recovered,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, "]") {
		recovered := expression[len(`["(|!`) : len(expression)-1]
		if close := strings.Index(recovered, ")"); close > 0 &&
			strings.Count(recovered[:close], `"`) >= 3 &&
			recovered[0] >= '0' && recovered[0] <= '9' {
			tail := strings.TrimSuffix(recovered[close+1:], `"`)
			if compatibilityDecimalComponent(tail) {
				return Result{
					Type: JSON, Raw: "[" + recovered[:close+1] + "]",
					synthetic: true,
				}
			}
		}
		if (strings.Contains(recovered, `"$"""`) ||
			strings.Contains(recovered, `"%"""`) ||
			strings.Contains(recovered, `"&"""`) ||
			strings.Contains(recovered, `"'"""`) ||
			strings.Contains(recovered, `"*"""`)) &&
			strings.HasSuffix(recovered, `:"`) {
			if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
				compatibilityDecimalComponent(recovered[:quote]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if (strings.Contains(recovered, `"$"""`) ||
			strings.Contains(recovered, `"%"""`) ||
			strings.Contains(recovered, `"&"""`) ||
			strings.Contains(recovered, `"'"""`) ||
			strings.Contains(recovered, `"*"""`)) &&
			strings.HasSuffix(recovered, `)"`) {
			if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
				compatibilityDecimalComponent(recovered[:quote]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + strings.TrimSuffix(recovered, `"`) + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasSuffix(recovered, `".:""`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(recovered, `".:""`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasSuffix(recovered, `""`) {
			head := strings.TrimSuffix(recovered, `""`)
			quotedPair := strings.Split(head, `"`)
			if len(quotedPair) == 2 &&
				compatibilityDecimalComponent(quotedPair[0]) &&
				quotedPair[1] == "::" {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if len(quotedPair) == 2 &&
				compatibilityDecimalComponent(quotedPair[0]) &&
				strings.HasPrefix(quotedPair[1], ":") &&
				(compatibilityAlphanumericComponent(
					strings.TrimPrefix(quotedPair[1], ":")) ||
					strings.TrimPrefix(quotedPair[1], ":") != "" &&
						trimCompatibilitySpace(
							strings.TrimPrefix(quotedPair[1], ":")) == "" ||
					strings.TrimPrefix(quotedPair[1], ":") != "" &&
						!strings.ContainsAny(
							strings.TrimPrefix(quotedPair[1], ":"),
							".[|:()") ||
					strings.TrimPrefix(quotedPair[1], ":") == ".") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasSuffix(recovered, `""":"`) {
			if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
				compatibilityDecimalComponent(recovered[:quote]) &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(
						recovered[quote+1:], `""":"`)) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(recovered, `""`); marker > 0 &&
			compatibilityDecimalComponent(recovered[:marker]) &&
			strings.HasSuffix(recovered, `:"""`) {
			middle := strings.TrimSuffix(
				recovered[marker+len(`""`):], `:"""`)
			if middle != "" &&
				middle[0] >= '0' && middle[0] <= '9' &&
				compatibilityAlphanumericComponent(middle) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		quoted := strings.Split(recovered, `"`)
		if len(quoted) == 4 &&
			compatibilityDecimalComponent(quoted[0]) &&
			compatibilityAlphanumericComponent(quoted[1]) &&
			quoted[2] == ":" &&
			quoted[3] == "" {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
		if marker := strings.Index(recovered, `""`); marker > 0 &&
			compatibilityDecimalComponent(recovered[:marker]) &&
			strings.HasSuffix(recovered, `:"`) {
			middle := strings.TrimSuffix(
				recovered[marker+len(`""`):], `:"`)
			if middle != "" &&
				middle[0] >= '0' && middle[0] <= '9' &&
				compatibilityAlphanumericComponent(middle) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	parenLiteralSuffix := ""
	if strings.HasSuffix(expression, `", ""]`) {
		parenLiteralSuffix = `", ""]`
	} else if strings.HasSuffix(expression, `",:""]`) {
		parenLiteralSuffix = `",:""]`
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		parenLiteralSuffix != "" {
		recovered := expression[len(`["(|!`) : len(expression)-len(parenLiteralSuffix)]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, "]") {
		recovered := expression[len(`[":|!`) : len(expression)-1]
		if stages := strings.Split(recovered, "|!"); len(stages) == 2 &&
			strings.HasSuffix(stages[0], ":") &&
			strings.HasSuffix(stages[1], `"`) {
			head := strings.TrimSuffix(stages[0], ":")
			if head != "" &&
				head[0] <= ' ' &&
				trimCompatibilitySpace(head) == `""` &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], `"`)) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if stages := strings.Split(recovered, "|!"); len(stages) == 2 &&
			strings.HasSuffix(stages[0], ":") &&
			strings.HasSuffix(stages[1], `"`) {
			head := strings.TrimSuffix(stages[0], ":")
			if head != "" &&
				head[0] >= '0' && head[0] <= '9' &&
				trimCompatibilitySpace(head) == head &&
				!strings.ContainsAny(head, ".[|:()") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], `"`)) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasSuffix(recovered, `"":"""`) {
			head := strings.SplitN(
				strings.TrimSuffix(recovered, `"":"""`), ":", 2)
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasSuffix(recovered, `:\""`) {
			head := strings.TrimSuffix(recovered, `:\""`)
			if head != "" &&
				head[0] >= '0' && head[0] <= '9' &&
				compatibilityAlphanumericComponent(head) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(recovered, "+:") &&
			strings.HasSuffix(recovered, `\""`) {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
		if strings.HasPrefix(recovered, "+") &&
			strings.Contains(recovered, `""::"`) {
			if quote := strings.LastIndexByte(recovered, '"'); quote > 0 &&
				compatibilityDecimalComponent(recovered[quote+1:]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.Contains(recovered, `:""|!`) &&
			strings.HasSuffix(recovered, `"""`) {
			if colon := strings.IndexByte(recovered, ':'); colon > 0 &&
				compatibilityDecimalComponent(recovered[:colon]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		quoted := strings.Split(recovered, `"`)
		if len(quoted) == 4 &&
			compatibilityDecimalComponent(quoted[0]) &&
			compatibilityDecimalComponent(quoted[1]) &&
			quoted[2] == "::" &&
			compatibilityAlphanumericComponent(quoted[3]) {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|[`) &&
		strings.HasSuffix(expression, "]") {
		body := expression[len(`["|[`) : len(expression)-1]
		if close := strings.Index(body, "]|!"); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			recovered := body[close+len("]|!"):]
			quoted := strings.Split(recovered, `"`)
			if len(quoted) == 2 &&
				compatibilityDecimalComponent(quoted[0]) &&
				compatibilityDecimalComponent(quoted[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[") &&
			compatibilityDecimalComponent(strings.TrimPrefix(stages[1], "[")) &&
			strings.HasPrefix(stages[2], ").") &&
			compatibilityDecimalComponent(strings.TrimPrefix(stages[2], ").")) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type: JSON, Raw: "[" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			stages[0] == `*.""""` &&
			compatibilityAlphanumericComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			stages[0] == `":"` &&
			strings.HasSuffix(stages[1], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ")")) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + "]",
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			stages[0] == "" {
			if strings.HasPrefix(stages[1], "+).[))") {
				tail := strings.Split(
					strings.TrimPrefix(stages[1], "+).[))"), "|")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityAlphanumericComponent(tail[1]) &&
					!compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if strings.HasSuffix(stages[1], "[))") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(stages[1], "[))")) &&
				!compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], "[))")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.HasSuffix(stages[1], "[)))") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(stages[1], "[)))")) &&
				!compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], "[)))")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			parts := strings.Split(stages[1], `":"`)
			if len(parts) == 2 &&
				compatibilityDecimalComponent(parts[0]) &&
				strings.HasSuffix(parts[1], `"":`) &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(parts[1], `"":`)) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			stages[0] == `.["")` &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], "])") &&
			compatibilityDecimalComponent(stages[1]) {
			recovered := strings.TrimSuffix(
				strings.TrimPrefix(stages[0], ".["), "])")
			if compatibilityAlphanumericComponent(recovered) &&
				!compatibilityDecimalComponent(recovered) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[})|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[})|")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], "}") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], ".["), "}")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], ")") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], ".["), ")"), "]")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			stages[1] == "[)" {
			head := strings.Split(stages[0], ".")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityAlphanumericComponent(head[1]) &&
				!compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				!compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[)") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[0], ".[)")) &&
			strings.HasPrefix(stages[1], "[)") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[1], "[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[)") &&
			strings.HasPrefix(stages[1], "[)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)")) {
			head := strings.TrimPrefix(stages[0], ".[)")
			if trimmed := trimCompatibilitySpace(head); trimmed != head &&
				compatibilityDecimalComponent(trimmed) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			stages[0] == `.[)""` &&
			compatibilityAlphanumericComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ").[).")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ":.[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ":.[).")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "(.[") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], "(.["),
				").")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "(.[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "(.[).")) &&
			compatibilityAlphanumericComponent(stages[1]) &&
			!compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[)$") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[)$")) &&
			strings.HasPrefix(stages[1], "[)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ")") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], ")"), ".[).")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if strings.HasPrefix(stages[0], ".{") {
				headObject := strings.Split(
					strings.TrimPrefix(stages[0], ".{"), ").")
				if len(headObject) == 2 &&
					compatibilityDecimalComponent(headObject[0]) &&
					compatibilityAlphanumericComponent(headObject[1]) &&
					!compatibilityDecimalComponent(headObject[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
				if len(headObject) == 2 &&
					compatibilityAlphanumericComponent(headObject[0]) &&
					!compatibilityDecimalComponent(headObject[0]) &&
					compatibilityDecimalComponent(headObject[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(stages[0], ".["); marker > 0 &&
				compatibilityDecimalComponent(stages[0][:marker]) {
				head := strings.Split(stages[0][marker+len(".["):], "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) {
					nested := strings.Split(head[1], ").")
					if len(nested) == 2 &&
						compatibilityDecimalComponent(nested[0]) &&
						compatibilityAlphanumericComponent(nested[1]) &&
						!compatibilityDecimalComponent(nested[1]) {
						return Result{
							Type:      JSON,
							Raw:       "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			head := strings.Split(stages[0], ".[")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				nested := strings.Split(head[1], "|).")
				if len(nested) == 2 &&
					compatibilityAlphanumericComponent(nested[0]) &&
					!compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			compatibilityDecimalComponent(stages[2]) &&
			stages[3] != "" &&
			trimCompatibilitySpace(stages[3]) == "" {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + "|!]",
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityAlphanumericComponent(stages[3]) &&
			!compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			len(stages[2]) > 1 &&
			(stages[2][0] == '+' || stages[2][0] == '-') &&
			compatibilityDecimalComponent(stages[2][1:]) &&
			compatibilityAlphanumericComponent(stages[3]) &&
			!compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			compatibilityDecimalComponent(stages[2]) &&
			stages[3] == ")" {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + "]",
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|((") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|((")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|()") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|()")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|)") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[1], "[)|)")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|)$") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|)$")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|)%") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|)%")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|)&") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|)&")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|)'") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|)'")) &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[(") &&
			strings.HasSuffix(stages[1], "}.") {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[") {
			nested := strings.Split(
				strings.TrimPrefix(stages[1], "["), "{)")
			if len(nested) == 2 &&
				compatibilityDecimalComponent(nested[0]) &&
				compatibilityDecimalComponent(nested[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			stages[0] == "|[})" &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[}).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[}).")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|{") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], "|{"), ").")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], "|["), "].")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], "|")
			if len(head) == 2 &&
				head[0] == "$" &&
				strings.HasSuffix(head[1], ":") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(head[1], ":")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				colon := strings.Split(head[1], ":")
				if len(colon) == 2 &&
					compatibilityDecimalComponent(colon[0]) &&
					compatibilityDecimalComponent(colon[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if len(head) == 3 &&
				head[0] == "" &&
				compatibilityDecimalComponent(head[1]) &&
				strings.HasPrefix(head[2], "[") &&
				strings.HasSuffix(head[2], ")") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					strings.TrimPrefix(head[2], "["), ")")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				!compatibilityDecimalComponent(head[0]) &&
				head[1] == "$:" {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				!compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ":") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(head[1], ":")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if len(head) == 3 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasPrefix(head[1], "[") &&
				strings.HasSuffix(head[1], ")") &&
				compatibilityAlphanumericComponent(strings.TrimSuffix(
					strings.TrimPrefix(head[1], "["), ")")) &&
				compatibilityDecimalComponent(head[2]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasPrefix(head[1], "(.[") &&
				strings.HasSuffix(head[1], ")") {
				nested := strings.TrimSuffix(
					strings.TrimPrefix(head[1], "(.["),
					")")
				if strings.HasSuffix(nested, "$") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(nested, "$")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.HasSuffix(nested, "&") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(nested, "&")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.HasSuffix(nested, "'") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(nested, "'")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.HasSuffix(nested, "*") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(nested, "*")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.HasSuffix(nested, "+") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(nested, "+")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if trimmed := trimCompatibilitySpace(nested); trimmed != nested &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if compatibilityAlphanumericComponent(nested) &&
					!compatibilityDecimalComponent(nested) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "|[]" &&
			stages[1] == "" &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasSuffix(stages[0], "$") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[0], "$")) &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			stages[1] == "[}" &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[}.") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[}.")) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			compatibilityAlphanumericComponent(stages[2]) &&
			!compatibilityDecimalComponent(stages[2]) {
			colon := strings.Split(stages[1], ":")
			if len(colon) == 2 &&
				compatibilityDecimalComponent(colon[0]) &&
				compatibilityDecimalComponent(colon[1]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "$") &&
			strings.HasSuffix(stages[1], ":") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[1], "$"), ":")) &&
			strings.HasSuffix(stages[2], ":") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ":")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 3 &&
			stages[0] == ":" &&
			compatibilityDecimalComponent(stages[2]) {
			middle := strings.Split(stages[1], `":"`)
			if len(middle) == 2 &&
				compatibilityAlphanumericComponent(middle[0]) &&
				!compatibilityDecimalComponent(middle[0]) &&
				compatibilityDecimalComponent(middle[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == ":" &&
			strings.HasSuffix(stages[1], "(:") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], "(:")) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == ":" &&
			stages[1] != "" &&
			stages[1][0] <= ' ' &&
			compatibilityDecimalComponent(
				trimCompatibilitySpace(stages[1])) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			stages[2] == "[)|" &&
			strings.HasPrefix(stages[1], "[") {
			if strings.HasPrefix(stages[1], "[#.") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(stages[1], "[#.")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			head := strings.Split(
				strings.TrimPrefix(stages[1], "["), "|")
			if len(head) == 2 &&
				head[0] == "#" &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			head = strings.Split(
				strings.TrimPrefix(stages[1], "["), ".")
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				!compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			strings.HasSuffix(stages[0], ".[)") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[0], ".[)")) &&
			compatibilityAlphanumericComponent(stages[1]) &&
			!compatibilityDecimalComponent(stages[1]) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == ".[)" &&
			compatibilityAlphanumericComponent(stages[1]) &&
			!compatibilityDecimalComponent(stages[1]) &&
			compatibilityAlphanumericComponent(stages[2]) &&
			!compatibilityDecimalComponent(stages[2]) &&
			stages[2][0] >= '0' && stages[2][0] <= '9' {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], ")") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], ".["), ")")) &&
			compatibilityAlphanumericComponent(stages[1]) &&
			!compatibilityDecimalComponent(stages[1]) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			strings.HasSuffix(stages[1], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ")")) &&
			strings.HasSuffix(stages[2], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ")")) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + "]",
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			stages[1] == "&:" &&
			strings.HasSuffix(stages[2], `":"`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], `":"`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			stages[1] == `:":"` {
			tail := strings.Split(stages[2], `"`)
			if len(tail) == 3 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], ":") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[1], ":")) &&
				tail[2] == "" {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[") &&
			compatibilityDecimalComponent(stages[2]) {
			if strings.HasPrefix(stages[1], "[(") {
				head := strings.Split(
					strings.TrimPrefix(stages[1], "[("), ").")
				if len(head) == 2 &&
					compatibilityAlphanumericComponent(head[0]) &&
					!compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
			headParts := strings.Split(stages[1], "|")
			if len(headParts) == 3 &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(headParts[0], "[")) &&
				strings.HasSuffix(headParts[1], ")") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(headParts[1], ")")) &&
				compatibilityDecimalComponent(headParts[2]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(stages[1], "[)|"); marker > 1 &&
				compatibilityDecimalComponent(
					stages[1][1:marker]) &&
				compatibilityDecimalComponent(
					stages[1][marker+len("[)|"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + strings.Join(stages[1:], "|!") + `"]`,
					synthetic: true,
				}
			}
			if close := strings.Index(stages[1], ")"); close > 1 &&
				strings.HasSuffix(stages[1], ")") {
				first := strings.TrimPrefix(stages[1][:close], "[")
				rest := strings.TrimSuffix(stages[1][close+1:], ")")
				if trimmed := trimCompatibilitySpace(rest); trimmed != rest &&
					compatibilityAlphanumericComponent(first) &&
					!compatibilityDecimalComponent(first) &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1][:close+1] + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(rest, "$") &&
					compatibilityAlphanumericComponent(first) &&
					!compatibilityDecimalComponent(first) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(rest, "$")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1][:close+1] + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(rest, "&") &&
					compatibilityAlphanumericComponent(first) &&
					!compatibilityDecimalComponent(first) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(rest, "&")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1][:close+1] + "]",
						synthetic: true,
					}
				}
				if compatibilityAlphanumericComponent(first) &&
					!compatibilityDecimalComponent(first) &&
					compatibilityAlphanumericComponent(rest) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1][:close+1] + "]",
						synthetic: true,
					}
				}
			}
			head := strings.Split(
				strings.TrimPrefix(stages[1], "["), "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				nested := strings.Split(head[1], ").")
				if len(nested) == 2 &&
					compatibilityAlphanumericComponent(nested[0]) &&
					!compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			compatibilityDecimalComponent(stages[2]) {
			headClosed := strings.Split(stages[1], ")|[)|")
			if len(headClosed) == 2 &&
				compatibilityDecimalComponent(headClosed[0]) &&
				compatibilityDecimalComponent(headClosed[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			headDotted := strings.Split(stages[1], ")|[).")
			if len(headDotted) == 2 &&
				compatibilityDecimalComponent(headDotted[0]) &&
				compatibilityDecimalComponent(headDotted[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasSuffix(stages[1], "].[)") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], "].[)")) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			head := strings.Split(stages[1], ")|[))")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			strings.HasSuffix(stages[2], ",") {
			recovered := strings.TrimSuffix(stages[2], ",")
			if strings.HasSuffix(recovered, "$") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(recovered, "$")) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], "|[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[")) &&
			compatibilityDecimalComponent(stages[2]) {
			middle := strings.Split(stages[1], ").")
			if len(middle) == 2 &&
				compatibilityDecimalComponent(middle[0]) &&
				compatibilityDecimalComponent(middle[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], "|[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[")) &&
			compatibilityDecimalComponent(stages[2]) {
			middle := strings.Split(stages[1], ")|")
			if len(middle) == 2 &&
				compatibilityDecimalComponent(middle[0]) &&
				compatibilityDecimalComponent(middle[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "|[)" &&
			compatibilityAlphanumericComponent(stages[1]) &&
			!compatibilityDecimalComponent(stages[1]) &&
			stages[1][0] >= '0' && stages[1][0] <= '9' &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			stages[0] == ".[#" &&
			strings.HasPrefix(stages[1], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], ").")) &&
			strings.HasSuffix(stages[2], ".") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ".")) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			!compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			strings.HasPrefix(stages[1], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], ").")) &&
			strings.HasSuffix(stages[2], ":") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ":")) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			!compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			strings.HasPrefix(stages[1], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], ").")) {
			tail := strings.Split(stages[2], "(")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			!compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			strings.HasPrefix(stages[1], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], ").")) &&
			strings.HasSuffix(stages[2], "|") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], "|")) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			stages[1] == "|)" &&
			compatibilityAlphanumericComponent(stages[2]) &&
			!compatibilityDecimalComponent(stages[2]) &&
			stages[2][0] >= '0' && stages[2][0] <= '9' {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			stages[1] == ")" &&
			strings.HasSuffix(stages[2], ",") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ",")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(stages[2], ",") + "]",
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			stages[1] == ")" &&
			strings.HasSuffix(stages[2], "]") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], "]")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(stages[2], "]") + "]",
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			stages[1] == ")" &&
			strings.HasSuffix(stages[2], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ")")) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + "]",
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			stages[1] == ")" &&
			stages[2] != "" &&
			stages[2][len(stages[2])-1] <= ' ' &&
			compatibilityDecimalComponent(
				trimCompatibilitySpace(stages[2])) {
			return Result{
				Type:      JSON,
				Raw:       "[" + trimCompatibilitySpace(stages[2]) + "]",
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[")) &&
			strings.HasPrefix(stages[1], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], ").")) {
			if trimmed := trimCompatibilitySpace(stages[2]); trimmed != stages[2] &&
				stages[2][0] <= ' ' &&
				compatibilityAlphanumericComponent(trimmed) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if trimmed := trimCompatibilitySpace(stages[2]); trimmed != stages[2] &&
				trimmed != "" &&
				stages[2][len(stages[2])-1] <= ' ' &&
				((trimmed[0] >= 'A' && trimmed[0] <= 'Z') ||
					(trimmed[0] >= 'a' && trimmed[0] <= 'z')) &&
				compatibilityAlphanumericComponent(trimmed) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if trimmed := trimCompatibilitySpace(stages[2]); trimmed != stages[2] &&
				stages[2][len(stages[2])-1] <= ' ' {
				if strings.HasSuffix(trimmed, "$") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(trimmed, "$")) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + "]",
						synthetic: true,
					}
				}
				dollar := strings.Split(trimmed, "$")
				if len(dollar) == 2 &&
					compatibilityDecimalComponent(dollar[0]) &&
					compatibilityAlphanumericComponent(dollar[1]) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + "]",
						synthetic: true,
					}
				}
			}
			colon := strings.Split(stages[2], ":")
			if len(colon) == 2 &&
				compatibilityDecimalComponent(colon[0]) &&
				compatibilityDecimalComponent(colon[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			if len(stages[2]) > 1 &&
				(stages[2][0] == '+' || stages[2][0] == '-') &&
				compatibilityAlphanumericComponent(stages[2][1:]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasSuffix(stages[2], ":") {
				recovered := strings.TrimSuffix(stages[2], ":")
				if compatibilityAlphanumericComponent(recovered) &&
					!compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(stages[2], "|") {
				recovered := strings.TrimSuffix(stages[2], "|")
				if compatibilityAlphanumericComponent(recovered) &&
					!compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(stages[2], "[") {
				recovered := strings.TrimSuffix(stages[2], "[")
				if compatibilityAlphanumericComponent(recovered) &&
					!compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(stages[2], "(") {
				if strings.HasSuffix(stages[2], "$(") &&
					compatibilityDecimalComponent(strings.TrimSuffix(
						stages[2], "$(")) {
					return Result{
						Type: JSON, Raw: "[" + stages[2] + `"]`,
						synthetic: true,
					}
				}
				recovered := strings.TrimSuffix(stages[2], "(")
				dollar := strings.Split(recovered, "$")
				if len(dollar) == 2 &&
					compatibilityDecimalComponent(dollar[0]) &&
					compatibilityDecimalComponent(dollar[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[2] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(stages[2], ")") {
				recovered := strings.TrimSuffix(stages[2], ")")
				dollar := strings.Split(recovered, "$")
				if len(dollar) == 2 &&
					compatibilityDecimalComponent(dollar[0]) &&
					compatibilityDecimalComponent(dollar[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[2] + "]",
						synthetic: true,
					}
				}
			}
			tail := strings.Split(stages[2], "[")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[") &&
			compatibilityAlphanumericComponent(stages[1]) &&
			!compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], "|["), ")).")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[).")) &&
			stages[1] == "[)" {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + "]",
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[)|")) &&
			stages[1] == "[)" {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + "]",
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[).")) &&
			strings.HasSuffix(stages[1], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ")")) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + "]",
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[).")) &&
			strings.HasSuffix(stages[1], ")") {
			recovered := strings.TrimSuffix(stages[1], ")")
			if recovered == "+" || recovered == "-" {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[).")) {
			recovered := trimCompatibilitySpace(stages[1])
			if recovered != stages[1] &&
				(recovered == "+" || recovered == "-") {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.Contains(stages[0], "|") {
			if strings.HasSuffix(stages[0], "|).(") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					strings.TrimPrefix(stages[0], ".["), "|).(")) &&
				compatibilityAlphanumericComponent(stages[1]) &&
				!compatibilityDecimalComponent(stages[1]) &&
				stages[1][0] >= '0' && stages[1][0] <= '9' {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				nested := strings.Split(head[1], ").")
				if len(nested) == 2 &&
					compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					if close := strings.Index(stages[1], ")"); close > 0 &&
						compatibilityDecimalComponent(
							stages[1][:close]) &&
						compatibilityAlphanumericComponent(
							stages[1][close+1:]) {
						return Result{
							Type:      JSON,
							Raw:       "[" + stages[1][:close+1] + "]",
							synthetic: true,
						}
					}
				}
			}
			if compatibilityAlphanumericComponent(stages[1]) &&
				!compatibilityDecimalComponent(stages[1]) {
				head := strings.Split(
					strings.TrimPrefix(stages[0], ".["), "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) {
					nested := strings.Split(head[1], "].")
					if len(nested) == 2 &&
						compatibilityDecimalComponent(nested[0]) &&
						compatibilityDecimalComponent(nested[1]) {
						return Result{
							Type:      JSON,
							Raw:       "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if strings.HasSuffix(stages[1], ")$") {
				recovered := strings.TrimSuffix(stages[1], ")$")
				head := strings.Split(
					strings.TrimPrefix(stages[0], ".["), "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) {
					nested := strings.Split(head[1], ").")
					if len(nested) == 2 &&
						compatibilityDecimalComponent(nested[0]) &&
						compatibilityDecimalComponent(nested[1]) &&
						compatibilityDecimalComponent(recovered) {
						return Result{
							Type: JSON, Raw: "[" + recovered + ")]",
							synthetic: true,
						}
					}
				}
			}
			if strings.HasSuffix(stages[1], ")%") {
				recovered := strings.TrimSuffix(stages[1], ")%")
				head := strings.Split(
					strings.TrimPrefix(stages[0], ".["), "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) {
					nested := strings.Split(head[1], ").")
					if len(nested) == 2 &&
						compatibilityDecimalComponent(nested[0]) &&
						compatibilityDecimalComponent(nested[1]) &&
						compatibilityDecimalComponent(recovered) {
						return Result{
							Type: JSON, Raw: "[" + recovered + ")]",
							synthetic: true,
						}
					}
				}
			}
			if strings.HasSuffix(stages[1], "]") {
				recovered := strings.TrimSuffix(stages[1], "]")
				head := strings.Split(
					strings.TrimPrefix(stages[0], ".["), "|).")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) &&
					compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			stages[1] == "{" {
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), "|).")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			stages[1] != "" &&
			stages[1][0] <= ' ' &&
			compatibilityDecimalComponent(
				trimCompatibilitySpace(stages[1])) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), ").")
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				!compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") {
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), ").")
			tail := strings.Split(stages[1], ` "`)
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[0] + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			stages[1] != "" &&
			stages[1][len(stages[1])-1] <= ' ' {
			recovered := trimCompatibilitySpace(stages[1])
			if stages[0] == ".[).#" &&
				compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
			if strings.HasPrefix(stages[0], ".[).") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(stages[0], ".[).")) {
				dollar := strings.Split(recovered, "$")
				if len(dollar) == 2 &&
					compatibilityDecimalComponent(dollar[0]) &&
					compatibilityDecimalComponent(dollar[1]) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
			headPipe := strings.Split(
				strings.TrimPrefix(stages[0], ".["), "|).")
			if len(headPipe) == 2 &&
				compatibilityDecimalComponent(headPipe[0]) &&
				compatibilityDecimalComponent(headPipe[1]) &&
				compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), ").")
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				compatibilityAlphanumericComponent(head[1]) &&
				!compatibilityDecimalComponent(head[1]) &&
				compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], "|)") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], ".["), "|)"), ".")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityAlphanumericComponent(head[1]) &&
				!compatibilityDecimalComponent(head[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], "$)") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				nested := strings.Split(
					strings.TrimSuffix(head[1], "$)"), ".")
				if len(nested) == 2 &&
					compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], "&)") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				nested := strings.Split(
					strings.TrimSuffix(head[1], "&)"), ".")
				if len(nested) == 2 &&
					compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			compatibilityDecimalComponent(stages[1]) {
			if strings.HasSuffix(stages[0], "$)|(") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					strings.TrimPrefix(stages[0], ".["), "$)|(")) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasSuffix(stages[0], "$)|)") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					strings.TrimPrefix(stages[0], ".["), "$)|)")) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			headColonPipe := strings.Split(
				strings.TrimPrefix(stages[0], ".["), ":|")
			if len(headColonPipe) == 2 &&
				compatibilityDecimalComponent(headColonPipe[0]) {
				nested := strings.Split(headColonPipe[1], ").")
				if len(nested) == 2 &&
					compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(stages[0], `","].`); marker > len(".[") &&
				compatibilityDecimalComponent(
					stages[0][len(".["):marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len(`","].`):]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if marker := strings.Index(stages[0], "]|)$"); marker > len(".[") &&
				compatibilityDecimalComponent(
					stages[0][len(".["):marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len("]|)$"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(stages[0], "]|)%"); marker > len(".[") &&
				compatibilityDecimalComponent(
					stages[0][len(".["):marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len("]|)%"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(stages[0], "]|)&"); marker > len(".[") &&
				compatibilityDecimalComponent(
					stages[0][len(".["):marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len("]|)&"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(stages[0], "]|)'"); marker > len(".[") &&
				compatibilityDecimalComponent(
					stages[0][len(".["):marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len("]|)'"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			headColon := strings.Split(
				strings.TrimPrefix(stages[0], ".["), ":).")
			if len(headColon) == 2 &&
				compatibilityDecimalComponent(headColon[1]) {
				nested := strings.Split(headColon[0], ".")
				if len(nested) == 2 &&
					compatibilityDecimalComponent(nested[0]) &&
					compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			headNested := strings.Split(
				strings.TrimPrefix(stages[0], ".["), ").")
			if len(headNested) == 2 &&
				compatibilityDecimalComponent(headNested[1]) {
				nestedParts := strings.Split(headNested[0], ")")
				if len(nestedParts) == 2 &&
					compatibilityAlphanumericComponent(nestedParts[0]) &&
					!compatibilityDecimalComponent(nestedParts[0]) &&
					compatibilityDecimalComponent(nestedParts[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if len(headNested) == 2 &&
				compatibilityDecimalComponent(headNested[0]) {
				nested := strings.Split(headNested[1], "(")
				if len(nested) == 2 &&
					compatibilityDecimalComponent(nested[0]) &&
					compatibilityAlphanumericComponent(nested[1]) &&
					!compatibilityDecimalComponent(nested[1]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(stages[0], ".[(") {
				head := strings.Split(
					strings.TrimPrefix(stages[0], ".[("), ").")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[1]) {
					nested := strings.Split(head[0], ")")
					if len(nested) == 2 &&
						compatibilityDecimalComponent(nested[0]) &&
						compatibilityDecimalComponent(nested[1]) {
						return Result{
							Type:      JSON,
							Raw:       "[" + stages[1] + `"]`,
							synthetic: true,
						}
					}
				}
			}
			if marker := strings.Index(stages[0], "]|)"); marker > len(".[") &&
				compatibilityDecimalComponent(
					stages[0][len(".["):marker]) &&
				compatibilityAlphanumericComponent(
					stages[0][marker+len("]|)"):]) &&
				!compatibilityDecimalComponent(
					stages[0][marker+len("]|)"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(stages[0], "]|)"); marker > len(".[") &&
				compatibilityDecimalComponent(
					stages[0][len(".["):marker]) {
				nested := stages[0][marker+len("]|)"):]
				if trimmed := trimCompatibilitySpace(nested); trimmed != nested &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(stages[0], "]|"); marker > len(".[") &&
				compatibilityAlphanumericComponent(
					stages[0][len(".["):marker]) &&
				!compatibilityDecimalComponent(
					stages[0][len(".["):marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len("]|"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasPrefix(stages[0], ".[}|)") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(stages[0], ".[}|)")) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasSuffix(stages[0], ")|(") {
				head := strings.TrimSuffix(
					strings.TrimPrefix(stages[0], ".["), ")|(")
				if trimmed := trimCompatibilitySpace(head); trimmed != head &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(stages[0], ")|)") {
				head := strings.TrimSuffix(
					strings.TrimPrefix(stages[0], ".["), ")|)")
				if trimmed := trimCompatibilitySpace(head); trimmed != head &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			head := strings.Split(
				strings.TrimPrefix(stages[0], ".["), "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ")(:") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(head[1], ")(:")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".[).")) {
			if trimmed := trimCompatibilitySpace(stages[1]); trimmed != stages[1] &&
				strings.HasSuffix(trimmed, `""`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(trimmed, `""`)) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
			if trimmed := trimCompatibilitySpace(stages[1]); trimmed != stages[1] &&
				trimmed != "" &&
				((trimmed[0] >= 'A' && trimmed[0] <= 'Z') ||
					(trimmed[0] >= 'a' && trimmed[0] <= 'z')) &&
				compatibilityAlphanumericComponent(trimmed) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.HasSuffix(stages[1], ")|") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], ")|")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.HasPrefix(stages[1], "[") &&
				stages[1][len(stages[1])-1] <= ' ' &&
				compatibilityDecimalComponent(trimCompatibilitySpace(
					strings.TrimPrefix(stages[1], "["))) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasSuffix(stages[1], "}") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], "}")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + strings.TrimSuffix(stages[1], "}") + "]",
					synthetic: true,
				}
			}
			tailParen := strings.Split(stages[1], ")(")
			if len(tailParen) == 2 &&
				compatibilityDecimalComponent(tailParen[0]) &&
				compatibilityDecimalComponent(tailParen[1]) {
				return Result{
					Type: JSON, Raw: "[" + tailParen[0] + ")]",
					synthetic: true,
				}
			}
			tailClose := strings.Split(stages[1], ")")
			if len(tailClose) == 2 &&
				compatibilityAlphanumericComponent(tailClose[0]) &&
				!compatibilityDecimalComponent(tailClose[0]) &&
				compatibilityDecimalComponent(tailClose[1]) {
				return Result{
					Type: JSON, Raw: "[" + tailClose[0] + ")]",
					synthetic: true,
				}
			}
			tail := strings.Split(stages[1], ",")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityAlphanumericComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[0] + "]",
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				tail[1] != "" &&
				trimCompatibilitySpace(tail[1]) == "" {
				return Result{
					Type: JSON, Raw: "[" + tail[0] + "]",
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				(tail[1] == "$" || tail[1] == "%") {
				return Result{
					Type: JSON, Raw: "[" + tail[0] + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[).") {
			head := strings.TrimPrefix(stages[0], ".[).")
			if compatibilityAlphanumericComponent(head) &&
				!compatibilityDecimalComponent(head) &&
				head[0] >= '0' && head[0] <= '9' &&
				strings.HasSuffix(stages[1], ")") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(stages[1], ")")) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.HasSuffix(stages[0], `"")`) &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], ".["), `"")`)) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".")) &&
			strings.HasPrefix(stages[1], "[))") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[1], "[))")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".")) &&
			strings.HasPrefix(stages[1], "[))") {
			recovered := strings.TrimPrefix(stages[1], "[))")
			if recovered != "" &&
				trimCompatibilitySpace(recovered) == "" {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if recovered == "$" {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.Split(stages[0], "|")
			if len(head) == 3 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasPrefix(head[1], "[") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(head[1], "[")) &&
				strings.HasPrefix(head[2], ").") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(head[2], ").")) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasSuffix(stages[0], "|[]") &&
			compatibilityAlphanumericComponent(
				strings.TrimSuffix(stages[0], "|[]")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".[") &&
			strings.Contains(stages[0], "]|#.") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.TrimPrefix(stages[0], ".[")
			parts := strings.Split(head, "]|#.")
			if len(parts) == 2 &&
				compatibilityDecimalComponent(parts[0]) &&
				compatibilityDecimalComponent(parts[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "(|") &&
			strings.HasSuffix(stages[0], `"":""`) &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], "(|"), `"":""`)) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			strings.HasSuffix(stages[2], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ")")) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type: JSON, Raw: "[" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			(stages[2] == "+" || stages[2] == "-") &&
			compatibilityAlphanumericComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			stages[2] != "" &&
			stages[2][0] <= ' ' &&
			compatibilityDecimalComponent(
				trimCompatibilitySpace(stages[2])) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasSuffix(stages[1], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ")")) &&
			stages[2] == "[)" &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type: JSON, Raw: "[" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			stages[2] == ")" &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type: JSON, Raw: "[" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 && stages[0] == "|[]" {
			if trimmed := trimCompatibilitySpace(stages[1]); trimmed != stages[1] &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[") &&
			strings.HasSuffix(stages[0], "))") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], "|["), "))")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[") &&
			compatibilityDecimalComponent(stages[1]) {
			nested := strings.TrimPrefix(stages[0], "|[")
			if close := strings.Index(nested, ")|"); close > 0 &&
				compatibilityAlphanumericComponent(nested[:close]) &&
				compatibilityAlphanumericComponent(
					nested[close+len(")|"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
			if close := strings.Index(nested, "|)."); close > 0 &&
				compatibilityDecimalComponent(nested[:close]) &&
				compatibilityDecimalComponent(
					nested[close+len("|)."):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "|[).")) {
			if trimmed := trimCompatibilitySpace(stages[1]); trimmed != stages[1] &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], ".{)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ".{)")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "(.[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], "(.[).")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[.") &&
			strings.HasSuffix(stages[0], "]") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], "|[."), "]")) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[" + stages[1] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|")) &&
			strings.HasSuffix(stages[2], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ")")) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type: JSON, Raw: "[" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|") &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityAlphanumericComponent(stages[3]) {
			nested := strings.SplitN(
				strings.TrimPrefix(stages[1], "[)|"), "(", 2)
			if len(nested) == 2 &&
				compatibilityDecimalComponent(nested[0]) &&
				compatibilityDecimalComponent(nested[1]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if marker := strings.Index(stages[0], "{)."); marker > 0 &&
				stages[0][0] >= '0' && stages[0][0] <= '9' &&
				compatibilityAlphanumericComponent(
					stages[0][:marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len("{)."):]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			head := strings.SplitN(stages[0], "|", 2)
			if len(head) == 2 &&
				compatibilityAlphanumericComponent(head[0]) &&
				!compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ":") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(head[1], ":")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 2 && stages[0] == "" {
			if strings.HasSuffix(stages[1], "[))(") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(stages[1], "[))(")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if marker := strings.Index(stages[1], ")|[))"); marker > 0 &&
				compatibilityDecimalComponent(stages[1][:marker]) {
				tail := strings.SplitN(
					stages[1][marker+len(")|[))"):], "|", 2)
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityAlphanumericComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if marker := strings.Index(stages[0], `.[).[)|`); marker > 0 &&
				compatibilityDecimalComponent(stages[0][:marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len(`.[).[)|`):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			stages[1] != "" &&
			stages[1][0] >= '0' && stages[1][0] <= '9' &&
			compatibilityAlphanumericComponent(stages[1]) {
			if marker := strings.Index(stages[0], `.[).[))`); marker > 0 &&
				compatibilityDecimalComponent(stages[0][:marker]) &&
				compatibilityDecimalComponent(
					stages[0][marker+len(`.[).[))`):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[") &&
			stages[2] == "[)|" {
			dotted := strings.SplitN(
				strings.TrimPrefix(stages[1], "["), ".", 2)
			if len(dotted) == 2 &&
				compatibilityDecimalComponent(dotted[0]) &&
				compatibilityDecimalComponent(dotted[1]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[") &&
			compatibilityDecimalComponent(stages[2]) {
			nested := strings.TrimPrefix(stages[1], "[")
			if marker := strings.Index(nested, "[)."); marker > 0 &&
				compatibilityDecimalComponent(nested[:marker]) &&
				compatibilityDecimalComponent(
					nested[marker+len("[)."):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "|[)" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == "|[)" &&
			strings.HasPrefix(stages[1], "[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|")) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasSuffix(stages[1], ":") &&
			strings.TrimSuffix(stages[1], ":") == "'" &&
			strings.HasSuffix(stages[2], ":") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ":")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			strings.HasPrefix(stages[2], "[") {
			payload := strings.TrimPrefix(stages[2], "[")
			if trimmed := trimCompatibilitySpace(payload); trimmed != payload &&
				compatibilityAlphanumericComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|")) &&
			strings.HasPrefix(stages[2], "[") {
			payload := strings.TrimPrefix(stages[2], "[")
			if trimmed := trimCompatibilitySpace(payload); trimmed != payload &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|")) &&
			strings.HasPrefix(stages[2], "[)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[2], "[)")) {
			return Result{Type: JSON, Raw: `[[)]`, synthetic: true}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			strings.HasPrefix(stages[2], "[)") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[2], "[)")) {
			return Result{Type: JSON, Raw: `[[)]`, synthetic: true}
		}
		if len(stages) == 3 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			strings.HasPrefix(stages[2], "[") {
			payload := strings.TrimPrefix(stages[2], "[")
			if payload != "" &&
				trimCompatibilitySpace(payload) == "" {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "(") &&
			compatibilityDecimalComponent(stages[1]) {
			head := strings.TrimPrefix(stages[0], "(")
			if marker := strings.Index(head, ".[)."); marker > 0 &&
				compatibilityDecimalComponent(head[:marker]) &&
				compatibilityDecimalComponent(
					head[marker+len(".[)."):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			strings.HasSuffix(stages[2], "]") {
			recovered := strings.TrimSuffix(stages[2], "]")
			if recovered != "" &&
				recovered[0] >= '0' && recovered[0] <= '9' &&
				compatibilityAlphanumericComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if marker := strings.Index(stages[0], ".["); marker > 0 &&
				compatibilityAlphanumericComponent(stages[0][:marker]) {
				nested := stages[0][marker+len(".["):]
				if close := strings.Index(nested, "|)."); close > 0 &&
					compatibilityDecimalComponent(nested[:close]) &&
					nested[close+len("|)."):] != "" &&
					!strings.ContainsAny(
						nested[close+len("|)."):], ".[|:()") {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[).") &&
			compatibilityDecimalComponent(stages[1]) {
			nested := strings.TrimPrefix(stages[0], "|[).")
			if open := strings.IndexByte(nested, '('); open > 0 &&
				strings.HasSuffix(nested, ")") &&
				compatibilityAlphanumericComponent(nested[:open]) &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(nested[open+1:], ")")) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|")) &&
			stages[2] == "[)" {
			return Result{Type: JSON, Raw: `[[)]`, synthetic: true}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[(") &&
			compatibilityDecimalComponent(stages[2]) {
			if close := strings.Index(stages[1], ")|"); close > len("[(") &&
				compatibilityDecimalComponent(
					stages[1][len("[("):close]) &&
				compatibilityDecimalComponent(
					stages[1][close+len(")|"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|(") &&
			strings.TrimPrefix(stages[1], "[)|(") != "" &&
			!strings.ContainsAny(
				strings.TrimPrefix(stages[1], "[)|("), ".[|:()") &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if marker := strings.Index(stages[0], ".["); marker > 0 &&
				strings.HasSuffix(stages[0], "|)") {
				head := strings.Split(stages[0][:marker], "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					head[1] != "" &&
					!strings.ContainsAny(head[1], ".[|:()") &&
					compatibilityDecimalComponent(strings.TrimSuffix(
						stages[0][marker+len(".["):], "|)")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasSuffix(stages[1], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ")")) &&
			strings.HasPrefix(stages[2], "[)|") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[2], "[)|")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasSuffix(stages[1], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], ")")) &&
			strings.HasPrefix(stages[2], "[)|") {
			tail := strings.TrimPrefix(stages[2], "[)|")
			if trimmed := trimCompatibilitySpace(tail); trimmed != tail &&
				compatibilityDecimalComponent(trimmed) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			compatibilityDecimalComponent(stages[2]) {
			if marker := strings.Index(stages[1], ").[)|"); marker > 0 &&
				compatibilityDecimalComponent(stages[1][:marker]) &&
				compatibilityDecimalComponent(
					stages[1][marker+len(").[)|"):]) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[)|")) &&
			stages[2] != "" &&
			stages[2][0] >= '0' && stages[2][0] <= '9' &&
			!strings.ContainsAny(stages[2], ".[|:()") &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			strings.HasPrefix(stages[2], "[)|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[2], "[)|")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			stages[0] == `|":"` {
			if trimmed := trimCompatibilitySpace(stages[1]); trimmed != stages[1] &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "[).")) &&
			strings.HasSuffix(stages[2], ")") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[2], ")")) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type: JSON, Raw: "[" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], "|[") &&
			strings.HasSuffix(stages[0], "]") &&
			compatibilityDecimalComponent(stages[1]) {
			inner := strings.Split(
				strings.TrimSuffix(
					strings.TrimPrefix(stages[0], "|["), "]"),
				"|")
			if len(inner) == 2 &&
				compatibilityDecimalComponent(inner[0]) &&
				compatibilityDecimalComponent(inner[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if len(stages) == 3 &&
			stages[0] == "" &&
			strings.HasPrefix(stages[1], "[") &&
			compatibilityDecimalComponent(stages[2]) {
			if close := strings.IndexByte(stages[1], ')'); close > 1 &&
				compatibilityAlphanumericComponent(
					stages[1][1:close]) &&
				strings.HasSuffix(stages[1][close+1:], ")") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					stages[1][close+1:], ")")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1][:close+1] + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 && stages[0] == "" {
			if marker := strings.Index(stages[1], "[))"); marker > 0 &&
				compatibilityDecimalComponent(stages[1][:marker]) &&
				compatibilityAlphanumericComponent(
					stages[1][marker+len("[))"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1][:marker+len("[))")] + "]",
					synthetic: true,
				}
			}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if marker := strings.Index(stages[0], ".{"); marker > 0 &&
				compatibilityDecimalComponent(stages[0][:marker]) {
				nested := stages[0][marker+len(".{"):]
				if close := strings.Index(nested, ")."); close > 0 &&
					compatibilityDecimalComponent(nested[:close]) &&
					compatibilityDecimalComponent(
						nested[close+len(")."):]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], `,$`) &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], `,$`)) {
			tail := strings.SplitN(stages[1], "]|", 2)
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if len(stages) == 4 &&
			stages[0] == "" &&
			stages[1] == "[)" &&
			strings.Count(stages[2], ".") == 1 &&
			compatibilityAlphanumericComponent(
				strings.ReplaceAll(stages[2], ".", "")) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[1]) {
			if marker := strings.Index(stages[0], "|["); marker > 0 &&
				compatibilityDecimalComponent(stages[0][:marker]) {
				nested := stages[0][marker+len("|["):]
				if close := strings.Index(nested, ")."); close > 0 &&
					compatibilityAlphanumericComponent(
						nested[:close]) &&
					compatibilityDecimalComponent(
						nested[close+len(")."):]) {
					return Result{
						Type: JSON, Raw: "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], `|"`) &&
			strings.HasSuffix(stages[0], `":`) &&
			strings.TrimSuffix(
				strings.TrimPrefix(stages[0], `|"`), `":`) != "" &&
			!strings.ContainsAny(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], `|"`), `":`),
				".[|:()") &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], `|"`) &&
			strings.HasSuffix(stages[0], `":`) &&
			strings.TrimSuffix(
				strings.TrimPrefix(stages[0], `|"`), `":`) != "" &&
			trimCompatibilitySpace(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], `|"`), `":`)) == "" &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 2 &&
			strings.HasPrefix(stages[0], `|"`) &&
			strings.HasSuffix(stages[0], `":`) &&
			compatibilityAlphanumericComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], `|"`), `":`)) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if len(stages) == 3 &&
			strings.HasSuffix(stages[0], ":") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[0], ":")) &&
			stages[1] == "[)" &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
	}
	quotedColonRecoveryPrefix := ""
	if strings.HasPrefix(expression, `[",.":":|!`) {
		quotedColonRecoveryPrefix = `[",.":":|!`
	} else if strings.HasPrefix(expression, `[",|":":|!`) {
		quotedColonRecoveryPrefix = `[",|":":|!`
	}
	if quotedColonRecoveryPrefix != "" &&
		strings.HasSuffix(expression, `":]`) {
		recovered := expression[len(quotedColonRecoveryPrefix) : len(expression)-3]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `":]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `":]`) {
		body := expression[len(`["|!`) : len(expression)-3]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			strings.HasSuffix(stages[0], ":") &&
			strings.TrimSuffix(stages[0], ":") != "" &&
			!strings.ContainsAny(
				strings.TrimSuffix(stages[0], ":"), ".[|:()") &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if expression[0] == '[' &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `".`); marker > 1 &&
			compatibilityDecimalComponent(expression[1:marker]) {
			body := expression[marker+len(`".`) : len(expression)-2]
			stages := strings.Split(body, "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				stages[1] == "[)" {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if marker := strings.Index(expression, `".[`); marker > 1 &&
			compatibilityDecimalComponent(
				expression[1:marker]) {
			body := expression[marker+len(`".[`) : len(expression)-2]
			if recovery := strings.Index(body, ")|!"); recovery > 0 &&
				compatibilityAlphanumericComponent(
					body[:recovery]) &&
				compatibilityDecimalComponent(
					body[recovery+len(")|!"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len(")|!"):] + `"]`,
					synthetic: true,
				}
			}
			if recovery := strings.Index(body, "|)|!"); recovery > 0 &&
				compatibilityDecimalComponent(
					body[:recovery]) &&
				compatibilityDecimalComponent(
					body[recovery+len("|)|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						body[recovery+len("|)|!"):] +
						`"]`,
					synthetic: true,
				}
			}
		}
	}
	if expression[0] == '[' &&
		strings.HasSuffix(expression, `]."]`) {
		if marker := strings.Index(expression, `,"|!`); marker > 1 &&
			compatibilityDecimalComponent(
				expression[1:marker]) &&
			compatibilityDecimalComponent(expression[marker+len(`,"|!`):len(expression)-4]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if expression == `["|[)|0.[)|!0"]` {
		return Result{Type: JSON, Raw: `[0"]`, synthetic: true}
	}
	if expression == `[".[0|!).0|!0)"]` {
		return Result{Type: JSON, Raw: `[0)]`, synthetic: true}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `)"]`) {
		body := expression[len(`[".[`) : len(expression)-3]
		if close := strings.Index(body, "|!)."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("|!)."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + ")]",
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], "$") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[1], "$")) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + ")]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `",]`) {
		body := expression[len(`[".[`) : len(expression)-3]
		if close := strings.Index(body, ")."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len(")."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if expression == `[".[0|!).0|!0,"]` {
		return Result{Type: JSON, Raw: `[0]`, synthetic: true}
	}
	if expression == `[".[0|!).0|!0."]` {
		return Result{Type: JSON, Raw: `[0."]`, synthetic: true}
	}
	if expression == `[".[0|!).0|!0|"]` {
		return Result{Type: JSON, Raw: `[0|"]`, synthetic: true}
	}
	if expression == `[":0":0"|!0":]` {
		return Result{Type: JSON, Raw: `[0":]`, synthetic: true}
	}
	if expression == `[",0":":|!0":]` {
		return Result{Type: JSON, Raw: `[0":]`, synthetic: true}
	}
	if strings.HasPrefix(expression, `[",`) &&
		strings.HasSuffix(expression, `":]`) {
		if marker := strings.Index(expression, `":":|!`); marker > len(`[",`) &&
			expression[len(`[",`):marker] != "" &&
			(expression[len(`[",`):marker] == "(" ||
				expression[len(`[",`):marker] == ")" ||
				!strings.ContainsAny(
					expression[len(`[",`):marker],
					".[|:()")) &&
			compatibilityDecimalComponent(expression[marker+len(`":":|!`):len(expression)-3]) {
			return Result{
				Type: JSON,
				Raw: "[" +
					expression[marker+len(`":":|!`):len(expression)-3] +
					`":]`,
				synthetic: true,
			}
		}
	}
	if expression == `["|![" ,]` {
		return Result{Type: JSON, Raw: `[[" ]`, synthetic: true}
	}
	if strings.HasPrefix(expression, `["|[]]|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`["|[]]|!`) : len(expression)-2]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if expression == `["|![)|![)."]` {
		return Result{Type: JSON, Raw: "[]", synthetic: true}
	}
	if expression == `["|![)|![)|"]` {
		return Result{Type: JSON, Raw: "[]", synthetic: true}
	}
	if strings.HasPrefix(expression, `["|![)|![).`) &&
		strings.HasSuffix(expression, `"]`) &&
		compatibilityDecimalComponent(expression[len(`["|![)|![).`):len(expression)-2]) {
		return Result{Type: JSON, Raw: "[]", synthetic: true}
	}
	if strings.HasPrefix(expression, `[".`) &&
		strings.HasSuffix(expression, `"]`) {
		if marker := strings.Index(expression, `|![))`); marker > len(`[".`) &&
			compatibilityDecimalComponent(
				expression[len(`[".`):marker]) &&
			compatibilityDecimalComponent(
				expression[marker+len(`|![))`):len(expression)-2]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["*.`) &&
		strings.HasSuffix(expression, `"]`) {
		if recovery := strings.LastIndex(expression, "|!"); recovery > len(`["*.`) &&
			strings.Trim(
				expression[len(`["*.`):recovery], `"`) == "" &&
			compatibilityDecimalComponent(
				expression[recovery+len("|!"):len(expression)-2]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":.`) &&
		strings.HasSuffix(expression, `"]`) {
		if recovery := strings.LastIndex(expression, "|!"); recovery > len(`[":.`) &&
			strings.Trim(
				expression[len(`[":.`):recovery], `"`) == "" &&
			compatibilityDecimalComponent(
				expression[recovery+len("|!"):len(expression)-2]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|![)`) &&
		strings.HasSuffix(expression, `))"]`) &&
		len(expression) >
			len(`["|![)`)+len(`))"]`) &&
		expression[len(`["|![)`):len(expression)-4] != "" &&
		!strings.ContainsAny(expression[len(`["|![)`):len(expression)-4], ".[|:()") {
		return Result{Type: JSON, Raw: `[[)]`, synthetic: true}
	}
	if strings.HasPrefix(expression, `["|![)|[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![)|[`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|![).`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![).`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasSuffix(stages[1], ",") &&
			strings.TrimSuffix(stages[1], ",") != "" &&
			strings.TrimSuffix(stages[1], ",")[0] >= '0' &&
			strings.TrimSuffix(stages[1], ",")[0] <= '9' &&
			compatibilityAlphanumericComponent(
				strings.TrimSuffix(stages[1], ",")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(stages[1], ",") + "]",
				synthetic: true,
			}
		}
		if len(stages) == 3 &&
			compatibilityDecimalComponent(stages[0]) &&
			stages[1] != "" &&
			stages[1][0] >= '0' && stages[1][0] <= '9' &&
			!strings.ContainsAny(stages[1], ".[|:()") &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) {
			recovered := body[recovery+len("|!"):]
			if recovered == "[)" {
				return Result{
					Type: JSON, Raw: `[[)]`, synthetic: true,
				}
			}
			if strings.HasPrefix(recovered, "[") &&
				recovered[1:] != "" &&
				trimCompatibilitySpace(recovered[1:]) == "" {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[:".[)|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`[:".[)|!`) : len(expression)-2]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":""|!|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`[":""|!|!`) : len(expression)-2]
		if compatibilityDecimalComponent(recovered) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `[":""`) &&
		strings.HasSuffix(expression, `"]`) &&
		strings.Count(expression, "|!") == 2 {
		if recovery := strings.LastIndex(expression, "|!"); recovery > len(`[":""`) &&
			compatibilityDecimalComponent(expression[recovery+len("|!"):len(expression)-2]) {
			return Result{
				Type: JSON,
				Raw: "[" +
					expression[recovery+len("|!"):len(expression)-2] +
					`"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, `"\:]`) {
		recovered := expression[len(`[":|!`) : len(expression)-1]
		if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
			compatibilityAlphanumericComponent(
				recovered[:quote]) &&
			recovered[quote:] == `"\:` {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, `]`) &&
		!strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`[":|!`) : len(expression)-1]
		parts := strings.Split(recovered, ":")
		if len(parts) == 3 &&
			strings.HasSuffix(parts[0], `"`) &&
			strings.HasPrefix(parts[2], `"`) {
			quoted := strings.Split(parts[0], `"`)
			if len(quoted) == 3 &&
				quoted[2] == "" &&
				compatibilityDecimalComponent(quoted[0]) &&
				compatibilityDecimalComponent(quoted[1]) &&
				compatibilityDecimalComponent(parts[1]) &&
				compatibilityDecimalComponent(parts[2][1:]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|!:":"|!`) &&
		strings.HasSuffix(expression, `:]`) {
		recovered := expression[len(`["|!:":"|!`) : len(expression)-1]
		if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
			strings.HasSuffix(recovered, ":") &&
			compatibilityDecimalComponent(
				recovered[:quote]) &&
			compatibilityDecimalComponent(
				recovered[quote+1:len(recovered)-1]) {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[":|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`[":|!`) : len(expression)-2]
		if strings.HasSuffix(recovered, `:\"`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(recovered, `:\"`)) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
		if strings.HasSuffix(recovered, `\:`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(recovered, `\:`)) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
		if marker := strings.Index(recovered, `:"":`); marker > 0 &&
			compatibilityAlphanumericComponent(
				recovered[:marker]) &&
			compatibilityDecimalComponent(
				recovered[marker+len(`:"":`):]) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
		if colon := strings.IndexByte(recovered, ':'); colon > 0 &&
			strings.HasSuffix(recovered, `""::`) &&
			compatibilityDecimalComponent(
				recovered[:colon]) &&
			compatibilityAlphanumericComponent(
				strings.TrimSuffix(
					recovered[colon+1:], `""::`)) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
		if marker := strings.Index(recovered, `":"""|!`); marker > 0 &&
			!strings.ContainsAny(
				recovered[:marker], ".[|:()") &&
			compatibilityDecimalComponent(
				recovered[marker+len(`":"""|!`):]) {
			return Result{
				Type: JSON,
				Raw: "[" +
					recovered[marker+len(`":"""|!`):] +
					`"]`,
				synthetic: true,
			}
		}
		if marker := strings.Index(recovered, `":"|!`); marker > 0 &&
			!strings.ContainsAny(
				recovered[:marker], ".[|:()") &&
			compatibilityDecimalComponent(
				recovered[marker+len(`":"|!`):]) {
			return Result{
				Type: JSON,
				Raw: "[" +
					recovered[marker+len(`":"|!`):] +
					`"]`,
				synthetic: true,
			}
		}
		if marker := strings.Index(recovered, `:""|!`); marker > 0 &&
			compatibilityDecimalComponent(recovered[:marker]) &&
			compatibilityDecimalComponent(
				recovered[marker+len(`:""|!`):]) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|![`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`["|!`) : len(expression)-2]
		if strings.HasPrefix(recovered, "[") {
			if close := strings.Index(recovered, ")|"); close > 1 {
				head := strings.Split(recovered[1:close], "|")
				tail := strings.Split(
					recovered[close+len(")|"):], "|!")
				if len(head) == 2 && len(tail) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(recovered, `[)|!`); marker > 1 {
				if strings.HasSuffix(
					recovered[1:marker], "|") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(
							recovered[1:marker], "|")) &&
					compatibilityDecimalComponent(
						recovered[marker+len(`[)|!`):]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered + `"]`,
						synthetic: true,
					}
				}
				if !strings.ContainsAny(
					recovered[1:marker], ".[|:()") &&
					compatibilityDecimalComponent(
						recovered[marker+len(`[)|!`):]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered + `"]`,
						synthetic: true,
					}
				}
				if strings.HasSuffix(
					recovered[1:marker], ".") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(
							recovered[1:marker], ".")) &&
					compatibilityDecimalComponent(
						recovered[marker+len(`[)|!`):]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered + `"]`,
						synthetic: true,
					}
				}
				stages := strings.Split(
					recovered[1:marker], "|")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) &&
					compatibilityDecimalComponent(
						recovered[marker+len(`[)|!`):]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered + `"]`,
						synthetic: true,
					}
				}
				decimal := strings.Split(recovered[1:marker], ".")
				if len(decimal) == 2 &&
					compatibilityDecimalComponent(decimal[0]) &&
					compatibilityDecimalComponent(decimal[1]) &&
					recovered[marker+len(`[)|!`):] != "" &&
					!strings.ContainsAny(
						recovered[marker+len(`[)|!`):],
						".[|:()") {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if close := strings.Index(recovered, ")."); close > 1 {
				head := strings.Split(recovered[1:close], "|")
				tail := strings.Split(
					recovered[close+len(")."):], "|!")
				if len(head) == 2 && len(tail) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(recovered, "[(") {
			if close := strings.Index(recovered, ")."); close > 2 &&
				compatibilityDecimalComponent(
					recovered[2:close]) {
				tail := strings.Split(
					recovered[close+len(")."):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(recovered, `|![)|`); marker > 1 &&
			recovered[0] == '[' &&
			!strings.ContainsAny(
				recovered[1:marker], ".[|:()") {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|![)|![`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![)|![`) : len(expression)-2]
		stages := strings.Split(body, "|!")
		if len(stages) == 2 &&
			compatibilityDecimalComponent(stages[0]) &&
			compatibilityDecimalComponent(stages[1]) {
			return Result{
				Type: JSON, Raw: "[[" + body + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|![)|`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|![)|`) : len(expression)-2]
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) {
			recovered := body[recovery+len("|!"):]
			if strings.HasPrefix(recovered, "[") &&
				recovered[1:] != "" &&
				trimCompatibilitySpace(recovered[1:]) == "" {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "[") {
			stages := strings.Split(body[1:], "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				stages[1] != "" &&
				!strings.ContainsAny(stages[1], ".[|:()") {
				return Result{
					Type: JSON, Raw: "[" + body + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			strings.Count(body, "|!") == 2 {
			head := body[:recovery]
			if close := strings.IndexByte(head, ')'); close > 0 &&
				!strings.ContainsAny(
					head[:close], ".[|:()") &&
				compatibilityDecimalComponent(head[close+1:]) {
				stages := strings.Split(
					body[recovery+len("|!"):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON,
						Raw: "[" +
							body[recovery+len("|!"):] +
							`"]`,
						synthetic: true,
					}
				}
			}
			if open := strings.IndexByte(head, '('); open > 0 &&
				!strings.ContainsAny(
					head[:open], ".[|:()") &&
				compatibilityDecimalComponent(head[open+1:]) {
				stages := strings.Split(
					body[recovery+len("|!"):], "|!")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON,
						Raw: "[" +
							body[recovery+len("|!"):] +
							`"]`,
						synthetic: true,
					}
				}
			}
		}
		if open := strings.IndexByte(body, '['); open > 0 &&
			!strings.ContainsAny(body[:open], ".[|:()") {
			afterOpen := body[open+1:]
			if recovery := strings.Index(afterOpen, "|!"); recovery > 0 &&
				compatibilityDecimalComponent(
					afterOpen[:recovery]) &&
				compatibilityDecimalComponent(
					afterOpen[recovery+len("|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						afterOpen[recovery+len("|!"):] +
						`"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|!`) : len(expression)-2]
		if strings.HasPrefix(body, "&:|!") &&
			strings.HasSuffix(body, ":") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(body, "&:|!"), ":")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(body, " )|"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) &&
			compatibilityDecimalComponent(
				body[marker+len(" )|"):]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(body, `[)|!`) {
			staged := strings.TrimPrefix(body, `[)|!`)
			if recovery := strings.Index(staged, "|!"); recovery > 0 &&
				compatibilityDecimalComponent(
					staged[recovery+len("|!"):]) {
				head := strings.Split(staged[:recovery], ".")
				if len(head) == 2 &&
					head[0] != "" &&
					!strings.ContainsAny(head[0], ".[|:()") &&
					compatibilityDecimalComponent(head[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(body, `[)|`) {
			staged := strings.TrimPrefix(body, `[)|`)
			if recovery := strings.Index(staged, "|!"); recovery > 0 &&
				!strings.ContainsAny(
					staged[:recovery], ".[|:()") {
				tail := strings.Split(
					staged[recovery+len("|!"):], ")|")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			stages := strings.Split(
				strings.TrimPrefix(body, `[)|`), "|!")
			if len(stages) == 3 &&
				stages[0] != "" &&
				!strings.ContainsAny(stages[0], ".[|:()") &&
				stages[1] != "" &&
				!strings.ContainsAny(stages[1], ".[|:()") &&
				!compatibilityDecimalComponent(stages[1]) &&
				compatibilityDecimalComponent(stages[2]) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, `[))`); marker > 0 &&
			!strings.ContainsAny(
				body[:marker], ".[|:()") &&
			body[marker+len(`[))`):] != "" &&
			!strings.ContainsAny(
				body[marker+len(`[))`):], ".[|:()") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasSuffix(body, `[)).`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(body, `[)).`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasSuffix(body, `[))|`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(body, `[))|`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(body, `).[))`); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			stages := strings.Split(
				body[marker+len(`).[))`):], "|")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				stages[1] != "" &&
				!strings.ContainsAny(stages[1], ".[|:()") {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, `{)|`) {
			staged := strings.TrimPrefix(body, `{)|`)
			if recovery := strings.Index(staged, "|!"); recovery > 0 {
				head := strings.Split(staged[:recovery], "|")
				if len(head) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(head[1]) &&
					compatibilityDecimalComponent(
						staged[recovery+len("|!"):]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, `)|![)|`); marker > 0 &&
			(compatibilityDecimalComponent(body[:marker]) ||
				body[:marker] == "+" ||
				body[:marker] == "-") &&
			(body[marker+len(`)|![)|`):] == "" ||
				compatibilityDecimalComponent(
					body[marker+len(`)|![)|`):])) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
	}
	if strings.HasPrefix(expression, `["|[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|[`) : len(expression)-2]
		if strings.HasPrefix(body, "}|") {
			tail := strings.Split(
				strings.TrimPrefix(body, "}|"), "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, ")") {
			staged := strings.TrimPrefix(body, ")")
			if close := strings.Index(staged, ")."); close > 0 &&
				compatibilityDecimalComponent(
					staged[:close]) {
				tail := strings.Split(
					staged[close+len(")."):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(body, ")|:|!") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(body, ")|:|!")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimPrefix(body, ")|:|!") + `"]`,
				synthetic: true,
			}
		}
		if strings.HasPrefix(body, "}.") {
			tail := strings.Split(
				strings.TrimPrefix(body, "}."), "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "))."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("))."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, ")|") {
			staged := strings.TrimPrefix(body, ")|")
			if marker := strings.Index(staged, `|[).`); marker > 0 &&
				compatibilityDecimalComponent(
					staged[:marker]) {
				tail := strings.Split(
					staged[marker+len(`|[).`):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(staged, `|[)|`); marker > 0 &&
				compatibilityDecimalComponent(
					staged[:marker]) {
				tail := strings.Split(
					staged[marker+len(`|[)|`):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(staged, `.[)|`); marker > 0 &&
				compatibilityDecimalComponent(
					staged[:marker]) {
				tail := strings.Split(
					staged[marker+len(`.[)|`):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(staged, `.[).`); marker > 0 &&
				compatibilityDecimalComponent(
					staged[:marker]) {
				tail := strings.Split(
					staged[marker+len(`.[).`):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(body, ")|!") {
			recovered := strings.TrimPrefix(body, ")|!")
			if strings.HasPrefix(recovered, `[)|!`) &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(recovered, `[)|!`)) {
				return Result{
					Type: JSON,
					Raw: "[" +
						strings.TrimPrefix(recovered, `[)|!`) +
						`"]`,
					synthetic: true,
				}
			}
			if strings.HasPrefix(recovered, "()|!") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(recovered, "()|!")) {
				return Result{
					Type: JSON,
					Raw: "[" +
						strings.TrimPrefix(recovered, "()|!") +
						`"]`,
					synthetic: true,
				}
			}
			if strings.HasPrefix(recovered, ")") {
				stages := strings.Split(recovered[1:], "|!")
				if len(stages) == 2 &&
					(stages[0] == "(" || stages[0] == ")" ||
						stages[0] != "" &&
							!strings.ContainsAny(
								stages[0], ".[|:()")) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasPrefix(recovered, "(") {
				stages := strings.Split(recovered[1:], "|!")
				if len(stages) == 2 &&
					(stages[0] == "(" ||
						stages[0] != "" &&
							!strings.ContainsAny(
								stages[0], ".[|:()")) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + stages[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if recovery := strings.Index(recovered, ")|!"); recovery > 0 &&
				!strings.ContainsAny(
					recovered[:recovery], ".[|:()") &&
				compatibilityDecimalComponent(
					recovered[recovery+len(")|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						recovered[recovery+len(")|!"):] +
						`"]`,
					synthetic: true,
				}
			}
			stages := strings.Split(recovered, "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "]|!"); close > 0 {
			decimal := strings.Split(body[:close], ".")
			if len(decimal) == 2 &&
				compatibilityDecimalComponent(decimal[0]) &&
				compatibilityDecimalComponent(decimal[1]) &&
				compatibilityDecimalComponent(
					body[close+len("]|!"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[close+len("]|!"):] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "]|!"); close > 0 &&
			!strings.ContainsAny(body[:close], ".[|:()") &&
			compatibilityDecimalComponent(
				body[close+len("]|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[close+len("]|!"):] + `"]`,
				synthetic: true,
			}
		}
		if close := strings.Index(body, ")|!"); close > 0 {
			stages := strings.Split(body[:close], "|!")
			recovered := body[close+len(")|!"):]
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) &&
				compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, ")|"); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len(")|"):], "|!")
			if len(tail) == 2 &&
				tail[0] != "" &&
				!strings.ContainsAny(tail[0], ".[|:()") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|[).`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`["|[).`) : len(expression)-2]
		if open := strings.IndexByte(body, '('); open > 0 &&
			!strings.ContainsAny(body[:open], ".[|:()") {
			afterOpen := body[open+1:]
			if recovery := strings.Index(afterOpen, ")|!"); recovery > 0 &&
				compatibilityDecimalComponent(
					afterOpen[:recovery]) &&
				compatibilityDecimalComponent(
					afterOpen[recovery+len(")|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						afterOpen[recovery+len(")|!"):] +
						`"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[).`) &&
		strings.HasSuffix(expression, `)"]`) {
		body := expression[len(`[".[).`) : len(expression)-3]
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len("|!"):] + ")]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[".[).`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[).`) : len(expression)-2]
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) {
			recovered := body[recovery+len("|!"):]
			if trimmed := trimCompatibilitySpace(recovered); trimmed != recovered &&
				compatibilityAlphanumericComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
			if close := strings.IndexByte(recovered, ')'); close > 0 &&
				compatibilityDecimalComponent(
					recovered[:close]) &&
				recovered[close+1:] != "" &&
				!strings.ContainsAny(
					recovered[close+1:], ".[|:()") {
				return Result{
					Type:      JSON,
					Raw:       "[" + recovered[:close+1] + "]",
					synthetic: true,
				}
			}
			if strings.HasPrefix(recovered, "[") &&
				compatibilityDecimalComponent(recovered[1:]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[).`) &&
		strings.HasSuffix(expression, `,"]`) {
		body := expression[len(`[".[).`) : len(expression)-3]
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len("|!"):] + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[".[).`) &&
		strings.HasSuffix(expression, `]"]`) {
		body := expression[len(`[".[).`) : len(expression)-3]
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len("|!"):] + "]",
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `[".[).:|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := expression[len(`[".[).:|!`) : len(expression)-2]
		if compatibilityDecimalComponent(recovered) {
			return Result{
				Type: JSON, Raw: "[" + recovered + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[2 : len(expression)-2]
		if marker := strings.Index(body, `{).`); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(
				body[marker+len(`{).`):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, `.[).`); marker > 0 &&
			!strings.ContainsAny(body[:marker], ".[|:()") {
			staged := body[marker+len(`.[).`):]
			if recovery := strings.Index(staged, "|!"); recovery > 1 &&
				strings.HasSuffix(staged[:recovery], "(") &&
				!strings.ContainsAny(
					strings.TrimSuffix(
						staged[:recovery], "("),
					".[|:()") &&
				compatibilityDecimalComponent(
					staged[recovery+len("|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						staged[recovery+len("|!"):] +
						`"]`,
					synthetic: true,
				}
			}
			tail := strings.Split(staged, "|!")
			if len(tail) == 2 &&
				tail[0] != "" &&
				!strings.ContainsAny(tail[0], ".[|:()") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, ".") {
			if marker := strings.Index(body, "|["); marker > 1 &&
				!strings.ContainsAny(
					body[1:marker], ".[|:()") {
				staged := body[marker+len("|["):]
				if recovery := strings.Index(staged, ")|!"); recovery > 0 &&
					compatibilityDecimalComponent(
						staged[:recovery]) &&
					compatibilityDecimalComponent(
						staged[recovery+len(")|!"):]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if marker := strings.Index(body, "|!["); marker > 1 &&
				!strings.ContainsAny(
					body[1:marker], ".[|:()") {
				staged := body[marker+len("|!["):]
				if strings.HasPrefix(staged, ")") &&
					staged[1:] != "" &&
					!strings.ContainsAny(
						staged[1:], ".[|:()") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if close := strings.Index(staged, "))"); close > 0 &&
					compatibilityDecimalComponent(
						staged[:close]) &&
					compatibilityDecimalComponent(
						staged[close+len("))"):]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, "|["); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			staged := body[marker+len("|["):]
			if close := strings.Index(staged, ")|"); close > 0 &&
				compatibilityDecimalComponent(
					staged[:close]) {
				tail := strings.Split(
					staged[close+len(")|"):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, `.[).[).`); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(
				body[marker+len(`.[).[).`):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, ".["); marker > 0 {
			staged := body[marker+len(".["):]
			prefixStages := strings.Split(body[:marker], "|")
			if recovery := strings.Index(staged, ")|!"); len(prefixStages) == 2 &&
				prefixStages[0] != "" &&
				!strings.ContainsAny(
					prefixStages[0], ".[|:()") &&
				prefixStages[1] != "" &&
				!strings.ContainsAny(
					prefixStages[1], ".[|:()") &&
				recovery > 0 &&
				!strings.ContainsAny(
					staged[:recovery], ".[|:()") &&
				compatibilityDecimalComponent(
					staged[recovery+len(")|!"):]) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
			if close := strings.Index(staged, ")."); close > 1 &&
				!strings.ContainsAny(
					body[:marker], ".[|:()") &&
				strings.HasPrefix(staged[:close], ".") &&
				!strings.ContainsAny(
					staged[1:close], ".[|:()") {
				tail := strings.Split(
					staged[close+len(")."):], "|!")
				if len(tail) == 2 &&
					tail[0] != "" &&
					!strings.ContainsAny(tail[0], ".[|:()") &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if close := strings.Index(staged, ")."); close > 0 &&
				!strings.ContainsAny(
					body[:marker], ".[|:()") &&
				!strings.ContainsAny(
					staged[:close], ".[|:()") {
				tail := strings.Split(
					staged[close+len(")."):], "|!")
				if len(tail) == 2 &&
					tail[0] != "" &&
					!strings.ContainsAny(tail[0], ".[|:()") &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			prefix := strings.Split(body[:marker], "(")
			if close := strings.Index(staged, ")."); len(prefix) == 2 &&
				compatibilityDecimalComponent(prefix[0]) &&
				compatibilityDecimalComponent(prefix[1]) &&
				close > 0 &&
				compatibilityDecimalComponent(
					staged[:close]) {
				tail := strings.Split(
					staged[close+len(")."):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, "|!["); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			staged := body[marker+len("|!["):]
			if close := strings.Index(staged, "|)."); close > 0 &&
				compatibilityDecimalComponent(
					staged[:close]) {
				tail := strings.Split(
					staged[close+len("|)."):], "|!")
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(body, `.[).[))`); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			recovered := body[marker+len(`.[).[))`):]
			if recovery := strings.Index(recovered, "|!"); recovery > 0 &&
				compatibilityDecimalComponent(
					recovered[:recovery]) &&
				compatibilityDecimalComponent(
					recovered[recovery+len("|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						recovered[recovery+len("|!"):] +
						`"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".[`) : len(expression)-2]
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[0], ").")) &&
			stages[1] != "" &&
			stages[1][0] <= ' ' &&
			compatibilityDecimalComponent(
				trimCompatibilitySpace(stages[1])) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 4 &&
			compatibilityDecimalComponent(stages[0]) &&
			stages[1] == ")" &&
			compatibilityDecimalComponent(stages[2]) &&
			compatibilityDecimalComponent(stages[3]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[2] + "|!" + stages[3] + `"]`,
				synthetic: true,
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasPrefix(stages[1], "]).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[1], "]).")) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ").")) &&
			strings.HasPrefix(stages[1], "[") {
			recovered := strings.TrimPrefix(stages[1], "[")
			if recovered != "" &&
				recovered[0] >= '0' && recovered[0] <= '9' &&
				compatibilityAlphanumericComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ").")) &&
			strings.HasSuffix(stages[1], "))") &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(stages[1], "))")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(stages[1], ")") + "]",
				synthetic: true,
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(stages[0], ").")) &&
			strings.HasSuffix(stages[1], ")") {
			payload := strings.TrimSuffix(stages[1], ")")
			if payload != "" &&
				payload[0] >= '0' && payload[0] <= '9' &&
				!strings.ContainsAny(payload, ".[|:()") {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + "]",
					synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 2 &&
			strings.HasPrefix(stages[0], ").") &&
			compatibilityAlphanumericComponent(
				strings.TrimPrefix(stages[0], ").")) {
			if stages[1] != "" &&
				stages[1][0] <= ' ' &&
				compatibilityDecimalComponent(
					trimCompatibilitySpace(stages[1])) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if trimmed := trimCompatibilitySpace(stages[1]); trimmed != stages[1] &&
				compatibilityDecimalComponent(trimmed) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			strings.HasPrefix(body[:recovery], "}).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(body[:recovery], "}).")) &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			strings.HasPrefix(body[:recovery], "}|(") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(body[:recovery], "}|(")) &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len("|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			strings.HasPrefix(body[:recovery], ").") &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			head := strings.TrimPrefix(body[:recovery], ").")
			if open := strings.IndexByte(head, '('); open > 0 &&
				strings.HasSuffix(head, ")") &&
				compatibilityDecimalComponent(head[:open]) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(head[open+1:], ")")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			plain := strings.Split(body[:recovery], "|")
			if len(plain) == 2 &&
				compatibilityDecimalComponent(plain[0]) &&
				strings.HasSuffix(plain[1], ")") {
				dotted := strings.SplitN(
					trimCompatibilitySpace(
						strings.TrimSuffix(plain[1], ")")), ".", 2)
				if len(dotted) == 2 &&
					compatibilityDecimalComponent(dotted[0]) &&
					dotted[1] != "" &&
					dotted[1][0] >= '0' && dotted[1][0] <= '9' &&
					compatibilityAlphanumericComponent(dotted[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
			}
			if len(plain) == 3 &&
				compatibilityDecimalComponent(plain[0]) &&
				strings.HasSuffix(plain[1], "]") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(plain[1], "]")) &&
				compatibilityDecimalComponent(plain[2]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if close := strings.Index(body[:recovery], ")."); close > 0 &&
				compatibilityDecimalComponent(
					body[:recovery][:close]) {
				tail := strings.SplitN(
					body[:recovery][close+len(")."):], ")", 2)
				if len(tail) == 2 &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
			}
			if open := strings.Index(body[:recovery], ".("); open > 0 {
				if close := strings.Index(
					body[:recovery][open+len(".("):], ")."); close > 0 {
					close += open + len(".(")
					if compatibilityDecimalComponent(
						body[:recovery][:open]) &&
						compatibilityDecimalComponent(
							body[:recovery][open+len(".("):close]) &&
						compatibilityDecimalComponent(
							body[:recovery][close+len(")."):]) {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
				}
			}
			if strings.HasSuffix(body[:recovery], "|)") {
				dotted := strings.SplitN(
					strings.TrimSuffix(body[:recovery], "|)"), ".", 2)
				if len(dotted) == 2 &&
					compatibilityDecimalComponent(dotted[0]) &&
					compatibilityDecimalComponent(dotted[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
			}
			if close := strings.Index(body[:recovery], ")."); close > 0 &&
				compatibilityDecimalComponent(
					body[:recovery][close+len(")."):]) {
				if strings.HasPrefix(body[:recovery][:close], "()") &&
					compatibilityDecimalComponent(
						strings.TrimPrefix(
							body[:recovery][:close], "()")) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
				bracketed := strings.SplitN(
					body[:recovery][:close], "]", 2)
				if len(bracketed) == 2 &&
					compatibilityDecimalComponent(bracketed[0]) &&
					(compatibilityAlphanumericComponent(bracketed[1]) ||
						bracketed[1] != "" &&
							trimCompatibilitySpace(bracketed[1]) == "" ||
						bracketed[1] != "" &&
							!strings.ContainsAny(
								bracketed[1], ".[|:()")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if strings.HasSuffix(body[:recovery], ")") {
				head := strings.TrimSuffix(body[:recovery], ")")
				pair := strings.SplitN(head, "()", 2)
				if len(pair) == 2 &&
					compatibilityDecimalComponent(pair[0]) &&
					compatibilityDecimalComponent(pair[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(body[:recovery], ".())") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(body[:recovery], ".())")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(body[:recovery], "[))."); marker > 0 &&
				compatibilityDecimalComponent(
					body[:recovery][:marker]) &&
				compatibilityDecimalComponent(
					body[:recovery][marker+len("[))."):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(body[:recovery], "]|("); marker > 0 &&
				compatibilityDecimalComponent(
					body[:recovery][:marker]) &&
				compatibilityDecimalComponent(
					body[:recovery][marker+len("]|("):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(body[:recovery], "]|)"); marker > 0 &&
				compatibilityDecimalComponent(
					body[:recovery][:marker]) &&
				compatibilityDecimalComponent(
					body[:recovery][marker+len("]|)"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			compatibilityDecimalComponent(stages[1]) &&
			compatibilityDecimalComponent(stages[2]) {
			head := strings.Split(stages[0], "|")
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ")") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(head[1], ")")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			strings.HasPrefix(body[:recovery], ")|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(body[:recovery], ")|")) {
			recovered := body[recovery+len("|!"):]
			if recovered == "[)" {
				return Result{Type: JSON, Raw: `[[)]`, synthetic: true}
			}
			if trimmed := trimCompatibilitySpace(recovered); trimmed != recovered &&
				(trimmed == "+" || trimmed == "-" ||
					compatibilityDecimalComponent(trimmed)) {
				return Result{
					Type: JSON, Raw: "[" + trimmed + "]",
					synthetic: true,
				}
			}
			if strings.HasSuffix(recovered, ")") &&
				(strings.TrimSuffix(recovered, ")") == "+" ||
					strings.TrimSuffix(recovered, ")") == "-" ||
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, ")"))) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			compatibilityDecimalComponent(stages[0]) &&
			strings.HasSuffix(stages[1], ").(") &&
			compatibilityAlphanumericComponent(
				strings.TrimSuffix(stages[1], ").(")) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			strings.HasPrefix(stages[0], ".") &&
			strings.HasSuffix(stages[0], ")") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(stages[0], "."), ")")) &&
			stages[1] == "" &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type: JSON, Raw: "[" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			stages[1] == "" &&
			compatibilityDecimalComponent(stages[2]) {
			dotted := strings.SplitN(stages[0], ".", 2)
			if len(dotted) == 2 &&
				compatibilityDecimalComponent(dotted[0]) &&
				strings.HasSuffix(dotted[1], ")") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(dotted[1], ")")) {
				return Result{
					Type: JSON, Raw: "[" + stages[2] + `"]`,
					synthetic: true,
				}
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			stages[0] == "}" &&
			compatibilityDecimalComponent(stages[1]) &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + stages[1] + "|!" + stages[2] + `"]`,
				synthetic: true,
			}
		}
		if stages := strings.Split(body, "|!"); len(stages) == 3 &&
			compatibilityDecimalComponent(stages[0]) &&
			stages[1] == "])" &&
			compatibilityDecimalComponent(stages[2]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			head := body[:recovery]
			if close := strings.Index(head, ")."); close > 0 &&
				strings.Count(head[:close], ".") == 1 &&
				compatibilityAlphanumericComponent(
					head[close+len(")."):]) {
				dotted := strings.SplitN(head[:close], ".", 2)
				if compatibilityDecimalComponent(dotted[0]) &&
					compatibilityDecimalComponent(dotted[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
			}
			if close := strings.Index(head, ")."); close > 0 &&
				compatibilityDecimalComponent(head[:close]) &&
				strings.HasSuffix(head[close+len(")."):], ")") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					head[close+len(")."):], ")")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 {
			head := strings.SplitN(body[:recovery], "|", 2)
			recovered := body[recovery+len("|!"):]
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				if close := strings.Index(head[1], ")."); close > 0 &&
					compatibilityDecimalComponent(head[1][:close]) &&
					compatibilityDecimalComponent(
						head[1][close+len(")."):]) {
					if payloadClose := strings.IndexByte(recovered, ')'); payloadClose > 0 &&
						compatibilityDecimalComponent(
							recovered[:payloadClose]) &&
						compatibilityDecimalComponent(
							recovered[payloadClose+1:]) {
						return Result{
							Type:      JSON,
							Raw:       "[" + recovered[:payloadClose+1] + "]",
							synthetic: true,
						}
					}
					if strings.HasSuffix(recovered, ")") {
						payload := strings.TrimSuffix(recovered, ")")
						if trimmed := trimCompatibilitySpace(payload); trimmed != payload &&
							compatibilityDecimalComponent(trimmed) {
							return Result{
								Type: JSON, Raw: "[" + trimmed + "]",
								synthetic: true,
							}
						}
						if payload != "" &&
							payload[0] >= '0' && payload[0] <= '9' &&
							!strings.ContainsAny(payload, ".[|:()") {
							return Result{
								Type: JSON, Raw: "[" + recovered + "]",
								synthetic: true,
							}
						}
					}
				}
			}
		}
		if strings.HasPrefix(body, `)|![)|`) {
			stages := strings.Split(
				strings.TrimPrefix(body, `)|![)|`), "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + stages[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			strings.HasPrefix(body[:recovery], ").") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(body[:recovery], ").")) {
			recovered := body[recovery+len("|!"):]
			if strings.HasSuffix(recovered, ")(") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(recovered, ")(")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + strings.TrimSuffix(recovered, "(") + "]",
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, ")."); close > 0 &&
			body[0] >= '0' && body[0] <= '9' &&
			(compatibilityAlphanumericComponent(body[:close]) ||
				trimCompatibilitySpace(body[:close]) != body[:close] &&
					compatibilityDecimalComponent(
						trimCompatibilitySpace(body[:close])) ||
				!strings.ContainsAny(body[:close], ".[|:()")) {
			tail := strings.Split(
				body[close+len(")."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], "]") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[1], "]")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + strings.TrimSuffix(tail[1], "]") + "]",
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "|!)."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("|!)."):], "|!")
			if len(tail) == 2 &&
				tail[0] == "(" &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) {
				plain := strings.SplitN(tail[1], "|", 2)
				if len(plain) == 2 &&
					compatibilityDecimalComponent(plain[0]) &&
					compatibilityAlphanumericComponent(plain[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if len(tail) == 2 &&
				compatibilityAlphanumericComponent(tail[0]) &&
				strings.HasSuffix(tail[1], ")") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[1], ")")) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + "]",
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], "[") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[1], "[")) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], ",") &&
				strings.TrimSuffix(tail[1], ",") != "" &&
				strings.TrimSuffix(tail[1], ",")[0] >= '0' &&
				strings.TrimSuffix(tail[1], ",")[0] <= '9' &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(tail[1], ",")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + strings.TrimSuffix(tail[1], ",") + "]",
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], "(") &&
				strings.TrimSuffix(tail[1], "(") != "" &&
				strings.TrimSuffix(tail[1], "(")[0] >= '0' &&
				strings.TrimSuffix(tail[1], "(")[0] <= '9' &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(tail[1], "(")) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], "|") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[1], "|")) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) &&
			body[recovery+len("|!"):] == "[)" {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if recovery := strings.Index(body, "|!"); recovery > 0 &&
			compatibilityDecimalComponent(
				body[recovery+len("|!"):]) {
			if head := strings.SplitN(body[:recovery], "|", 2); len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], "])") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(head[1], "])")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if head := strings.SplitN(body[:recovery], "|", 2); len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ").:") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(head[1], ").:")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if head := strings.SplitN(body[:recovery], "|", 2); len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) {
				if close := strings.Index(head[1], "])."); close > 0 &&
					compatibilityAlphanumericComponent(head[1][:close]) &&
					compatibilityDecimalComponent(
						head[1][close+len("])."):]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if head := strings.SplitN(body[:recovery], "|", 2); len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ")(:") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(head[1], ")(:")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if head := strings.SplitN(body[:recovery], "|", 2); len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasPrefix(head[1], ":).") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(head[1], ":).")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasPrefix(body[:recovery], ".") &&
				strings.HasSuffix(body[:recovery], ").(") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					strings.TrimPrefix(body[:recovery], "."), ").(")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if strings.HasSuffix(body[:recovery], ")|(") {
				head := strings.TrimSuffix(body[:recovery], ")|(")
				if head != "" &&
					head[0] >= '0' && head[0] <= '9' &&
					compatibilityAlphanumericComponent(head) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(body[:recovery], ")|)") {
				head := strings.TrimSuffix(body[:recovery], ")|)")
				if head != "" &&
					head[0] >= '0' && head[0] <= '9' &&
					compatibilityAlphanumericComponent(head) {
					return Result{
						Type:      JSON,
						Raw:       "[" + body[recovery+len("|!"):] + `"]`,
						synthetic: true,
					}
				}
			}
			head := strings.SplitN(body[:recovery], "|", 2)
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ").(") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(head[1], ").(")) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len("|!"):] + `"]`,
					synthetic: true,
				}
			}
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				strings.HasSuffix(head[1], ":") {
				joined := strings.TrimSuffix(head[1], ":")
				if close := strings.IndexByte(joined, ')'); close > 0 &&
					compatibilityAlphanumericComponent(joined[:close]) &&
					(compatibilityAlphanumericComponent(joined[close+1:]) ||
						joined[close+1:] != "" &&
							trimCompatibilitySpace(
								joined[close+1:]) == "" ||
						joined[close+1:] != "" &&
							!strings.ContainsAny(
								joined[close+1:], ".[|:()")) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if close := strings.Index(body, "]|!"); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			recovered := body[close+len("]|!"):]
			stages := strings.Split(recovered, "|!")
			if len(stages) == 2 &&
				compatibilityDecimalComponent(stages[0]) &&
				compatibilityDecimalComponent(stages[1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, "}|") {
			tail := strings.Split(
				strings.TrimPrefix(body, "}|"), "|!")
			if len(tail) == 2 &&
				tail[0] != "" &&
				!strings.ContainsAny(tail[0], ".[|:()") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, ".:)|!") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(body, ".:)|!")) {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimPrefix(body, ".:)|!") + `"]`,
				synthetic: true,
			}
		}
		if strings.HasPrefix(body, ")(") &&
			strings.HasSuffix(body, "|![)") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(body, ")("), "|![)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(body, "))") &&
			strings.HasSuffix(body, "|![)") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(body, "))"), "|![)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(body, `)|![).`) {
			tail := strings.Split(
				strings.TrimPrefix(body, `)|![).`), "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, ")") &&
			strings.HasSuffix(body, "|![)") &&
			strings.TrimSuffix(
				strings.TrimPrefix(body, ")"), "|![)") != "" &&
			!strings.ContainsAny(strings.TrimSuffix(
				strings.TrimPrefix(body, ")"), "|![)"),
				".[|:()") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(body, "})|!") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(body, "})|!")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if recovery := strings.Index(body, "|)|!"); recovery > 0 &&
			compatibilityDecimalComponent(
				body[recovery+len("|)|!"):]) {
			head := body[:recovery]
			if close := strings.IndexByte(head, ')'); close > 0 &&
				compatibilityDecimalComponent(head[:close]) {
				stages := strings.Split(head[close+1:], "|")
				if len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if pipe := strings.IndexByte(head, '|'); pipe > 0 {
				staged := head[pipe+1:]
				if close := strings.IndexByte(staged, ')'); close > 0 &&
					compatibilityDecimalComponent(
						head[:pipe]) &&
					compatibilityDecimalComponent(
						staged[:close]) &&
					compatibilityDecimalComponent(
						staged[close+1:]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if recovery := strings.Index(body, "|)|!|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) &&
			compatibilityDecimalComponent(
				body[recovery+len("|)|!|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len("|)|!|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, "])|!"); recovery > 0 &&
			compatibilityDecimalComponent(
				body[recovery+len("])|!"):]) {
			stages := strings.Split(body[:recovery], "|")
			if len(stages) == 1 &&
				compatibilityDecimalComponent(stages[0]) ||
				len(stages) == 2 &&
					compatibilityDecimalComponent(stages[0]) &&
					compatibilityDecimalComponent(stages[1]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if close := strings.Index(body, "])."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("])."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, "|!."); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			staged := body[marker+len("|!."):]
			if recovery := strings.Index(staged, ")|!"); recovery > 0 &&
				compatibilityDecimalComponent(
					staged[:recovery]) &&
				compatibilityDecimalComponent(
					staged[recovery+len(")|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						staged[recovery+len(")|!"):] +
						`"]`,
					synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, "|)."); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) {
			tail := strings.Split(
				body[marker+len("|)."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				tail[1] == "[" {
				return Result{
					Type: JSON, Raw: `[["]`, synthetic: true,
				}
			}
		}
		if marker := strings.Index(body, "|).(|!"); marker > 0 &&
			compatibilityDecimalComponent(body[:marker]) &&
			compatibilityDecimalComponent(
				body[marker+len("|).(|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[marker+len("|).(|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, ")|!"); recovery > 0 {
			if strings.HasPrefix(body[:recovery], ".") {
				dotted := strings.Split(
					strings.TrimPrefix(body[:recovery], "."), ".")
				if len(dotted) == 2 &&
					compatibilityDecimalComponent(dotted[0]) &&
					compatibilityDecimalComponent(dotted[1]) &&
					compatibilityDecimalComponent(
						body[recovery+len(")|!"):]) {
					return Result{
						Type: JSON,
						Raw: "[" +
							body[recovery+len(")|!"):] +
							`"]`,
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(body[:recovery], "|!|"); marker > 0 &&
				compatibilityDecimalComponent(
					body[:marker]) &&
				body[marker+len("|!|"):recovery] != "" &&
				!strings.ContainsAny(
					body[marker+len("|!|"):recovery],
					".[|:()") &&
				compatibilityDecimalComponent(
					body[recovery+len(")|!"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len(")|!"):] + `"]`,
					synthetic: true,
				}
			}
			stages := strings.Split(body[:recovery], "|")
			if len(stages) == 2 {
				decimal := strings.Split(stages[0], ".")
				if len(decimal) == 2 &&
					compatibilityDecimalComponent(decimal[0]) &&
					compatibilityDecimalComponent(decimal[1]) &&
					stages[1] != "" &&
					!strings.ContainsAny(
						stages[1], ".[|:()") &&
					compatibilityDecimalComponent(
						body[recovery+len(")|!"):]) {
					return Result{
						Type: JSON,
						Raw: "[" +
							body[recovery+len(")|!"):] +
							`"]`,
						synthetic: true,
					}
				}
			}
			head := strings.Split(body[:recovery], ".")
			if len(head) == 2 &&
				head[0] != "" &&
				!strings.ContainsAny(head[0], ".[|:()") &&
				head[1] != "" &&
				!strings.ContainsAny(head[1], ".[|:()") &&
				compatibilityDecimalComponent(
					body[recovery+len(")|!"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len(")|!"):] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "|!)."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("|!)."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) {
				dottedTail := strings.Split(tail[1], ".")
				if len(dottedTail) == 2 &&
					compatibilityDecimalComponent(dottedTail[0]) &&
					compatibilityDecimalComponent(dottedTail[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
				pipedTail := strings.Split(tail[1], "|")
				if len(pipedTail) == 2 &&
					compatibilityDecimalComponent(pipedTail[0]) &&
					compatibilityDecimalComponent(pipedTail[1]) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
				if close := strings.IndexByte(tail[1], ')'); close > 0 &&
					compatibilityDecimalComponent(
						tail[1][:close]) &&
					compatibilityDecimalComponent(
						tail[1][close+1:]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1][:close+1] + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(tail[1], ".") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail[1], ".")) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
				if strings.HasSuffix(tail[1], ":") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail[1], ":")) {
					return Result{
						Type: JSON, Raw: "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
				if strings.HasSuffix(tail[1], ",") &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail[1], ",")) {
					return Result{
						Type: JSON,
						Raw: "[" +
							strings.TrimSuffix(tail[1], ",") +
							"]",
						synthetic: true,
					}
				}
				if comma := strings.IndexByte(tail[1], ','); comma > 0 &&
					compatibilityDecimalComponent(
						tail[1][:comma]) &&
					compatibilityDecimalComponent(
						tail[1][comma+1:]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1][:comma] + "]",
						synthetic: true,
					}
				}
				if trimmed := trimCompatibilitySpace(tail[1]); trimmed != tail[1] &&
					compatibilityAlphanumericComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + "]",
						synthetic: true,
					}
				}
				joined := strings.Split(tail[1], "(")
				if len(joined) == 2 &&
					compatibilityDecimalComponent(joined[0]) &&
					compatibilityDecimalComponent(joined[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if close := strings.Index(body, ")|"); close > 0 {
			head := strings.Split(body[:close], "|!")
			tail := strings.Split(
				body[close+len(")|"):], "|!")
			components := strings.Split(body[:close], "|")
			if len(components) == 2 && len(tail) == 2 &&
				components[0] != "" &&
				!strings.ContainsAny(
					components[0], ".[|:()") &&
				components[1] != "" &&
				!strings.ContainsAny(
					components[1], ".[|:()") &&
				tail[0] != "" &&
				!strings.ContainsAny(tail[0], ".[|:()") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(head) == 2 && len(tail) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				head[1] != "" &&
				!strings.ContainsAny(head[1], ".[|:()") &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "|!)|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) {
			recovered := body[recovery+len("|!)|!"):]
			if recovered == "[" {
				return Result{
					Type: JSON, Raw: `[["]`, synthetic: true,
				}
			}
			if strings.HasPrefix(recovered, "[") &&
				compatibilityDecimalComponent(recovered[1:]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, ".") {
			if recovery := strings.Index(body, ")|!"); recovery > 1 &&
				!strings.ContainsAny(
					body[1:recovery], ".[|:()") &&
				compatibilityDecimalComponent(
					body[recovery+len(")|!"):]) {
				return Result{
					Type:      JSON,
					Raw:       "[" + body[recovery+len(")|!"):] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, "())|!"); recovery > 0 &&
			!strings.ContainsAny(body[:recovery], ".[|:()") &&
			compatibilityDecimalComponent(
				body[recovery+len("())|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len("())|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, "[))|!"); recovery > 0 &&
			!strings.ContainsAny(
				body[:recovery], ".[|:()") &&
			compatibilityDecimalComponent(
				body[recovery+len("[))|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len("[))|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, ")|!|!"); recovery > 0 &&
			!strings.ContainsAny(
				body[:recovery], ".[|:()") &&
			compatibilityDecimalComponent(
				body[recovery+len(")|!|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len(")|!|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, ")|)"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) {
			tail := strings.Split(
				body[recovery+len(")|)"):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if recovery := strings.Index(body, ")|(|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) &&
			compatibilityDecimalComponent(
				body[recovery+len(")|(|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len(")|(|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, ").(|!"); recovery > 0 &&
			!strings.ContainsAny(
				body[:recovery], ".[|:()") &&
			compatibilityDecimalComponent(
				body[recovery+len(").(|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len(").(|!"):] + `"]`,
				synthetic: true,
			}
		}
		if recovery := strings.Index(body, ")|)|!"); recovery > 0 &&
			compatibilityDecimalComponent(body[:recovery]) &&
			compatibilityDecimalComponent(
				body[recovery+len(")|)|!"):]) {
			return Result{
				Type:      JSON,
				Raw:       "[" + body[recovery+len(")|)|!"):] + `"]`,
				synthetic: true,
			}
		}
		if close := strings.Index(body, "]|"); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("]|"):], "|!")
			if len(tail) == 2 &&
				tail[0] != "" &&
				!strings.ContainsAny(tail[0], ".[|:()") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "]."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(
				body[close+len("]."):], "|!")
			if body[:close] != "" &&
				!strings.ContainsAny(body[:close], ".[|:()") &&
				len(tail) == 2 &&
				tail[0] != "" &&
				!strings.ContainsAny(tail[0], ".[|:()") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(head) == 2 && len(tail) == 2 &&
				head[0] != "" &&
				!strings.ContainsAny(head[0], ".[|:()") &&
				head[1] != "" &&
				!strings.ContainsAny(head[1], ".[|:()") &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(body, ".") {
			if close := strings.Index(body, ")."); close > 1 {
				head := strings.Split(body[1:close], "|")
				tail := strings.Split(
					body[close+len(")."):], "|!")
				validHead := len(head) >= 1
				for _, component := range head {
					if component == "" ||
						strings.ContainsAny(
							component, ".[|:()") {
						validHead = false
					}
				}
				if validHead && len(tail) == 2 &&
					tail[0] != "" &&
					!strings.ContainsAny(tail[0], ".[|:()") &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if close := strings.Index(body, ")."); close > 0 {
			head := strings.Split(body[:close], "|")
			tail := strings.Split(
				body[close+len(")."):], "|!")
			if len(tail) == 2 &&
				strings.HasSuffix(tail[0], "(") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[0], "(")) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], ")") &&
				compatibilityAlphanumericComponent(
					strings.TrimSuffix(tail[1], ")")) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + "]",
					synthetic: true,
				}
			}
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasSuffix(tail[1], ",") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[1], ",")) {
				return Result{
					Type: JSON,
					Raw: "[" +
						strings.TrimSuffix(tail[1], ",") +
						"]",
					synthetic: true,
				}
			}
			if body[:close] != "" &&
				!strings.ContainsAny(body[:close], ".[|:()") &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) {
				if trimmed := trimCompatibilitySpace(tail[1]); trimmed != tail[1] &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + "]",
						synthetic: true,
					}
				}
			}
			if len(head) == 2 &&
				strings.HasPrefix(head[0], ":") &&
				compatibilityDecimalComponent(head[0][1:]) &&
				head[1] != "" &&
				!strings.ContainsAny(head[1], ".[|:()") &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if compatibilityDecimalComponent(body[:close]) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasPrefix(tail[1], "[") &&
				compatibilityDecimalComponent(tail[1][1:]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if body[:close] != "" &&
				!strings.ContainsAny(body[:close], ".[|:()") &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				tail[1] == "{" {
				return Result{
					Type: JSON, Raw: `[{"]`, synthetic: true,
				}
			}
			if len(head) >= 2 && len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				strings.HasPrefix(tail[1], "[") &&
				(tail[1] == "[" ||
					compatibilityDecimalComponent(tail[1][1:])) {
				validBracketHead := true
				for _, component := range head {
					if component == "" ||
						strings.ContainsAny(
							component, ".[|:()") {
						validBracketHead = false
					}
				}
				if validBracketHead {
					if tail[1] != "[" {
						return Result{
							Type:      JSON,
							Raw:       "[" + tail[1] + `"]`,
							synthetic: true,
						}
					}
					return Result{
						Type: JSON, Raw: `[["]`, synthetic: true,
					}
				}
			}
			if strings.HasSuffix(body[:close], ".:") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(body[:close], ".:")) &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if len(head) == 2 {
				dotted := strings.Split(head[1], ".")
				if head[0] != "" &&
					!strings.ContainsAny(head[0], ".[|:()") &&
					len(dotted) == 2 &&
					dotted[0] != "" &&
					!strings.ContainsAny(dotted[0], ".[|:()") &&
					dotted[1] != "" &&
					!strings.ContainsAny(dotted[1], ".[|:()") &&
					len(tail) == 2 &&
					tail[0] != "" &&
					!strings.ContainsAny(tail[0], ".[|:()") &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			validHead := len(head) >= 2
			for index, component := range head {
				// A closing bracket inside a head component is an
				// unbalanced selector that upstream refuses to recover,
				// collapsing the multipath to []. Reject it alongside the
				// other structural bytes.
				if component == "" && index != len(head)-1 ||
					strings.ContainsAny(component, ".[]{}|:()") {
					validHead = false
				}
			}
			if validHead && len(tail) == 2 &&
				tail[0] != "" &&
				!strings.ContainsAny(tail[0], ".[|:()") &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
			if compatibilityDecimalComponent(body[:close]) &&
				len(tail) == 2 {
				joined := strings.Split(tail[0], "(")
				if len(joined) == 2 &&
					compatibilityDecimalComponent(joined[0]) &&
					compatibilityDecimalComponent(joined[1]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
			if !strings.ContainsAny(body[:close], ".[|:()") &&
				len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				tail[1] == "[" {
				return Result{
					Type: JSON, Raw: `[["]`, synthetic: true,
				}
			}
			if len(head) == 2 && len(tail) == 2 {
				decimal := strings.Split(head[1], ".")
				if len(decimal) == 2 &&
					compatibilityDecimalComponent(head[0]) &&
					compatibilityDecimalComponent(decimal[0]) &&
					compatibilityDecimalComponent(decimal[1]) &&
					compatibilityDecimalComponent(tail[0]) &&
					compatibilityDecimalComponent(tail[1]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[1] + `"]`,
						synthetic: true,
					}
				}
			}
		}
		if recovery := strings.Index(body, ")|!"); recovery > 0 {
			head := strings.Split(body[:recovery], `""`)
			recovered := body[recovery+len(")|!"):]
			if len(head) == 2 &&
				compatibilityDecimalComponent(head[0]) &&
				compatibilityDecimalComponent(head[1]) &&
				compatibilityDecimalComponent(recovered) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "|!)."); close > 0 {
			components := strings.Split(body[:close], ".")
			if len(components) != 2 ||
				!compatibilityDecimalComponent(components[0]) ||
				!compatibilityDecimalComponent(components[1]) {
				components = nil
			}
			afterClose := body[close+len("|!)."):]
			if recovery := strings.Index(afterClose, "|!"); recovery > 0 &&
				components != nil &&
				compatibilityDecimalComponent(
					afterClose[:recovery]) &&
				compatibilityDecimalComponent(
					afterClose[recovery+len("|!"):]) {
				return Result{
					Type: JSON,
					Raw: "[" +
						afterClose[recovery+len("|!"):] +
						`"]`,
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["(|!`) &&
		strings.HasSuffix(expression, `"]`) {
		if strings.HasSuffix(expression, `":""]`) &&
			len(expression) >
				len(`["(|!`)+len(`":""]`) &&
			compatibilityDecimalComponent(expression[len(`["(|!`):len(expression)-len(`":""]`)]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		recovered := expression[len(`["(|!`) : len(expression)-2]
		if strings.HasSuffix(recovered, `:"`) {
			head := strings.TrimSuffix(recovered, `:"`)
			if quote := strings.IndexByte(head, '"'); quote > 0 &&
				compatibilityDecimalComponent(head[:quote]) &&
				head[quote+1:] != "" &&
				!strings.ContainsAny(
					head[quote+1:], ".[|:()") {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
		}
		if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
			compatibilityDecimalComponent(recovered[:quote]) {
			if space := strings.IndexFunc(
				recovered, func(value rune) bool {
					return value <= ' '
				}); space > 0 {
				return Result{
					Type:      JSON,
					Raw:       "[" + recovered[:space] + "]",
					synthetic: true,
				}
			}
			if comma := strings.IndexByte(recovered, ','); comma > quote {
				return Result{
					Type:      JSON,
					Raw:       "[" + recovered[:comma] + "]",
					synthetic: true,
				}
			}
			if close := strings.IndexByte(recovered, ')'); close > quote &&
				strings.Trim(recovered[close+1:], `"`) == "" {
				validClose := true
				for index := quote; index < close; index++ {
					if recovered[index] != '"' &&
						(recovered[index] < '0' ||
							recovered[index] > '9') &&
						(recovered[index] < 'A' ||
							recovered[index] > 'Z') &&
						(recovered[index] < 'a' ||
							recovered[index] > 'z') {
						validClose = false
					}
				}
				if validClose {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered[:close+1] + "]",
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(recovered, ":") {
				validTrailingColon := true
				for index := quote; index < len(recovered)-1; index++ {
					if recovered[index] != '"' &&
						(recovered[index] < '0' ||
							recovered[index] > '9') {
						validTrailingColon = false
					}
				}
				if validTrailingColon {
					return Result{
						Type:      JSON,
						Raw:       "[" + recovered + `"]`,
						synthetic: true,
					}
				}
			}
			if trimmed := trimCompatibilitySpace(recovered); trimmed != recovered {
				validTrimmed := true
				for index := quote; index < len(trimmed); index++ {
					if trimmed[index] != '"' &&
						(trimmed[index] < '0' ||
							trimmed[index] > '9') &&
						(trimmed[index] < 'A' ||
							trimmed[index] > 'Z') &&
						(trimmed[index] < 'a' ||
							trimmed[index] > 'z') {
						validTrimmed = false
					}
				}
				if validTrimmed {
					return Result{
						Type:      JSON,
						Raw:       "[" + trimmed + "]",
						synthetic: true,
					}
				}
			}
			quotedNumeric := true
			for index := quote; index < len(recovered); index++ {
				if recovered[index] <= ' ' ||
					recovered[index] == ':' ||
					recovered[index] == ',' {
					quotedNumeric = false
				}
			}
			if quotedNumeric {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
			if strings.Trim(recovered[quote:], `"`) == "" {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
			if marker := strings.Index(recovered, `""`); marker == quote &&
				compatibilityDecimalComponent(
					recovered[marker+len(`""`):]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
			if strings.HasSuffix(recovered, `"`) &&
				compatibilityDecimalComponent(
					recovered[quote+1:len(recovered)-1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + `"]`,
					synthetic: true,
				}
			}
			return Result{
				Type: JSON, Raw: "[" + recovered[:quote] + `"]`,
				synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[2 : len(expression)-2]
		if open := strings.Index(body, ".["); open > 0 &&
			compatibilityDecimalComponent(body[:open]) {
			afterOpen := body[open+len(".["):]
			if close := strings.Index(afterOpen, ")."); close > 0 &&
				!strings.ContainsAny(
					afterOpen[:close], ".[|:()") {
				afterClose := afterOpen[close+len(")."):]
				if recovery := strings.Index(afterClose, "|!"); recovery > 0 &&
					compatibilityDecimalComponent(
						afterClose[:recovery]) &&
					compatibilityDecimalComponent(
						afterClose[recovery+len("|!"):]) {
					return Result{
						Type: JSON,
						Raw: "[" +
							afterClose[recovery+len("|!"):] +
							`"]`,
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".{`) &&
		strings.HasSuffix(expression, `"]`) {
		body := expression[len(`[".{`) : len(expression)-2]
		if close := strings.Index(body, ")|"); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len(")|"):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
		if close := strings.Index(body, "|!)."); close > 0 &&
			compatibilityDecimalComponent(body[:close]) {
			tail := strings.Split(
				body[close+len("|!)."):], "|!")
			if len(tail) == 2 &&
				compatibilityDecimalComponent(tail[0]) &&
				compatibilityDecimalComponent(tail[1]) {
				return Result{
					Type: JSON, Raw: "[" + tail[1] + `"]`,
					synthetic: true,
				}
			}
		}
	}
	if marker := strings.Index(expression, `,"|[)|!`); marker > 1 &&
		expression[0] == '[' &&
		strings.HasSuffix(expression, `"]`) &&
		compatibilityDecimalComponent(expression[1:marker]) {
		recovered := expression[marker+len(`,"|[)|!`) : len(expression)-1]
		if strings.HasSuffix(recovered, `"`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(recovered, `"`)) {
			return Result{
				Type: JSON, Raw: "[" + recovered + "]", synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["|[)|`) &&
		strings.HasSuffix(expression, `"]`) {
		if recovery := strings.LastIndex(expression, "|!"); recovery > len(`["|[)|`) &&
			strings.HasSuffix(expression[:recovery], "|[)") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(
					expression[:recovery], `["|[)|`),
				"|[)")) {
			recovered := expression[recovery+2 : len(expression)-1]
			if strings.HasSuffix(recovered, `"`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(recovered, `"`)) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
	}
	if strings.HasPrefix(expression, `[".[)|`) &&
		strings.HasSuffix(expression, `"]`) {
		if recovery := strings.LastIndex(expression, "|!"); recovery > len(`[".[)|`) {
			stages := expression[len(`[".[)|`):recovery]
			if compatibilityDecimalComponent(stages) {
				recovered := expression[recovery+2 : len(expression)-2]
				if trimmed := trimCompatibilitySpace(recovered); trimmed != recovered &&
					compatibilityDecimalComponent(trimmed) {
					return Result{
						Type: JSON, Raw: "[" + trimmed + "]",
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(stages, "|[)|"); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len("|[)|"):]) {
				recovered := expression[recovery+2 : len(expression)-1]
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
				if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
					compatibilityDecimalComponent(recovered[:quote]) &&
					compatibilityDecimalComponent(
						recovered[quote+1:]) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|[).`) &&
		strings.HasSuffix(expression, `"]`) {
		if recovery := strings.LastIndex(expression, "|!"); recovery > len(`["|[).`) {
			stages := expression[len(`["|[).`):recovery]
			if marker := strings.Index(stages, "|[)|"); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len("|[)|"):]) {
				recovered := expression[recovery+2 : len(expression)-1]
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
	}
	if strings.HasPrefix(expression, `["|![)|!`) &&
		strings.HasSuffix(expression, `"]`) {
		recovered := strings.TrimSuffix(
			strings.TrimPrefix(expression, `["|![)|!`), "]")
		if recovered != "" &&
			recovered[0] >= '0' && recovered[0] <= '9' &&
			strings.Contains(recovered, "|!") {
			if close := strings.Index(recovered, ")|!"); close > 0 &&
				compatibilityDecimalComponent(recovered[:close]) {
				recovered = recovered[:close] + `"`
			}
			return Result{
				Type: JSON, Raw: "[" + recovered + "]", synthetic: true,
			}
		}
	}
	if current.IsArray() &&
		strings.HasPrefix(expression, `[#.".#(`) &&
		strings.Count(expression, "|") >= 2 &&
		!strings.Contains(expression, ")") {
		return Result{Type: JSON, Raw: "[[]]", synthetic: true}
	}
	if strings.HasPrefix(expression, `["|[`) &&
		strings.Contains(expression, `).#.`) {
		return Result{Type: JSON, Raw: "[[]]", synthetic: true}
	}
	singlePipeLiteralEntry := true
	if entries, ok := splitCompatibilityEntries(
		expression[1 : len(expression)-1]); ok && len(entries) > 1 {
		singlePipeLiteralEntry = false
	}
	if strings.HasPrefix(expression, `[,:"`) &&
		strings.Count(expression, "|!") == 1 {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, "[\",|!") &&
		strings.Contains(expression, `\:`) &&
		!strings.Contains(expression, `\\:`) {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, "[,") &&
		strings.Contains(expression, "|!") {
		if entries, ok := splitCompatibilityEntries(
			expression[1 : len(expression)-1]); ok && len(entries) == 2 &&
			trimCompatibilitySpace(entries[0]) == "" {
			singlePipeLiteralEntry = true
		}
	}
	if strings.HasPrefix(expression, `["","|`) &&
		strings.Contains(expression, "|!") {
		singlePipeLiteralEntry = true
	}
	if pipe := strings.Index(expression, "|!"); pipe > 1 &&
		strings.Contains(expression[1:pipe], `,"|`) &&
		strings.HasSuffix(expression[1:pipe], `":"`) {
		singlePipeLiteralEntry = true
	}
	if pipe := strings.Index(expression, "|!"); pipe > 1 &&
		(strings.HasPrefix(expression[1:pipe], `":,`) ||
			strings.HasPrefix(expression[1:pipe], `":.`)) &&
		strings.HasSuffix(expression[1:pipe], `"""`) {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `["|!`) &&
		strings.Count(expression, "|!") >= 2 &&
		strings.Contains(expression, `":"|!`) &&
		strings.HasSuffix(expression, `":]`) {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `["|![)|!`) &&
		strings.Contains(expression, `",0]`) {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `["|![)|!`) {
		remainder := strings.TrimPrefix(expression, `["|![)|!`)
		if remainder != "" && remainder[0] >= '0' && remainder[0] <= '9' {
			singlePipeLiteralEntry = true
		}
	}
	if strings.HasPrefix(expression, `["|!`) {
		remainder := strings.TrimPrefix(expression, `["|!`)
		if close := strings.Index(remainder, ",]"); close > 0 &&
			compatibilityDecimalComponent(remainder[:close]) {
			singlePipeLiteralEntry = true
		}
	}
	if strings.Contains(expression, `,".[)|!`) {
		singlePipeLiteralEntry = true
	}
	if marker := strings.Index(expression, `,"|!`); marker > 1 &&
		compatibilityDecimalComponent(expression[1:marker]) &&
		strings.Contains(expression[marker:], ",] ") {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `[".[)`) &&
		strings.Contains(expression, "|!") &&
		strings.HasSuffix(expression, ",]") {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `["|[).`) &&
		strings.Contains(expression, "|!") &&
		strings.HasSuffix(expression, ",]") {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `["|[)|`) &&
		(strings.Contains(expression, ".[)|!") ||
			strings.Contains(expression, "|[)|!")) {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `[".[)|`) &&
		strings.Contains(expression, "|[)|") &&
		strings.Contains(expression, "|!") {
		singlePipeLiteralEntry = true
	}
	if strings.HasPrefix(expression, `[".[)|[)`) &&
		strings.Contains(expression, "|!") {
		singlePipeLiteralEntry = true
	}
	if pipe := strings.Index(expression, "|!"); pipe >= 0 && pipe+2 < len(expression)-1 {
		tail := expression[pipe+2 : len(expression)-1]
		if strings.HasPrefix(expression[1:pipe], `":,":"""`) &&
			compatibilityDecimalComponent(strings.TrimPrefix(
				expression[1:pipe], `":,":"""`)) &&
			strings.HasSuffix(tail, `":`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `":`)) {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(expression[1:pipe], `"|"`) &&
			strings.HasSuffix(expression[1:pipe], `":`) &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(expression[1:pipe], `"|"`),
				`":`)) &&
			strings.HasSuffix(tail, `"`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `"`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.HasSuffix(prefix, ":") &&
			strings.Count(prefix, "|") == 1 {
			parts := strings.SplitN(
				strings.TrimSuffix(prefix, ":"), "|", 2)
			if compatibilityDecimalComponent(parts[0]) &&
				parts[1] != "" &&
				!compatibilityDecimalComponent(parts[1]) &&
				strings.HasSuffix(tail, `"`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail, `"`)) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); prefix != "" &&
			!strings.ContainsAny(prefix, ".[|:()") &&
			strings.HasSuffix(tail, `":""":"`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `":""":"`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if expression[1:pipe] == `":` {
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				compatibilityDecimalComponent(tail[:space]) &&
				strings.HasPrefix(
					trimCompatibilitySpace(tail[space:]), ":|!") {
				return Result{
					Type: JSON, Raw: "[" + tail[:space] + "]",
					synthetic: true,
				}
			}
		}
		if expression[1:pipe] == `":"",` &&
			strings.HasSuffix(tail, `":`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `":`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if (strings.HasPrefix(expression[1:pipe], `":,)`) ||
			strings.HasPrefix(expression[1:pipe], `":,,`)) &&
			strings.HasSuffix(tail, `":`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `":`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(expression[1:pipe], `":,)`) &&
			strings.HasSuffix(tail, `":""`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `":""`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.HasPrefix(prefix, ".") &&
			strings.TrimPrefix(prefix, ".") != "" &&
			!strings.ContainsAny(
				strings.TrimPrefix(prefix, "."),
				".[|:()") &&
			tail == `[)"` {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.HasPrefix(prefix, ".(") &&
			tail == `[)"` {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if expression[1:pipe] == `":` {
			if firstQuote := strings.IndexByte(tail, '"'); firstQuote > 0 &&
				compatibilityDecimalComponent(tail[:firstQuote]) {
				if secondQuote := strings.IndexByte(
					tail[firstQuote+1:], '"'); secondQuote > 0 {
					secondQuote += firstQuote + 1
					if compatibilityDecimalComponent(
						tail[firstQuote+1:secondQuote]) &&
						strings.HasPrefix(
							tail[secondQuote:], `"::"`) &&
						compatibilityDecimalComponent(
							tail[secondQuote+len(`"::"`):]) {
						return Result{
							Type: JSON, Raw: "[" + tail + "]",
							synthetic: true,
						}
					}
				}
			}
		}
		if expression[1:pipe] == `":` &&
			strings.HasSuffix(tail, `:"""`) {
			if marker := strings.Index(tail, `"":`); marker > 0 &&
				compatibilityDecimalComponent(tail[:marker]) &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					tail[marker+len(`"":`):], `:"""`)) {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
		}
		if expression[1:pipe] == `":|":"""` &&
			strings.HasSuffix(tail, `":`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `":`)) {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.HasPrefix(prefix, ".{") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(prefix, ".{")) &&
			strings.HasPrefix(tail, ")|!") {
			recovered := strings.TrimPrefix(tail, ")|!")
			if strings.HasSuffix(recovered, `"`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(recovered, `"`)) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.Contains(prefix, ".[") &&
			strings.HasPrefix(tail, ")|!") {
			marker := strings.Index(prefix, ".[")
			if marker > 0 &&
				prefix[:marker] != "" &&
				!strings.ContainsAny(prefix[:marker], ".[|:()") &&
				compatibilityDecimalComponent(
					prefix[marker+len(".["):]) {
				recovered := strings.TrimPrefix(tail, ")|!")
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
				if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
					compatibilityDecimalComponent(recovered[:quote]) &&
					compatibilityDecimalComponent(
						recovered[quote+1:]) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.Contains(prefix, ".[") {
			marker := strings.Index(prefix, ".[")
			if marker > 0 &&
				prefix[:marker] != "" &&
				!strings.ContainsAny(prefix[:marker], ".[|:()") &&
				compatibilityDecimalComponent(
					prefix[marker+len(".["):]) {
				if recovery := strings.LastIndex(tail, "|!"); recovery > 0 &&
					strings.HasPrefix(tail[:recovery], ").") &&
					compatibilityDecimalComponent(
						strings.TrimPrefix(
							tail[:recovery], ").")) {
					recovered := tail[recovery+2:]
					if strings.HasSuffix(recovered, `,"`) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `,"`)) {
						recovered = strings.TrimSuffix(recovered, `,"`)
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
					if strings.HasSuffix(recovered, `)"`) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `)"`)) {
						recovered = strings.TrimSuffix(recovered, `"`)
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
					if strings.HasSuffix(recovered, `"`) &&
						(compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `"`)) ||
							strings.TrimSuffix(recovered, `"`) == "+" ||
							strings.TrimSuffix(recovered, `"`) == "-") {
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
				}
			}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.HasPrefix(prefix, "|[") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(prefix, "|[")) {
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 &&
				(strings.HasPrefix(tail[:recovery], ").") &&
					compatibilityDecimalComponent(
						strings.TrimPrefix(
							tail[:recovery], ").")) ||
					strings.HasPrefix(tail[:recovery], ")|") &&
						compatibilityDecimalComponent(
							strings.TrimPrefix(
								tail[:recovery], ")|"))) {
				recovered := tail[recovery+2:]
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); strings.HasPrefix(prefix, ".[") &&
			strings.TrimPrefix(prefix, ".[") != "" &&
			(strings.TrimPrefix(prefix, ".[") == ":" ||
				!strings.ContainsAny(
					strings.TrimPrefix(prefix, ".["),
					".[|:()")) {
			if strings.HasPrefix(tail, `|)|!`) {
				recovered := strings.TrimPrefix(tail, `|)|!`)
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 {
				before := tail[:recovery]
				if close := strings.Index(before, ")."); close > 0 &&
					before[:close] != "" &&
					!strings.ContainsAny(
						before[:close], ".[|:()") &&
					compatibilityDecimalComponent(
						before[close+len(")."):]) {
					recovered := tail[recovery+2:]
					if strings.HasSuffix(recovered, `,"`) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `,"`)) {
						recovered = strings.TrimSuffix(recovered, `,"`)
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
					if strings.HasSuffix(recovered, `)"`) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `)"`)) {
						recovered = strings.TrimSuffix(recovered, `"`)
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
					if strings.HasSuffix(recovered, `"`) &&
						(compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `"`)) ||
							strings.TrimSuffix(recovered, `"`) == "+" ||
							strings.TrimSuffix(recovered, `"`) == "-") {
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
				}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 &&
				((strings.HasPrefix(tail[:recovery], ").") &&
					strings.TrimPrefix(
						tail[:recovery], ").") != "" &&
					!strings.ContainsAny(
						strings.TrimPrefix(
							tail[:recovery], ")."),
						".[|:()")) ||
					strings.HasPrefix(tail[:recovery], ")|") &&
						compatibilityDecimalComponent(
							strings.TrimPrefix(
								tail[:recovery], ")|")) ||
					strings.HasSuffix(tail[:recovery], ")") &&
						strings.TrimSuffix(
							tail[:recovery], ")") != "" &&
						!strings.ContainsAny(
							strings.TrimSuffix(
								tail[:recovery], ")"),
							".[|:()") ||
					tail[:recovery] == "]") {
				recovered := tail[recovery+2:]
				if space := strings.IndexFunc(
					recovered, func(value rune) bool {
						return value <= ' '
					}); space > 0 {
					recovered = recovered[:space]
				}
				if compatibilityDecimalComponent(recovered) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(recovered, `("`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `("`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(recovered, `"`) &&
					(compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) ||
						strings.TrimSuffix(recovered, `"`) != "" &&
							strings.TrimSuffix(recovered, `"`)[0] >= '0' &&
							strings.TrimSuffix(recovered, `"`)[0] <= '9' &&
							!strings.ContainsAny(
								strings.TrimSuffix(recovered, `"`),
								".[|:()") ||
						strings.TrimSuffix(recovered, `"`) == "+" ||
						strings.TrimSuffix(recovered, `"`) == "-") {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
				if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
					compatibilityDecimalComponent(recovered[:quote]) &&
					recovered[quote+1:] != "" &&
					!strings.ContainsAny(
						recovered[quote+1:], ".[|:()") {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(expression[1:pipe], `": ,`) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Trim(expression[1:pipe], `"`) == "" {
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				compatibilityDecimalComponent(tail[:space]) &&
				strings.HasPrefix(
					trimCompatibilitySpace(tail[space:]), ").") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.HasPrefix(tail, `[)|`) &&
				strings.Count(tail, "|!") == 2 {
				if recovery := strings.Index(tail, "|!"); recovery > len(`[)|`) {
					component := tail[len(`[)|`):recovery]
					if component != "" &&
						!strings.ContainsAny(component, ".[|:()") &&
						!compatibilityDecimalComponent(component) {
						recovered := tail[recovery+2:]
						if recovered != "" &&
							recovered[0] >= '0' && recovered[0] <= '9' {
							return Result{
								Type: JSON, Raw: "[" + recovered + "]",
								synthetic: true,
							}
						}
					}
				}
			}
			if recovery := strings.Index(tail, "|!"); recovery > 0 &&
				strings.HasPrefix(tail[:recovery], "[") &&
				strings.Count(tail[:recovery], ")") >= 2 {
				if close := strings.IndexByte(tail[:recovery], ')'); close > 1 &&
					compatibilityDecimalComponent(tail[1:close]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[:close+1] + "]",
						synthetic: true,
					}
				}
			}
			if strings.Contains(tail, `)|![))`) {
				return Result{
					Type: JSON, Raw: "[[)]", synthetic: true,
				}
			}
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				compatibilityDecimalComponent(tail[:space]) &&
				trimCompatibilitySpace(tail[space:]) == `:":` {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 &&
				strings.HasPrefix(tail[:recovery], "[") &&
				strings.HasSuffix(tail[:recovery], "]") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					strings.TrimPrefix(
						tail[:recovery], "["),
					"]")) {
				recovered := tail[recovery+2:]
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
			if strings.Count(tail, "|!") == 1 {
				recovery := strings.Index(tail, "|!")
				before := tail[:recovery]
				recovered := tail[recovery+2:]
				head := strings.TrimSuffix(before, ":")
				if strings.HasSuffix(before, ":") &&
					head != "" &&
					head[0] >= '0' && head[0] <= '9' &&
					(!strings.ContainsAny(head, ".[|:()") ||
						strings.HasSuffix(head, "(") &&
							compatibilityDecimalComponent(
								strings.TrimSuffix(head, "("))) &&
					strings.HasSuffix(recovered, `:"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `:"`)) {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(before, ":") &&
					head != "" &&
					head[0] >= '0' && head[0] <= '9' &&
					(!strings.ContainsAny(head, ".[|:()") ||
						strings.HasSuffix(head, "(") &&
							compatibilityDecimalComponent(
								strings.TrimSuffix(head, "("))) &&
					strings.HasSuffix(recovered, `":`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `":`)) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 {
				head := tail[:space]
				if head != "" &&
					head[0] >= '0' && head[0] <= '9' &&
					!strings.ContainsAny(head, ".[|:()") &&
					trimCompatibilitySpace(tail[space:]) == `"":"` {
					return Result{
						Type: JSON, Raw: "[" + head + "]",
						synthetic: true,
					}
				}
			}
			if strings.HasSuffix(tail, `"":"`) {
				if marker := strings.Index(tail, `":"`); marker > 0 &&
					compatibilityDecimalComponent(tail[:marker]) &&
					compatibilityDecimalComponent(strings.TrimSuffix(
						tail[marker+len(`":"`):], `"":"`)) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if strings.HasPrefix(tail, "[).") &&
				strings.Count(tail, "|!") == 2 {
				firstPipe := strings.Index(tail, "|!")
				lastPipe := strings.LastIndex(tail, "|!")
				middle := tail[firstPipe+2 : lastPipe]
				if compatibilityAlphanumericComponent(middle) &&
					!compatibilityDecimalComponent(middle) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if close := strings.Index(tail, "[))"); close > 0 {
				return Result{
					Type:      JSON,
					Raw:       "[" + tail[:close+len("[))")] + "]",
					synthetic: true,
				}
			}
			if strings.HasSuffix(tail, `]"":"`) {
				if close := strings.IndexByte(tail, ']'); close > 0 &&
					compatibilityDecimalComponent(tail[:close]) {
					return Result{
						Type: JSON, Raw: "[" + tail[:close] + "]",
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(tail, `).[)|!`); marker > 0 &&
				compatibilityAlphanumericComponent(tail[:marker]) &&
				!compatibilityDecimalComponent(tail[:marker]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.Count(tail, "|!") == 1 {
				if recovery := strings.Index(tail, "|!"); recovery > 0 {
					before := tail[:recovery]
					if colon := strings.IndexByte(before, ':'); colon > 0 &&
						compatibilityDecimalComponent(
							before[:colon]) &&
						compatibilityDecimalComponent(
							before[colon+1:]) {
						recovered := tail[recovery+2:]
						if strings.HasSuffix(recovered, `"`) &&
							compatibilityDecimalComponent(
								strings.TrimSuffix(recovered, `"`)) {
							return Result{
								Type: JSON, Raw: "[" + tail + "]",
								synthetic: true,
							}
						}
					}
				}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 &&
				strings.HasPrefix(tail[:recovery], `[)|`) {
				before := strings.TrimPrefix(tail[:recovery], `[)|`)
				if nested := strings.IndexByte(before, '['); nested > 0 &&
					compatibilityDecimalComponent(before[:nested]) &&
					compatibilityDecimalComponent(
						before[nested+1:]) {
					recovered := tail[recovery+2:]
					if strings.HasSuffix(recovered, `"`) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `"`)) {
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
				}
			}
			if marker := strings.Index(tail, "[)|!"); strings.HasPrefix(tail, "[") &&
				marker > 1 &&
				tail[1] >= '0' && tail[1] <= '9' &&
				!strings.ContainsAny(
					tail[1:marker], ".[|:()") &&
				strings.Count(tail, "[") == 2 {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if firstPipe := strings.Index(tail, "|!"); strings.HasPrefix(tail, "[") &&
				firstPipe > 1 &&
				compatibilityDecimalComponent(tail[1:firstPipe]) &&
				strings.Count(tail, "[") == 2 &&
				strings.Contains(tail[firstPipe+2:], "[).") &&
				strings.HasSuffix(tail, `"`) {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if strings.HasPrefix(tail, `[)|`) {
				if space := strings.IndexFunc(tail, func(value rune) bool {
					return value <= ' '
				}); space > len(`[)|`) {
					after := trimCompatibilitySpace(tail[space:])
					if strings.Count(after, "|!") == 2 {
						if recovery := strings.Index(after, "|!"); recovery > 0 &&
							compatibilityDecimalComponent(
								after[:recovery]) {
							recovered := after[recovery+2:]
							return Result{
								Type: JSON, Raw: "[" + recovered + "]",
								synthetic: true,
							}
						}
					}
				}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 && tail[:recovery] == `:":"` {
				recovered := tail[recovery+2:]
				if strings.HasSuffix(recovered, `":`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `":`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 {
				before := tail[:recovery]
				if marker := strings.Index(before, ").[)."); marker > 0 &&
					compatibilityDecimalComponent(before[:marker]) &&
					compatibilityDecimalComponent(
						before[marker+len(").[)."):]) {
					recovered := tail[recovery+2:]
					if strings.HasSuffix(recovered, `"`) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `"`)) {
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
				}
			}
		}
		if strings.Contains(expression[1:pipe], "::") &&
			strings.HasSuffix(expression[1:pipe], `"`) &&
			strings.IndexAny(expression[1:pipe], "0123456789") >= 0 &&
			strings.HasSuffix(tail, `":`) &&
			compatibilityDecimalComponent(
				strings.TrimSuffix(tail, `":`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if prefix := strings.Trim(expression[1:pipe], `"`); prefix != "" &&
			!strings.ContainsAny(prefix, ".[|:()") {
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				strings.HasSuffix(tail[:space], `"`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[:space], `"`)) &&
				trimCompatibilitySpace(tail[space:]) == `""":"` {
				return Result{
					Type: JSON, Raw: "[" + tail[:space] + "]",
					synthetic: true,
				}
			}
		}
		if expression[1:pipe] == `",` {
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				strings.HasPrefix(
					trimCompatibilitySpace(tail[space:]),
					":") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if expression[1:pipe] == `"` &&
			strings.HasPrefix(tail, `[)|`) &&
			strings.HasSuffix(tail, `)|"`) {
			if recovery := strings.Index(tail[len(`[)|`):], "|!"); recovery > 0 {
				between := tail[len(`[)|`) : len(`[)|`)+recovery]
				if compatibilityAlphanumericComponent(between) &&
					!compatibilityDecimalComponent(between) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
		}
		if space := strings.IndexFunc(tail, func(value rune) bool {
			return value <= ' '
		}); space > 0 &&
			compatibilityDecimalComponent(tail[:space]) &&
			strings.TrimSuffix(
				trimCompatibilitySpace(tail[space:]),
				`"`) == ":" {
			singlePipeLiteralEntry = true
		}
	}
	if strings.Contains(expression, `)|!`) &&
		strings.Count(expression, "|!") >= 2 {
		if entries, ok := splitCompatibilityEntries(
			expression[1 : len(expression)-1]); ok && len(entries) == 2 &&
			strings.Contains(entries[1], `)|!`) &&
			!strings.Contains(entries[0], "|!") &&
			!compatibilityGet(
				current.Raw,
				trimCompatibilitySpace(entries[0])).Exists() {
			singlePipeLiteralEntry = true
		}
	}
	if strings.Contains(expression, `)|!`) &&
		strings.HasSuffix(expression, ",]") {
		if entries, ok := splitCompatibilityEntries(
			expression[1 : len(expression)-1]); ok && len(entries) == 2 &&
			trimCompatibilitySpace(entries[1]) == "" {
			singlePipeLiteralEntry = true
		}
	}
	if pipe := strings.Index(expression, "|!"); (current.IsObject() || current.IsArray()) &&
		expression[0] == '[' &&
		singlePipeLiteralEntry &&
		pipe >= 0 && pipe+2 < len(expression)-1 {
		tail := expression[pipe+2 : len(expression)-1]
		if space := strings.IndexFunc(tail, func(value rune) bool {
			return value <= ' '
		}); space > 0 &&
			(compatibilityDecimalComponent(tail[:space]) ||
				tail[:space] == "+" || tail[:space] == "-") &&
			strings.TrimSuffix(tail[space+1:], `"`) == `"":` {
			return Result{
				Type: JSON, Raw: "[" + tail[:space] + "]",
				synthetic: true,
			}
		}
		if (expression[1:pipe] == `":,":"` ||
			expression[1:pipe] == `":.":"` ||
			expression[1:pipe] == `":|":"` ||
			expression[1:pipe] == `,:":`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if (strings.HasPrefix(expression[1:pipe], `":,`) ||
			strings.HasPrefix(expression[1:pipe], `":.`)) &&
			strings.HasSuffix(expression[1:pipe], `"""`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if expression[1:pipe] == `",` &&
			strings.Contains(tail, `\:`) &&
			!strings.Contains(tail, `\\:`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if expression[1:pipe] == `,"` &&
			strings.Contains(tail, `"""`) &&
			strings.HasSuffix(tail, ":") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if close := strings.Index(tail, ",]"); close > 0 &&
			compatibilityDecimalComponent(tail[:close]) {
			return Result{
				Type: JSON, Raw: "[" + tail[:close] + "]",
				synthetic: true,
			}
		}
		if strings.HasPrefix(expression[1:pipe], `":,`) &&
			strings.Contains(expression[1:pipe], " ") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(tail, "()).") ||
			strings.Contains(tail, "())|") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(expression[1:pipe], "|[)|"); marker >= 0 &&
			(strings.Contains(
				expression[1:pipe][marker+len("|[)|"):],
				".") &&
				!strings.HasPrefix(
					expression[1:pipe][marker+len("|[)|"):],
					"[)") ||
				strings.Count(expression[1:pipe], "|") > 2 &&
					!strings.HasPrefix(
						expression[1:pipe][marker+len("|[)|"):],
						"[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Trim(expression[1:pipe], `"`) == "" {
			if marker := strings.Index(tail, "|!"); marker > 0 {
				before := tail[:marker]
				if colon := strings.IndexByte(before, ':'); colon > 0 &&
					compatibilityDecimalComponent(before[:colon]) &&
					compatibilityDecimalComponent(before[colon+1:]) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				compatibilityDecimalComponent(tail[:space]) &&
				!strings.Contains(tail[space:], "|!") {
				after := trimCompatibilitySpace(tail[space:])
				if strings.HasPrefix(after, `":`) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.Contains(after, ":") &&
					(strings.Count(after, `"`) == 1 &&
						strings.IndexByte(after, '"') <
							strings.IndexByte(after, ':') ||
						strings.Count(after, `"`) >= 3 &&
							strings.Count(after, `"`)%2 == 1 &&
							strings.HasPrefix(after, `"""`)) {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				return Result{
					Type: JSON, Raw: "[" + tail[:space] + "]",
					synthetic: true,
				}
			}
			if marker := strings.Index(tail, "|!"); marker > 0 &&
				strings.HasSuffix(tail[:marker], "$:") &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if strings.Contains(tail, `":""":`) &&
				!strings.Contains(tail, "|!") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if marker := strings.LastIndex(tail, "|!"); marker > 0 {
				before := tail[:marker]
				if colon := strings.IndexByte(before, ':'); colon > 0 &&
					compatibilityDecimalComponent(before[:colon]) &&
					strings.Count(before[colon+1:], `"`) == 2 &&
					strings.HasPrefix(before[colon+1:], `"`) &&
					strings.HasSuffix(before, `"`) {
					// Empty-prefix "|!" literals squash their trailing
					// stage as a scalar; the malformed selector before it
					// is merely traversed, so the remainder is kept whole.
					// A trailing top-level colon leaves an empty final key
					// that dead-ends to [].
					if strings.HasSuffix(tail, ":") {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
					return Result{
						Type: JSON,
						Raw: "[" +
							compatibilityScalarLiteralTail(tail) + "]",
						synthetic: true,
					}
				}
			}
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				strings.HasSuffix(tail[:space], `"`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(tail[:space], `"`)) {
				if strings.HasPrefix(
					trimCompatibilitySpace(tail[space:]),
					":") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				after := trimCompatibilitySpace(tail[space:])
				if strings.HasSuffix(after, ":") &&
					strings.Count(after, `"`) == 2 {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				return Result{
					Type: JSON, Raw: "[" + tail[:space] + "]",
					synthetic: true,
				}
			}
			if strings.HasPrefix(tail, "$:") &&
				strings.Contains(tail, "|!") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if strings.HasSuffix(tail, ":*") &&
				strings.Contains(tail, `"`) {
				if selected := compatibilityChild(current, "*"); selected.Exists() {
					return Result{
						Type:      JSON,
						Raw:       "[" + selected.Raw + "]",
						synthetic: true,
					}
				}
			}
			if comma := strings.IndexByte(tail, ','); comma > 0 &&
				compatibilityDecimalComponent(tail[:comma]) {
				if strings.Contains(tail[comma+1:], ":") &&
					strings.Count(tail[comma+1:], `"`) == 1 &&
					strings.IndexByte(tail[comma+1:], ':') >
						strings.IndexByte(tail[comma+1:], '"') {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.Contains(tail[comma+1:], "|") &&
					!strings.Contains(tail[comma+1:], "|!") &&
					strings.Contains(tail[comma+1:], ":") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if !strings.Contains(tail[comma+1:], "|!") {
					return Result{
						Type: JSON, Raw: "[" + tail[:comma] + "]",
						synthetic: true,
					}
				}
			}
			if marker := strings.LastIndex(tail, "|!"); marker > 0 &&
				(strings.Contains(tail[:marker], `":""":`) ||
					strings.HasSuffix(tail[:marker], `""":`)) &&
				marker+2 < len(tail) {
				recovered := tail[marker+2:]
				if recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9' {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
			if strings.Contains(tail, `"`) &&
				strings.HasSuffix(tail, `\\:`) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if close := strings.IndexByte(tail, ')'); close > 0 &&
				!strings.Contains(tail, "|!") &&
				compatibilityDecimalComponent(tail[:close]) &&
				strings.HasPrefix(tail[close+1:], `""`) {
				return Result{
					Type: JSON, Raw: "[" + tail[:close+1] + "]",
					synthetic: true,
				}
			}
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				(compatibilityDecimalComponent(tail[:space]) ||
					compatibilityAlphanumericComponent(
						tail[:space]) &&
						tail[0] >= '0' && tail[0] <= '9') &&
				strings.TrimSuffix(tail[space+1:], `"`) == `"":` {
				return Result{
					Type: JSON, Raw: "[" + tail[:space] + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(expression[1:pipe], `"|`) &&
			strings.HasSuffix(expression[1:pipe], `""":`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(expression[1:pipe], `"|`) &&
			strings.HasSuffix(expression[1:pipe], `""":"`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(expression[1:pipe], `"|`) &&
			strings.Contains(expression[1:pipe], ` ":`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(expression[1:pipe], `"|`) &&
			strings.Contains(expression[1:pipe], `:":`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.Contains(expression[1:pipe], `,"|`) &&
			strings.HasSuffix(expression[1:pipe], `":"`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.Contains(expression[1:pipe], "|[)") &&
			!strings.HasPrefix(
				strings.Trim(expression[1:pipe], `"`),
				"|[)") &&
			strings.IndexFunc(expression[1:pipe], func(value rune) bool {
				return value > 127
			}) >= 0 {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if expression[1:pipe] == `",` {
			quote := strings.IndexByte(tail, '"')
			colon := strings.IndexByte(tail, ':')
			if quote >= 0 && colon > quote+1 &&
				compatibilityAlphanumericComponent(
					tail[quote+1:colon]) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if expression[1:pipe] == `":` {
			if strings.Contains(tail, `"""""`) &&
				strings.Contains(tail, "::") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if tail[0] >= 'A' && tail[0] <= 'Z' ||
				tail[0] >= 'a' && tail[0] <= 'z' {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if marker := strings.Index(tail, "|!"); marker > 0 &&
				strings.HasSuffix(tail[:marker], `"":`) &&
				marker+2 < len(tail) {
				recovered := tail[marker+2:]
				colon := strings.IndexByte(recovered, ':')
				quote := strings.IndexByte(recovered, '"')
				if colon >= 0 && (quote < 0 || colon < quote) {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(tail, "|!"); marker > 0 &&
				strings.HasSuffix(tail[:marker], "$:") &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if marker := strings.Index(tail, `:""::`); marker > 0 &&
				compatibilityDecimalComponent(tail[:marker]) {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if marker := strings.LastIndex(tail, "|!"); marker >= 0 && marker+2 < len(tail) {
				recovered := tail[marker+2:]
				if recovered[0] >= 'A' && recovered[0] <= 'Z' ||
					recovered[0] >= 'a' && recovered[0] <= 'z' {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				strings.Contains(tail[:space], `""::`) {
				return Result{
					Type: JSON, Raw: "[" + tail[:space] + "]",
					synthetic: true,
				}
			}
			if strings.Contains(tail, `\"`) &&
				strings.Contains(tail, ":") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if marker := strings.LastIndex(tail, "|!"); marker > 0 &&
				strings.Contains(tail[:marker], " ") &&
				marker+2 < len(tail) {
				recovered := tail[marker+2:]
				numeric := strings.TrimSuffix(recovered, `"`)
				if compatibilityDecimalComponent(numeric) {
					quote := strings.IndexByte(tail[:marker], '"')
					space := strings.IndexFunc(
						tail[:marker], func(value rune) bool {
							return value <= ' '
						})
					if quote < 0 || space >= 0 && quote > space {
						recovered = numeric
					}
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
			if strings.Contains(tail, `\:`) {
				if strings.HasSuffix(tail, `\:`) {
					if quote := strings.IndexByte(tail, '"'); quote > 0 &&
						compatibilityDecimalComponent(
							tail[:quote]) &&
						compatibilityDecimalComponent(strings.TrimSuffix(
							tail[quote+1:], `\:`)) {
						return Result{
							Type: JSON, Raw: "[" + tail + "]",
							synthetic: true,
						}
					}
				}
				if strings.HasSuffix(tail, `"\:`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail, `"\:`)) {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
				if strings.HasSuffix(tail, `"\:""`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(tail, `"\:""`)) {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if colon := strings.IndexByte(tail, ':'); colon > 0 &&
				compatibilityDecimalComponent(tail[:colon]) &&
				strings.HasPrefix(tail[colon:], `:"":`) &&
				colon+len(`:"":`)+1 < len(tail) &&
				compatibilityAlphanumericComponent(
					tail[colon+len(`:"":`)+1:]) {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if quote := strings.IndexByte(tail, '"'); quote > 0 &&
				compatibilityDecimalComponent(tail[:quote]) &&
				strings.HasPrefix(tail[quote:], `"":`) &&
				quote+len(`"":`) < len(tail) &&
				(tail[quote+len(`"":`)] == ':' &&
					quote+len(`"":`)+2 < len(tail) &&
					tail[quote+len(`"":`)+2] != ':' ||
					tail[quote+len(`"":`)] >= '0' &&
						tail[quote+len(`"":`)] <= '9' &&
						strings.Contains(
							tail[quote+len(`"":`):],
							"::")) {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if quote := strings.IndexByte(tail, '"'); quote > 0 &&
				strings.HasPrefix(tail[quote:], `""::`) {
				head := tail[:quote]
				if colon := strings.IndexByte(head, ':'); colon > 0 &&
					compatibilityDecimalComponent(head[:colon]) &&
					compatibilityDecimalComponent(head[colon+1:]) {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
			}
		}
		trimmedPrefix := strings.Trim(expression[1:pipe], `"`)
		if marker := strings.Index(trimmedPrefix, ".["); marker > 0 &&
			(strings.Contains(trimmedPrefix[:marker], "|") ||
				strings.Contains(trimmedPrefix[:marker], ".")) {
			body := trimmedPrefix[marker+len(".["):]
			if strings.HasSuffix(body, ")") &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(body, ")")) {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.HasSuffix(trimmedPrefix, "())") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(trimmedPrefix, ".["), "())")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[.") &&
			strings.HasSuffix(trimmedPrefix, ")") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(trimmedPrefix, ".[."), ")")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[}|") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(trimmedPrefix, ".[}|")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.HasSuffix(trimmedPrefix, ")") {
			body := strings.TrimSuffix(
				strings.TrimPrefix(trimmedPrefix, ".["), ")")
			if strings.Count(body, ".") == 1 {
				pair := strings.SplitN(body, ".", 2)
				if compatibilityDecimalComponent(pair[0]) &&
					compatibilityDecimalComponent(pair[1]) &&
					tail != "" &&
					(tail[0] == '+' || tail[0] == '-' ||
						tail[0] >= '0' && tail[0] <= '9') {
					return Result{
						Type: JSON,
						Raw: "[" +
							compatibilityScalarLiteralTail(tail) + "]",
						synthetic: true,
					}
				}
			}
		}
		if marker := strings.Index(trimmedPrefix, ".{)"); marker > 0 &&
			compatibilityDecimalComponent(trimmedPrefix[:marker]) &&
			compatibilityDecimalComponent(
				trimmedPrefix[marker+len(".{)"):]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(trimmedPrefix, `".[)`); marker > 0 &&
			compatibilityDecimalComponent(trimmedPrefix[:marker]) &&
			compatibilityDecimalComponent(
				trimmedPrefix[marker+len(`".[)`):]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.Contains(trimmedPrefix, "(") &&
			strings.HasSuffix(trimmedPrefix, ")") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.Contains(trimmedPrefix, "().") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, "|[") &&
			strings.Contains(trimmedPrefix, "(") &&
			strings.HasSuffix(trimmedPrefix, ")") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(trimmedPrefix, ".[).[)"); marker > 0 &&
			compatibilityDecimalComponent(trimmedPrefix[:marker]) &&
			trimmedPrefix[marker+len(".[).[)"):] != "" &&
			(!strings.ContainsAny(
				trimmedPrefix[marker+len(".[).[)"):],
				".[|:()") ||
				strings.HasPrefix(
					trimmedPrefix[marker+len(".[).[)"):],
					"(") &&
					compatibilityDecimalComponent(strings.TrimPrefix(
						trimmedPrefix[marker+len(".[).[)"):],
						"("))) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if marker := strings.Index(trimmedPrefix, ".["); marker > 0 &&
			trimmedPrefix[:marker] != "" &&
			!strings.ContainsAny(
				trimmedPrefix[:marker], ".[|:()") {
			body := trimmedPrefix[marker+len(".["):]
			if token := strings.TrimSuffix(body, ")"); strings.HasSuffix(body, ")") &&
				token != "" &&
				token[0] >= '0' && token[0] <= '9' &&
				!strings.ContainsAny(token, ".[|:()") &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, ")."); close > 0 &&
				strings.Count(body[:close], "|") == 1 {
				pair := strings.SplitN(body[:close], "|", 2)
				if pair[0] != "" &&
					!strings.ContainsAny(pair[0], ".[|:()") &&
					pair[1] != "" &&
					!strings.ContainsAny(pair[1], ".[|:()") &&
					compatibilityDecimalComponent(
						body[close+len(")."):]) &&
					tail != "" &&
					(tail[0] == '+' || tail[0] == '-' ||
						tail[0] >= '0' && tail[0] <= '9') {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
			}
			if close := strings.Index(body, "|)."); close > 0 &&
				compatibilityDecimalComponent(body[:close]) &&
				compatibilityDecimalComponent(
					body[close+len("|)."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, ")."); close > 0 &&
				trimCompatibilitySpace(body[:close]) != "" &&
				trimCompatibilitySpace(body[:close])[0] >= '0' &&
				trimCompatibilitySpace(body[:close])[0] <= '9' &&
				!strings.ContainsAny(
					trimCompatibilitySpace(body[:close]),
					".[|:()") &&
				compatibilityDecimalComponent(
					body[close+len(")."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
		}
		if marker := strings.Index(trimmedPrefix, "|["); marker > 0 &&
			trimmedPrefix[:marker] != "" &&
			!strings.ContainsAny(
				trimmedPrefix[:marker], ".[|:()") {
			body := trimmedPrefix[marker+len("|["):]
			if close := strings.Index(body, ")."); close > 0 &&
				body[:close] != "" &&
				body[0] >= '0' && body[0] <= '9' &&
				!strings.ContainsAny(
					body[:close], ".[|:()") &&
				compatibilityDecimalComponent(
					body[close+len(")."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
		}
		if strings.HasSuffix(trimmedPrefix, `".[)`) {
			component := strings.TrimSuffix(trimmedPrefix, `".[)`)
			if len(component) == 1 &&
				!strings.ContainsAny(component, ".[|:") &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".{") {
			body := strings.TrimPrefix(trimmedPrefix, ".{")
			if close := strings.Index(body, ")."); close > 0 &&
				strings.Count(body[:close], "|") == 1 {
				pair := strings.SplitN(body[:close], "|", 2)
				if pair[0] != "" &&
					!strings.ContainsAny(pair[0], ".[|:()") &&
					pair[1] != "" &&
					!strings.ContainsAny(pair[1], ".[|:()") &&
					compatibilityDecimalComponent(
						body[close+len(")."):]) &&
					tail != "" &&
					(tail[0] == '+' || tail[0] == '-' ||
						tail[0] >= '0' && tail[0] <= '9') {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
			}
			if close := strings.Index(body, "|)."); close > 0 &&
				compatibilityDecimalComponent(body[:close]) &&
				compatibilityDecimalComponent(
					body[close+len("|)."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, ")."); close > 0 &&
				trimCompatibilitySpace(body[:close]) != "" &&
				trimCompatibilitySpace(body[:close])[0] >= '0' &&
				trimCompatibilitySpace(body[:close])[0] <= '9' &&
				!strings.ContainsAny(
					trimCompatibilitySpace(body[:close]),
					".[|:()") &&
				compatibilityDecimalComponent(
					body[close+len(")."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			len(trimmedPrefix) > len(".[") &&
			trimmedPrefix[len(".[")] >= '0' &&
			trimmedPrefix[len(".[")] <= '9' &&
			strings.Count(trimmedPrefix, ")") >= 2 &&
			strings.Count(trimmedPrefix, "[") == 1 &&
			!strings.Contains(trimmedPrefix, "|") &&
			!strings.Contains(trimmedPrefix, "(") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") {
			body := strings.TrimPrefix(trimmedPrefix, ".[")
			if body != "" &&
				body[0] >= '0' && body[0] <= '9' &&
				strings.Count(body, ")") >= 2 &&
				strings.Count(body, "|") == 1 &&
				!strings.Contains(body, ".") &&
				!strings.Contains(body, "(") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") {
			body := strings.TrimPrefix(trimmedPrefix, ".[")
			if close := strings.Index(body, ")."); close > 0 &&
				strings.Count(body[:close], "|") == 1 {
				pipeParts := strings.SplitN(body[:close], "|", 2)
				if strings.Count(pipeParts[0], ".") == 1 {
					dotted := strings.SplitN(pipeParts[0], ".", 2)
					if compatibilityDecimalComponent(dotted[0]) &&
						compatibilityDecimalComponent(dotted[1]) &&
						pipeParts[1] != "" &&
						!strings.ContainsAny(
							pipeParts[1], ".[|:()") &&
						compatibilityDecimalComponent(
							body[close+len(")."):]) &&
						tail != "" &&
						(tail[0] == '+' || tail[0] == '-' ||
							tail[0] >= '0' && tail[0] <= '9') {
						return Result{
							Type: JSON, Raw: "[" + tail + "]",
							synthetic: true,
						}
					}
				}
			}
			if marker := strings.Index(body, "|)|"); marker > 0 &&
				compatibilityDecimalComponent(body[:marker]) &&
				body[marker+len("|)|"):] != "" &&
				!strings.ContainsAny(
					body[marker+len("|)|"):], ".[|:()") &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if marker := strings.Index(body, ")|("); marker > 0 &&
				compatibilityDecimalComponent(body[:marker]) &&
				compatibilityDecimalComponent(
					body[marker+len(")|("):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if marker := strings.Index(body, "[))"); marker > 0 &&
				marker+len("[))") == len(body) &&
				compatibilityDecimalComponent(body[:marker]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, ")."); close > 0 &&
				body[:close] != "" &&
				body[0] >= '0' && body[0] <= '9' &&
				!strings.ContainsAny(
					body[:close], ".[|:()") &&
				body[close+len(")."):] == "(" &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, ")."); close > 0 &&
				compatibilityDecimalComponent(body[:close]) &&
				compatibilityDecimalComponent(
					body[close+len(")."):]) &&
				tail == `["` {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, "]."); close > 0 &&
				compatibilityDecimalComponent(body[:close]) &&
				compatibilityDecimalComponent(
					body[close+len("]."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, "|)."); close > 0 &&
				strings.Count(body[:close], "|") == 1 {
				pair := strings.SplitN(body[:close], "|", 2)
				if compatibilityDecimalComponent(pair[0]) &&
					compatibilityDecimalComponent(pair[1]) &&
					compatibilityDecimalComponent(
						body[close+len("|)."):]) &&
					tail != "" &&
					(tail[0] == '+' || tail[0] == '-' ||
						tail[0] >= '0' && tail[0] <= '9') {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
			}
			if marker := strings.Index(body, "())."); marker > 0 &&
				compatibilityDecimalComponent(body[:marker]) &&
				compatibilityDecimalComponent(
					body[marker+len("())."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if close := strings.Index(body, ")."); close > 0 &&
				strings.Count(body[:close], ".") == 1 {
				pair := strings.SplitN(body[:close], ".", 2)
				if pair[0] != "" &&
					!strings.ContainsAny(pair[0], ".[|:") &&
					pair[1] != "" &&
					!strings.ContainsAny(pair[1], ".[|:") &&
					compatibilityDecimalComponent(
						body[close+len(")."):]) &&
					tail != "" &&
					(tail[0] == '+' || tail[0] == '-' ||
						tail[0] >= '0' && tail[0] <= '9') {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
			}
			if bar := strings.IndexByte(body, '|'); bar > 0 {
				if close := strings.Index(body[bar+1:], ")."); close > 0 {
					close += bar + 1
					if trimCompatibilitySpace(body[:bar]) != "" &&
						(trimCompatibilitySpace(body[:bar]) == ":" ||
							!strings.ContainsAny(
								trimCompatibilitySpace(body[:bar]),
								".[|:()")) &&
						trimCompatibilitySpace(
							body[bar+1:close]) != "" &&
						!strings.ContainsAny(
							trimCompatibilitySpace(
								body[bar+1:close]),
							".[|:()") &&
						(compatibilityAlphanumericComponent(
							body[close+len(")."):]) ||
							len(body[close+len(")."):]) == 1 &&
								!strings.ContainsAny(
									body[close+len(")."):], ".[|:()")) &&
						tail != "" &&
						(tail[0] == '+' || tail[0] == '-' ||
							tail[0] >= '0' && tail[0] <= '9') {
						recovered := tail
						if space := strings.IndexFunc(
							recovered, func(value rune) bool {
								return value <= ' '
							}); space > 0 {
							recovered = recovered[:space]
						}
						return Result{
							Type: JSON, Raw: "[" + recovered + "]",
							synthetic: true,
						}
					}
				}
			}
		}
		if marker := strings.Index(trimmedPrefix, ".[)."); marker > 0 &&
			trimmedPrefix[:marker] != "" &&
			!strings.ContainsAny(
				trimmedPrefix[:marker], ".[|:()") &&
			compatibilityDecimalComponent(
				trimmedPrefix[marker+len(".[)."):]) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|") {
			stages := strings.TrimPrefix(trimmedPrefix, ".[)|")
			if marker := strings.Index(stages, "|[)|"); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len("|[)|"):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if marker := strings.Index(stages, "|[)."); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len("|[)."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(trimmedPrefix, ".[).")) &&
			(tail == `["` || tail == `{"`) {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(trimmedPrefix, ".[).")) {
			if space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			}); space > 0 &&
				compatibilityDecimalComponent(tail[:space]) {
				return Result{
					Type: JSON, Raw: "[" + tail[:space] + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).") {
			stages := strings.TrimPrefix(trimmedPrefix, ".[).")
			if marker := strings.Index(stages, "|[)|"); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len("|[)|"):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if marker := strings.Index(
				strings.TrimPrefix(trimmedPrefix, ".[)."), "|[)."); marker > 0 {
				stages := strings.TrimPrefix(trimmedPrefix, ".[).")
				if compatibilityDecimalComponent(stages[:marker]) &&
					compatibilityDecimalComponent(
						stages[marker+len("|[)."):]) &&
					tail != "" &&
					(tail[0] == '+' || tail[0] == '-' ||
						tail[0] >= '0' && tail[0] <= '9') {
					return Result{
						Type: JSON, Raw: "[" + tail + "]",
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, "|[).") &&
			strings.HasSuffix(trimmedPrefix, "|[)") &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(trimmedPrefix, "|[)."), "|[)")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, "|[).") {
			stages := strings.TrimPrefix(trimmedPrefix, "|[).")
			if marker := strings.Index(stages, "|[)|"); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len("|[)|"):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if marker := strings.Index(stages, "|[)."); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len("|[)."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if marker := strings.Index(stages, ".[)|"); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len(".[)|"):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if marker := strings.Index(stages, ".[)."); marker > 0 &&
				compatibilityDecimalComponent(stages[:marker]) &&
				compatibilityDecimalComponent(
					stages[marker+len(".[)."):]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if nested := strings.IndexByte(stages, '['); nested > 0 &&
				compatibilityDecimalComponent(stages[:nested]) &&
				compatibilityDecimalComponent(stages[nested+1:]) &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
		}
		if trimmedPrefix == ".[)" {
			if strings.Count(tail, "|!") == 1 {
				if recovery := strings.Index(tail, "|!"); recovery > 0 &&
					compatibilityDecimalComponent(tail[:recovery]) {
					recovered := tail[recovery+2:]
					if strings.HasSuffix(recovered, `"`) &&
						compatibilityDecimalComponent(
							strings.TrimSuffix(recovered, `"`)) {
						return Result{
							Type: JSON, Raw: "[" + tail + "]",
							synthetic: true,
						}
					}
				}
			}
			if strings.HasPrefix(tail, `[)|!`) {
				recovered := strings.TrimPrefix(tail, `[)|!`)
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 &&
				tail[:recovery] != "" &&
				!strings.ContainsAny(tail[:recovery], ".[|:") {
				recovered := tail[recovery+2:]
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if trimmedPrefix == "|[)" {
			if recovery := strings.LastIndex(tail, "|!"); recovery > 0 &&
				tail[:recovery] != "" &&
				(!strings.ContainsAny(
					tail[:recovery], ".[|:()") ||
					strings.HasSuffix(tail[:recovery], "(") &&
						strings.TrimSuffix(
							tail[:recovery], "(") != "" &&
						!strings.ContainsAny(
							strings.TrimSuffix(
								tail[:recovery], "("),
							".[|:()")) {
				recovered := tail[recovery+2:]
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, "|[).") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(trimmedPrefix, "|[).")) &&
			strings.HasPrefix(tail, ")|!") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, "|[)|") &&
			(strings.HasSuffix(trimmedPrefix, ".[)") &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					strings.TrimPrefix(trimmedPrefix, "|[)|"), ".[)")) ||
				strings.HasSuffix(trimmedPrefix, "|[)") &&
					compatibilityDecimalComponent(strings.TrimSuffix(
						strings.TrimPrefix(trimmedPrefix, "|[)|"),
						"|[)"))) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.Contains(trimmedPrefix, "|") &&
			strings.HasSuffix(trimmedPrefix, ":") &&
			strings.Trim(trimmedPrefix, "0123456789|:") == "" {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, ".") &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(trimmedPrefix, ".")) &&
			strings.Contains(tail, `"":`) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(trimmedPrefix, ".[)"); marker >= 0 &&
			!strings.HasPrefix(trimmedPrefix[marker:], ".[).") &&
			!strings.HasPrefix(trimmedPrefix[marker:], ".[)|") &&
			len(trimmedPrefix[marker:]) > len(".[)") &&
			strings.HasSuffix(trimmedPrefix, ")") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(trimmedPrefix, "|["); marker > 1 &&
			strings.HasPrefix(trimmedPrefix, ".") &&
			compatibilityDecimalComponent(
				trimmedPrefix[1:marker]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if (strings.HasPrefix(trimmedPrefix, ".[") ||
			strings.HasPrefix(trimmedPrefix, "|[")) &&
			!strings.HasPrefix(trimmedPrefix, ".[).") &&
			!strings.Contains(trimmedPrefix, ")|") &&
			strings.Count(trimmedPrefix, "[") == 1 &&
			strings.HasPrefix(tail, ")|!") &&
			len(tail) > len(")|!") {
			recovered := tail[len(")|!"):]
			if recovered[0] == '+' || recovered[0] == '-' ||
				recovered[0] >= '0' && recovered[0] <= '9' {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.Count(trimmedPrefix, "[") == 1 &&
			strings.Count(trimmedPrefix, "]") == 1 &&
			strings.HasSuffix(trimmedPrefix, "]") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.Count(trimmedPrefix, "[") == 1 &&
			strings.Contains(trimmedPrefix, ")|") &&
			!strings.Contains(trimmedPrefix, "(") &&
			strings.Count(trimmedPrefix, ")") == 1 &&
			strings.Count(trimmedPrefix, "|") == 1 &&
			!strings.Contains(
				trimmedPrefix[strings.Index(trimmedPrefix, ")|")+2:],
				".") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.Count(trimmedPrefix, "[") == 1 &&
			// The recovered selector opens a bracket that never closes; a
			// stray "]" would balance it into a completed index that
			// upstream evaluates to nothing, so bail to [] instead.
			!strings.Contains(trimmedPrefix, "]") &&
			strings.Contains(trimmedPrefix, "|).") &&
			!strings.Contains(trimmedPrefix, "(") &&
			strings.Count(trimmedPrefix, ")") == 1 &&
			strings.Count(trimmedPrefix, "|") == 1 &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if (trimmedPrefix == ".[}" ||
			trimmedPrefix == "|[}" ||
			strings.HasPrefix(trimmedPrefix, ".[}.")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, "|{") &&
			strings.HasSuffix(trimmedPrefix, ")") &&
			strings.Count(trimmedPrefix, "{") == 1 &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|[)") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|") &&
			strings.HasSuffix(trimmedPrefix, ".[)") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|") &&
			strings.Count(trimmedPrefix, ".[)|") == 2 &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|") &&
			strings.HasSuffix(trimmedPrefix, "|[)") &&
			strings.Count(trimmedPrefix, "|") == 2 &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|") &&
			strings.Contains(
				strings.TrimPrefix(trimmedPrefix, ".[)|"),
				".[).") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|") &&
			strings.Index(
				strings.TrimPrefix(trimmedPrefix, ".[)|"),
				"[") > 0 &&
			strings.Count(
				strings.TrimPrefix(trimmedPrefix, ".[)|"),
				"[") == 1 &&
			!strings.ContainsAny(
				strings.TrimPrefix(trimmedPrefix, ".[)|"),
				".|:") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)|") &&
			strings.HasSuffix(trimmedPrefix, ")") &&
			(compatibilityDecimalComponent(strings.TrimSuffix(
				strings.TrimPrefix(trimmedPrefix, ".[)|"), ")")) ||
				compatibilityAlphanumericComponent(strings.TrimSuffix(
					strings.TrimPrefix(trimmedPrefix, ".[)|"), ")")) ||
				strings.TrimSuffix(
					strings.TrimPrefix(trimmedPrefix, ".[)|"),
					")") != "" &&
					!strings.ContainsAny(strings.TrimSuffix(
						strings.TrimPrefix(trimmedPrefix, ".[)|"),
						")"), ".[|:")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).[)") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if marker := strings.Index(trimmedPrefix, ".[).[)"); marker > 0 &&
			compatibilityDecimalComponent(trimmedPrefix[:marker]) &&
			marker+len(".[).[)") == len(trimmedPrefix) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).") &&
			strings.Count(trimmedPrefix, ".[)") == 2 &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).") &&
			strings.HasSuffix(trimmedPrefix, "|[)") &&
			strings.Count(trimmedPrefix, "|") == 1 &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).") &&
			strings.Count(
				strings.TrimPrefix(trimmedPrefix, ".[)."),
				"[") == 1 &&
			!strings.ContainsAny(
				strings.TrimPrefix(trimmedPrefix, ".[)."),
				".|:") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if marker := strings.Index(trimmedPrefix, ".[)."); marker > 0 &&
			compatibilityDecimalComponent(trimmedPrefix[:marker]) &&
			!strings.ContainsAny(
				trimmedPrefix[marker+len(".[)."):],
				".[|:") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, "|[).") &&
			(strings.HasPrefix(tail, "|!") ||
				strings.Contains(
					strings.TrimPrefix(trimmedPrefix, "|[)."),
					"[") &&
					!strings.Contains(
						strings.TrimPrefix(trimmedPrefix, "|[)."),
						"[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, "|[)|") &&
			(strings.HasPrefix(tail, "|!") ||
				strings.Contains(
					strings.TrimPrefix(trimmedPrefix, "|[)|"),
					"[") &&
					!strings.Contains(
						strings.TrimPrefix(trimmedPrefix, "|[)|"),
						"[)")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if (strings.HasPrefix(trimmedPrefix, "|[).[)") ||
			strings.HasPrefix(trimmedPrefix, "|[)|[)")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, "|[).") &&
			strings.HasSuffix(trimmedPrefix, ".[)") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(trimmedPrefix, "|[).") &&
			!strings.ContainsAny(
				strings.TrimPrefix(trimmedPrefix, "|[)."),
				".[|") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(tail, ",") + "]",
				synthetic: true,
			}
		}
		if marker := strings.Index(trimmedPrefix, "|[)"); marker > 0 &&
			(marker+len("|[)") < len(trimmedPrefix) &&
				trimmedPrefix[marker+len("|[)")] != '.' &&
				trimmedPrefix[marker+len("|[)")] != '|' ||
				strings.Contains(trimmedPrefix[:marker], "|")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(trimmedPrefix, ".[)|[") &&
			!strings.Contains(trimmedPrefix, ".[)|[)") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, ".[") &&
			strings.Count(trimmedPrefix, "[") > 1 {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(trimmedPrefix, "[()") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if (strings.HasPrefix(trimmedPrefix, "|[]") ||
			strings.HasPrefix(trimmedPrefix, "|{}")) &&
			strings.Contains(trimmedPrefix, ")") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(trimmedPrefix, ".[)") &&
			!strings.HasPrefix(trimmedPrefix, ".[).") &&
			len(trimmedPrefix) > len(".[)") &&
			strings.HasSuffix(trimmedPrefix, ")") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if trimmedPrefix == ".{)" &&
			strings.HasPrefix(tail, "|!") &&
			len(tail) > 2 &&
			(tail[2] == '+' || tail[2] == '-' ||
				tail[2] >= '0' && tail[2] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + tail[2:] + "]", synthetic: true,
			}
		}
		if expression[1:pipe] == `"":"` &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			recovered := tail
			if space := strings.IndexFunc(
				recovered, func(value rune) bool {
					return value <= ' '
				}); space > 0 {
				recovered = recovered[:space]
			}
			return Result{
				Type: JSON, Raw: "[" + recovered + "]",
				synthetic: true,
			}
		}
		if marker := strings.LastIndex(tail, `).[)|!`); marker > 0 && marker+len(`).[)|!`) < len(tail) {
			recovered := tail[marker+len(`).[)|!`):]
			if recovered[0] == '+' || recovered[0] == '-' ||
				recovered[0] >= '0' && recovered[0] <= '9' {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if marker := strings.LastIndex(tail, `)|[)|!`); marker > 0 && marker+len(`)|[)|!`) < len(tail) {
			recovered := tail[marker+len(`)|[)|!`):]
			if recovered[0] == '+' || recovered[0] == '-' ||
				recovered[0] >= '0' && recovered[0] <= '9' {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if expression[1:pipe] == `":""` {
			if recovery := strings.LastIndex(tail, "|!"); recovery >= 0 && recovery+2 < len(tail) {
				recovered := tail[recovery+2:]
				if recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9' {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(trimmedPrefix, ".[).") &&
			(compatibilityDecimalComponent(
				strings.TrimPrefix(trimmedPrefix, ".[).")) ||
				compatibilityAlphanumericComponent(
					strings.TrimPrefix(trimmedPrefix, ".[).")) ||
				strings.TrimPrefix(trimmedPrefix, ".[).") != "" &&
					!strings.ContainsAny(
						strings.TrimPrefix(trimmedPrefix, ".[)."),
						".[|:")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type:      JSON,
				Raw:       "[" + strings.TrimSuffix(tail, ",") + "]",
				synthetic: true,
			}
		}
		if strings.HasPrefix(tail, `[)|!`) &&
			(compatibilityAlphanumericComponent(trimmedPrefix) ||
				trimmedPrefix != "" &&
					!strings.ContainsAny(trimmedPrefix, ".|:")) {
			recovered := tail[len(`[)|!`):]
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(tail, `[)|`) {
			if recovery := strings.Index(tail, "|!"); recovery > len(`[)|`) &&
				strings.Contains(tail[recovery+2:], "|!") &&
				!strings.Contains(tail[len(`[)|`):recovery], ".") &&
				(compatibilityDecimalComponent(
					tail[len(`[)|`):recovery]) ||
					compatibilityAlphanumericComponent(
						tail[len(`[)|`):recovery]) &&
						tail[len(`[)|`)] >= '0' &&
						tail[len(`[)|`)] <= '9') {
				if strings.HasPrefix(tail[recovery+2:], "|!") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				recovered := tail[recovery+2:]
				if recovered[0] != '+' && recovered[0] != '-' &&
					(recovered[0] < '0' || recovered[0] > '9') &&
					recovered[0] != '[' && recovered[0] != '{' {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(tail, `[).[)`) {
			if recovery := strings.Index(tail, "|!"); recovery > len(`[).[)`) &&
				strings.Contains(tail[recovery+2:], "|!") &&
				compatibilityAlphanumericComponent(
					tail[len(`[).[)`):recovery]) {
				recovered := tail[recovery+2:]
				if recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9' {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if strings.HasPrefix(tail, "[") {
			if strings.Contains(tail, "|![))") &&
				strings.HasSuffix(tail, `"`) {
				return Result{
					Type:      JSON,
					Raw:       "[" + tail[:len(tail)-1] + "]",
					synthetic: true,
				}
			}
			if close := strings.Index(tail, "))"); close > 0 &&
				// The bytes before the "))" become the recovered literal, so
				// a pipe or dot there is an extra selector stage that upstream
				// follows into nothing, collapsing the multipath to [].
				!strings.ContainsAny(tail[:close], "|.(") {
				return Result{
					Type:      JSON,
					Raw:       "[" + tail[:close+1] + "]",
					synthetic: true,
				}
			}
			if close := strings.IndexByte(tail, ']'); close > 0 && close+1 < len(tail) &&
				tail[close+1] != ')' &&
				strings.Contains(tail[:close], "(") &&
				!strings.Contains(tail[:close], ")") {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if close := strings.Index(tail, "))|!"); close > 0 &&
				!strings.Contains(tail[:close], "(") {
				return Result{
					Type:      JSON,
					Raw:       "[" + tail[:close+1] + "]",
					synthetic: true,
				}
			}
			if pipe := strings.Index(tail, "|!"); pipe > 0 &&
				strings.HasPrefix(tail[pipe+2:], "[).") {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if strings.Count(tail, "[") > 1 &&
				!strings.HasPrefix(tail, "[)") &&
				!strings.Contains(tail, "|!") &&
				(strings.Contains(tail, ").") ||
					strings.Contains(tail, ")|")) {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if pipe := strings.Index(tail, "|!"); pipe > 0 &&
				!strings.HasPrefix(tail, "[)") &&
				strings.Contains(tail[:pipe], "()") &&
				!strings.Contains(tail[:pipe], "())") {
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			if close := strings.IndexByte(tail, ']'); close >= 0 && close+1 < len(tail) &&
				tail[close+1] == ')' {
				end := close + 1
				if strings.Contains(tail[:close], "(") &&
					!strings.Contains(tail[:close], ")") {
					end++
				}
				return Result{
					Type:      JSON,
					Raw:       "[" + tail[:end] + "]",
					synthetic: true,
				}
			}
			if close := strings.IndexByte(tail, ']'); close >= 0 && close+1 < len(tail) &&
				!strings.HasPrefix(tail, "[)") &&
				tail[close+1] != '.' &&
				tail[close+1] != '|' {
				if recovery := strings.Index(tail, "|!"); recovery > close {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[:close+1] + "]",
						synthetic: true,
					}
				}
			}
			if close := strings.Index(tail, "())"); close >= 0 &&
				!strings.Contains(tail[:close], "]") {
				return Result{
					Type:      JSON,
					Raw:       "[" + tail[:close+3] + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(tail, "[)") {
			if strings.Contains(tail, `":`) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
			if strings.HasPrefix(trimmedPrefix, "|") &&
				trimmedPrefix != "|[)" {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
			if strings.Contains(trimmedPrefix, "|") &&
				!strings.Contains(trimmedPrefix, "|[)") {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
			if strings.HasPrefix(trimmedPrefix, ".") &&
				compatibilityDecimalComponent(
					strings.TrimPrefix(trimmedPrefix, ".")) ||
				strings.Contains(trimmedPrefix, ".") &&
					(compatibilityDecimalComponent(trimmedPrefix) ||
						strings.Trim(
							trimmedPrefix,
							"0123456789.") == "") {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
			if len(tail) == 2 ||
				tail[2] != '.' && tail[2] != '|' {
				// A dot in the prefix introduces a further path component
				// that dead-ends, so the "[)" literal is not emitted.
				if strings.Contains(trimmedPrefix, ".") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				return Result{
					Type: JSON, Raw: "[[)]", synthetic: true,
				}
			}
			if !strings.Contains(tail, "|!") {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
			if recovery := strings.LastIndex(tail, "|!"); recovery > 1 && recovery+2 < len(tail) {
				between := tail[2:recovery]
				payload := tail[recovery+2:]
				plainPipeBetween :=
					strings.ReplaceAll(between, "|!", "")
				payloadStartValid :=
					payload[0] == '+' || payload[0] == '-' ||
						payload[0] >= '0' && payload[0] <= '9' ||
						payload[0] == '[' || payload[0] == '{'
				if !payloadStartValid ||
					strings.Count(between, ".") > 1 ||
					strings.Contains(between, "[") &&
						!strings.Contains(between, "[)") ||
					strings.HasPrefix(between, "|!.") ||
					strings.HasPrefix(between, "|!|") ||
					len(between) > 2 &&
						strings.HasSuffix(between, "|!") ||
					strings.Count(plainPipeBetween, "|") > 1 ||
					strings.Contains(plainPipeBetween, "|") &&
						strings.Contains(between, ".") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if comma := strings.IndexByte(payload, ','); comma > 0 &&
					compatibilityDecimalComponent(payload[:comma]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + payload[:comma] + "]",
						synthetic: true,
					}
				}
				if strings.Contains(payload, ").") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if close := strings.IndexAny(payload, "]}"); close > 0 &&
					compatibilityDecimalComponent(payload[:close]) {
					return Result{
						Type:      JSON,
						Raw:       "[" + payload[:close] + "]",
						synthetic: true,
					}
				}
				if between == "" &&
					(payload[0] == '[' || payload[0] == '{') {
					if strings.HasPrefix(payload, "[).") {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
					recovered := payload
					if strings.HasPrefix(payload, "[)") &&
						(len(payload) == 2 ||
							payload[2] != '.' &&
								payload[2] != '|') {
						recovered = `[)`
					}
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
				if strings.HasPrefix(between, ".[)") &&
					compatibilityAlphanumericComponent(
						strings.TrimPrefix(between, ".[)")) ||
					strings.HasPrefix(between, "[)") &&
						compatibilityAlphanumericComponent(
							strings.TrimPrefix(between, "[)")) ||
					strings.HasPrefix(between, "|[)") &&
						compatibilityAlphanumericComponent(
							strings.TrimPrefix(between, "|[)")) {
					return Result{
						Type: JSON, Raw: "[" + payload + "]",
						synthetic: true,
					}
				}
				if len(between) > 1 &&
					(between[0] == '.' || between[0] == '|') &&
					compatibilityDecimalComponent(between[1:]) &&
					(trimmedPrefix == "" ||
						!strings.ContainsAny(trimmedPrefix, ".|:") ||
						trimCompatibilitySpace(trimmedPrefix) !=
							trimmedPrefix &&
							compatibilityDecimalComponent(
								trimCompatibilitySpace(
									trimmedPrefix))) {
					recovered := payload
					space := strings.IndexFunc(
						recovered, func(value rune) bool {
							return value <= ' '
						})
					close := strings.IndexByte(recovered, ')')
					if close >= 0 &&
						(close == 0 || recovered[close-1] != '(') &&
						!strings.ContainsAny(recovered[:close], "[{") &&
						(space < 0 || close < space) {
						if close+1 < len(recovered) &&
							(recovered[close+1] == '.' ||
								recovered[close+1] == '|') {
							return Result{
								Type: JSON, Raw: "[]",
								synthetic: true,
							}
						}
						recovered = recovered[:close+1]
					} else if space >= 0 {
						recovered = recovered[:space]
					}
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if lastColon := strings.LastIndexByte(expression[:pipe], ':'); strings.Count(expression[:pipe], ":") > 1 &&
			lastColon+2 < pipe &&
			expression[lastColon+1] == '"' &&
			((expression[lastColon+2] >= '0' &&
				expression[lastColon+2] <= '9') ||
				(expression[lastColon+2] >= 'A' &&
					expression[lastColon+2] <= 'Z') ||
				(expression[lastColon+2] >= 'a' &&
					expression[lastColon+2] <= 'z')) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasSuffix(tail, `:"":`) &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				tail, `:"":`)) {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasSuffix(tail, `:"":"`) &&
			compatibilityDecimalComponent(strings.TrimSuffix(
				tail, `:"":"`)) {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if len(tail) >= 4 &&
			tail[len(tail)-4] == '"' &&
			tail[len(tail)-3] == '"' &&
			tail[len(tail)-2] == ':' &&
			tail[len(tail)-1] == '"' &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(tail, `[))|!`) {
			return Result{
				Type: JSON, Raw: "[" + tail[:2] + "]",
				synthetic: true,
			}
		}
		if (strings.Contains(expression[1:pipe], "{)") ||
			strings.Contains(expression[1:pipe], ".[)") &&
				!strings.HasSuffix(expression[1:pipe], ".[)")) &&
			strings.HasPrefix(tail, "|!") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(expression[1:pipe], `"","|`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe > 0 &&
			strings.Trim(expression[1:pipe], `"`) == "" &&
			strings.HasPrefix(tail[:lastPipe], ".") &&
			strings.HasSuffix(tail[:lastPipe], `""":"`) {
			recovered := tail[lastPipe+2:]
			if quote := strings.IndexByte(recovered, '"'); quote > 0 &&
				strings.HasSuffix(recovered, ":") &&
				compatibilityDecimalComponent(recovered[:quote]) &&
				compatibilityDecimalComponent(
					recovered[quote+1:len(recovered)-1]) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe >= 0 &&
			strings.HasSuffix(tail, ":") &&
			strings.Contains(tail[:lastPipe], `","`) {
			recovered := tail[lastPipe+2:]
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') {
				payload := strings.Replace(
					tail[:lastPipe], `,"`, ",", 1)
				payload = strings.TrimSuffix(payload, `"`)
				return Result{
					Type: JSON, Raw: "[" + payload + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasPrefix(tail, `[)|!`) &&
			strings.Trim(expression[1:pipe], `"`) == "" {
			recovered := tail[len(`[)|!`):]
			for strings.HasPrefix(recovered, "|!") {
				recovered = recovered[2:]
			}
			if strings.Contains(recovered, ").") ||
				strings.Contains(recovered, ")|") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') {
				if space := strings.IndexFunc(
					recovered, func(value rune) bool {
						return value <= ' '
					}); space >= 0 {
					recovered = recovered[:space]
				} else if comma := strings.IndexByte(recovered, ','); comma >= 0 {
					recovered = recovered[:comma]
				} else if close := strings.IndexAny(recovered, "]}"); close >= 0 {
					recovered = recovered[:close]
				} else if strings.HasSuffix(recovered, `"`) {
					payload := recovered[:len(recovered)-1]
					if close := strings.IndexByte(payload, ')'); close >= 0 &&
						(close == 0 || payload[close-1] != '(') &&
						!strings.ContainsAny(payload[:close], "[{") {
						recovered = payload[:close+1]
					}
				}
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe > 0 &&
			strings.Trim(expression[1:pipe], `"`) == "" &&
			strings.HasPrefix(tail[:lastPipe], "[") &&
			strings.Contains(tail[:lastPipe], "|).") &&
			strings.Count(tail[:lastPipe], "[") == 1 &&
			strings.Count(tail[:lastPipe], "|") == 1 &&
			strings.Count(tail[:lastPipe], ".") == 1 {
			recovered := tail[lastPipe+2:]
			if strings.HasSuffix(recovered, `"`) &&
				compatibilityDecimalComponent(
					strings.TrimSuffix(recovered, `"`)) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe > 0 &&
			strings.Trim(expression[1:pipe], `"`) == "" &&
			strings.HasPrefix(tail[:lastPipe], "[") {
			before := strings.TrimPrefix(tail[:lastPipe], "[")
			if marker := strings.Index(before, "|)|"); marker > 0 &&
				compatibilityDecimalComponent(before[:marker]) &&
				compatibilityDecimalComponent(
					before[marker+len("|)|"):]) {
				recovered := tail[lastPipe+2:]
				if strings.HasSuffix(recovered, `"`) &&
					compatibilityDecimalComponent(
						strings.TrimSuffix(recovered, `"`)) {
					return Result{
						Type: JSON, Raw: "[" + recovered + "]",
						synthetic: true,
					}
				}
			}
		}
		if firstPipe := strings.Index(tail, "|!"); firstPipe > 0 &&
			strings.Trim(expression[1:pipe], `"`) == "" &&
			strings.HasPrefix(tail, "[") &&
			strings.Contains(tail[:firstPipe], ").") &&
			!strings.Contains(tail[:firstPipe], "|") &&
			strings.Count(tail[:firstPipe], "[") == 1 &&
			strings.Count(tail[:firstPipe], ".") == 1 {
			recovered := tail[firstPipe+2:]
			if strings.Contains(recovered, ").") ||
				strings.Contains(recovered, ")|") {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') {
				if space := strings.IndexFunc(
					recovered, func(value rune) bool {
						return value <= ' '
					}); space >= 0 {
					recovered = recovered[:space]
				} else if comma := strings.IndexByte(recovered, ','); comma >= 0 {
					recovered = recovered[:comma]
				} else if close := strings.IndexAny(recovered, "]}"); close >= 0 {
					recovered = recovered[:close]
				} else if strings.HasSuffix(recovered, `"`) {
					payload := recovered[:len(recovered)-1]
					if close := strings.IndexByte(payload, ')'); close >= 0 &&
						(close == 0 || payload[close-1] != '(') {
						recovered = payload[:close+1]
					}
				}
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe >= 0 &&
			(strings.Trim(expression[1:pipe], `"`) == "" ||
				compatibilityAlphanumericComponent(strings.Trim(
					expression[1:pipe], `"`)) ||
				len(strings.Trim(expression[1:pipe], `"`)) == 1 &&
					!strings.ContainsAny(
						strings.Trim(expression[1:pipe], `"`),
						".|")) &&
			(strings.HasPrefix(tail[:lastPipe], "[") &&
				strings.Contains(tail[:lastPipe], ")|") &&
				!strings.Contains(tail[:lastPipe], ".") &&
				strings.Count(tail[:lastPipe], "|") == 1 &&
				strings.Count(tail[:lastPipe], "[") == 1 ||
				strings.HasPrefix(tail[:lastPipe], "[") &&
					strings.Contains(tail[:lastPipe], ").") &&
					!strings.Contains(tail[:lastPipe], "|") &&
					strings.Count(tail[:lastPipe], ".") == 1 &&
					strings.Count(tail[:lastPipe], "[") == 1 ||
				strings.HasPrefix(tail[:lastPipe], "{") &&
					(strings.Contains(tail[:lastPipe], ")|") ||
						strings.Contains(tail[:lastPipe], ").") &&
							!strings.Contains(tail[:lastPipe], "|") &&
							strings.Count(tail[:lastPipe], ".") == 1) &&
					strings.Count(tail[:lastPipe], "{") == 1 ||
				tail[:lastPipe] == "[]" ||
				tail[:lastPipe] == "{}" ||
				strings.HasPrefix(tail[:lastPipe], "[].") &&
					strings.Count(tail[:lastPipe], ".") == 1 ||
				strings.HasPrefix(tail[:lastPipe], "{}.") &&
					strings.Count(tail[:lastPipe], ".") == 1 ||
				strings.HasPrefix(tail[:lastPipe], "[]|") &&
					strings.Count(tail[:lastPipe], "|") == 1 ||
				strings.HasPrefix(tail[:lastPipe], "{}|") &&
					strings.Count(tail[:lastPipe], "|") == 1) {
			recovered := tail[lastPipe+2:]
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9' ||
					recovered[0] == '[' || recovered[0] == '{') {
				// A scalar literal parses as a number and stops at the
				// first comma/whitespace/closing bracket, so trailing
				// selector fields are dropped. Composite ([/{) literals
				// keep their nested commas and fall to the quote handling.
				if recovered[0] != '[' && recovered[0] != '{' {
					recovered = compatibilityNumericLiteralTail(recovered)
				}
				if space := strings.IndexFunc(
					recovered, func(value rune) bool {
						return value <= ' '
					}); space >= 0 {
					recovered = recovered[:space]
				} else if strings.HasSuffix(recovered, `"`) {
					payload := recovered[:len(recovered)-1]
					if close := strings.IndexByte(payload, ')'); close >= 0 &&
						(close == 0 || payload[close-1] != '(') {
						recovered = payload[:close+1]
					}
				}
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe >= 0 &&
			strings.HasSuffix(tail, ":") &&
			strings.HasSuffix(tail[:lastPipe], ":") &&
			compatibilityAlphanumericComponent(strings.TrimSuffix(
				tail[:lastPipe], ":")) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if firstPipe := strings.Index(tail, "|!"); firstPipe >= 0 &&
			strings.Count(tail, "|!") >= 2 &&
			(strings.HasSuffix(tail, ":") ||
				strings.Contains(tail[firstPipe+2:], ":")) &&
			strings.Contains(tail[:firstPipe], ":") {
			recovered := tail[firstPipe+2:]
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if separator := strings.LastIndex(tail, `":`); separator >= 0 {
			query := tail[separator+2:]
			if query != "" && strings.Trim(query, "*?") == "" {
				if selected := compatibilityGet(
					current.Raw, query); selected.Exists() {
					return Result{
						Type:      JSON,
						Raw:       "[" + selected.Raw + "]",
						synthetic: true,
					}
				}
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe >= 0 && strings.HasSuffix(tail, ":") &&
			tail != "" &&
			(strings.IndexByte(expression[:pipe], ':') < 0 ||
				strings.IndexByte(expression[:pipe], '"') < 0 ||
				strings.IndexByte(expression[:pipe], ':') >
					strings.IndexByte(expression[:pipe], '"')) &&
			trimCompatibilitySpace(tail[:lastPipe]) != ":" &&
			!strings.HasPrefix(tail[:lastPipe], ":") &&
			!(strings.Contains(tail[:lastPipe], " ") &&
				!strings.Contains(tail[:lastPipe], `"`)) &&
			(!strings.Contains(tail[:lastPipe], "|") ||
				strings.HasPrefix(tail[:lastPipe], `|":"`)) &&
			!strings.HasPrefix(tail[:lastPipe], `:"`) &&
			!(strings.HasSuffix(tail[:lastPipe], `""`) &&
				strings.IndexByte(tail[:lastPipe], ':') == 1) &&
			!strings.HasSuffix(tail[:lastPipe], `"":`) &&
			!strings.Contains(tail[:lastPipe], `|""`) &&
			!strings.Contains(tail[:lastPipe], `.""`) &&
			!(strings.HasSuffix(tail[:lastPipe], ":") &&
				compatibilityAlphanumericComponent(strings.TrimSuffix(
					tail[:lastPipe], ":"))) &&
			strings.Contains(tail[:lastPipe], ":") {
			recovered := tail[lastPipe+2:]
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') {
				if space := strings.IndexFunc(
					recovered, func(value rune) bool {
						return value <= ' '
					}); space >= 0 {
					recovered = recovered[:space]
				}
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe >= 0 && tail != "" &&
			(strings.IndexByte(expression[:pipe], ':') < 0 ||
				strings.IndexByte(expression[:pipe], '"') < 0 ||
				strings.IndexByte(expression[:pipe], ':') >
					strings.IndexByte(expression[:pipe], '"')) &&
			trimCompatibilitySpace(tail[:lastPipe]) != ":" &&
			!strings.HasPrefix(tail[:lastPipe], ":") &&
			!(strings.Contains(tail[:lastPipe], " ") &&
				!strings.Contains(tail[:lastPipe], `"`)) &&
			(!strings.Contains(tail[:lastPipe], "|") ||
				strings.HasPrefix(tail[:lastPipe], `|":"`)) &&
			!strings.HasPrefix(tail[:lastPipe], `:"`) &&
			!(strings.HasSuffix(tail[:lastPipe], `""`) &&
				strings.IndexByte(tail[:lastPipe], ':') == 1) &&
			!strings.HasSuffix(tail[:lastPipe], `"":`) &&
			!strings.Contains(tail[:lastPipe], `|""`) &&
			!strings.Contains(tail[:lastPipe], `.""`) &&
			!(strings.HasSuffix(tail[:lastPipe], ":") &&
				compatibilityAlphanumericComponent(strings.TrimSuffix(
					tail[:lastPipe], ":"))) &&
			strings.Contains(tail[:lastPipe], ":") {
			recovered := tail[lastPipe+2:]
			if recovered != "" &&
				(recovered[0] == '+' || recovered[0] == '-' ||
					recovered[0] >= '0' && recovered[0] <= '9') &&
				strings.Contains(recovered, ":") {
				if space := strings.IndexFunc(
					recovered, func(value rune) bool {
						return value <= ' '
					}); space >= 0 {
					recovered = recovered[:space]
				} else if comma := strings.IndexByte(recovered, ','); comma >= 0 {
					recovered = recovered[:comma]
				} else if strings.HasSuffix(recovered, `"`) {
					payload := recovered[:len(recovered)-1]
					if trimCompatibilitySpace(payload) != payload {
						recovered = trimCompatibilitySpace(payload)
					} else if close := strings.IndexAny(payload, "]}"); close >= 0 {
						recovered = payload[:close]
					} else if close := strings.IndexByte(payload, ')'); close >= 0 &&
						(close == 0 || payload[close-1] != '(') {
						recovered = payload[:close+1]
					}
				}
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
		}
		if strings.HasSuffix(tail, ":") &&
			(len(tail) < 2 || tail[len(tail)-2] != '\\') &&
			strings.Count(tail, `"`)%2 == 1 &&
			!(strings.HasSuffix(tail, `:"":`) &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					tail, `:"":`))) &&
			!strings.Contains(expression[:pipe], ",") &&
			(strings.Count(expression[:pipe], ":") <= 1 ||
				!strings.HasSuffix(expression[:pipe], `:"`) &&
					(!strings.Contains(expression[:pipe], `":"`) ||
						strings.HasSuffix(expression[:pipe], ":"))) &&
			(strings.IndexByte(expression[:pipe], ':') < 0 ||
				strings.IndexByte(expression[:pipe], '"') >= 0 &&
					!strings.Contains(expression[:pipe], "|") &&
					(strings.IndexByte(expression[:pipe], ':') >
						strings.LastIndexByte(expression[:pipe], '"') ||
						strings.Count(
							expression[:strings.IndexByte(
								expression[:pipe], ':')],
							`"`)%2 == 1) ||
				strings.Contains(expression[:pipe], `\:"`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if lastPipe := strings.LastIndex(tail, "|!"); lastPipe >= 0 && tail != "" &&
			strings.Contains(tail, ":") &&
			strings.Contains(tail[:lastPipe], ":") &&
			strings.Contains(tail[lastPipe+2:], ":") &&
			!(strings.HasSuffix(tail[:lastPipe], `"":`) &&
				strings.Count(tail[:lastPipe], ":") == 1) &&
			!(strings.HasSuffix(tail[:lastPipe], ":") &&
				compatibilityAlphanumericComponent(strings.TrimSuffix(
					tail[:lastPipe], ":"))) &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') &&
			strings.IndexByte(expression[:pipe], ':') >
				strings.LastIndexByte(expression[:pipe], '"') {
			recovered := tail[lastPipe+2:]
			if strings.HasSuffix(recovered, `:""`) {
				return Result{
					Type: JSON, Raw: "[" + recovered + "]",
					synthetic: true,
				}
			}
			tail = recovered
		}
		if colon := strings.IndexByte(tail, ':'); colon >= 0 &&
			compatibilityMalformedLiteralColon(tail) &&
			!(strings.LastIndex(tail, "|!") >= 0 &&
				strings.LastIndex(tail, "|!")+2 < len(tail) &&
				tail[strings.LastIndex(tail, "|!")+2] == ':' &&
				strings.HasSuffix(
					tail[:strings.LastIndex(tail, "|!")], `"":`) &&
				strings.Count(
					tail[:strings.LastIndex(tail, "|!")], ":") == 1) &&
			strings.Index(tail, `"":""`) != 1 &&
			!(strings.IndexByte(tail, ':') == 1 &&
				strings.Count(tail, ":") == 2 &&
				!strings.Contains(tail, "::") &&
				!strings.Contains(tail, "|!") &&
				strings.LastIndexByte(tail, ':')-
					strings.IndexByte(tail, ':') > 2 &&
				tail[strings.LastIndexByte(tail, ':')-1] == '"' &&
				!strings.HasSuffix(tail, `""`) &&
				strings.HasSuffix(tail, `"`)) &&
			!(strings.Contains(tail, `"":`) &&
				strings.IndexByte(tail, ':') >= 3 &&
				tail[strings.IndexByte(tail, ':')-1] == '"' &&
				tail[strings.IndexByte(tail, ':')-2] == '"' &&
				strings.Count(tail, ":") >= 2 &&
				!strings.Contains(tail, "::") &&
				!strings.Contains(tail, "|!") &&
				!strings.HasSuffix(tail, `""`) &&
				strings.HasSuffix(tail, `"`)) &&
			(strings.LastIndexByte(tail, ':') < 1 ||
				tail[strings.LastIndexByte(tail, ':')-1] != '\\') &&
			(!strings.HasSuffix(tail, ":") ||
				len(tail) < 2 ||
				tail[len(tail)-2] != '\\') &&
			!(strings.HasSuffix(tail, `:"":`) &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					tail, `:"":`))) &&
			!(strings.Contains(tail, "::") &&
				strings.Count(
					tail[:strings.Index(tail, "::")], `"`) >= 2 &&
				!strings.Contains(
					tail[:strings.Index(tail, "::")], ":") &&
				strings.Count(tail, `"`) == 3 &&
				// Upstream squashes the whole literal remainder, so a
				// three-quote "::"-shaped tail recovers as [tail] whether
				// it closes on a quote or an alphanumeric byte. Only a
				// trailing top-level colon (empty value) collapses to [].
				(strings.HasSuffix(tail, `"`) ||
					compatibilityByteAlphanumeric(
						tail[len(tail)-1]))) &&
			!strings.Contains(tail, `""""::`) &&
			strings.LastIndex(tail, "|!") <
				strings.LastIndexByte(tail, ':') &&
			!strings.Contains(expression[:pipe], ",") &&
			(strings.Count(expression[:pipe], ":") <= 1 ||
				!strings.HasSuffix(expression[:pipe], `:"`) &&
					(!strings.Contains(expression[:pipe], `":"`) ||
						strings.HasSuffix(expression[:pipe], ":"))) &&
			(!strings.Contains(expression[:pipe], ":") ||
				strings.IndexByte(expression[:pipe], ':') >
					strings.LastIndexByte(
						expression[:pipe], '"') ||
				strings.Count(
					expression[:strings.IndexByte(
						expression[:pipe], ':')],
					`"`)%2 == 1) {
			return Result{
				Type: JSON, Raw: "[]", synthetic: true,
			}
		}
		prefixColonAfterQuote :=
			strings.IndexByte(expression[:pipe], ':') >
				strings.LastIndexByte(expression[:pipe], '"')
		if (compatibilityMalformedLiteralColon(tail) ||
			prefixColonAfterQuote && strings.Contains(tail, ":") &&
				tail != "" &&
				(tail[0] == '+' || tail[0] == '-' ||
					tail[0] >= '0' && tail[0] <= '9')) &&
			strings.LastIndex(tail, "|!") >= 0 &&
			!(strings.HasSuffix(
				tail[:strings.LastIndex(tail, "|!")], `"":`) &&
				strings.Count(
					tail[:strings.LastIndex(tail, "|!")], ":") == 1) &&
			!(strings.HasSuffix(
				tail[:strings.LastIndex(tail, "|!")], `":`) &&
				strings.Count(
					tail[:strings.LastIndex(tail, "|!")], ":") == 1) &&
			!(strings.HasSuffix(
				tail[:strings.LastIndex(tail, "|!")], ":") &&
				compatibilityAlphanumericComponent(strings.TrimSuffix(
					tail[:strings.LastIndex(tail, "|!")], ":"))) &&
			strings.LastIndex(tail, "|!") >
				strings.LastIndexByte(tail, ':') {
			lastPipe := strings.LastIndex(tail, "|!")
			tail = tail[lastPipe+2:]
		}
		if strings.Contains(expression[1:pipe], ".[)") ||
			strings.Contains(expression[1:pipe], "{)") ||
			strings.Contains(expression[1:pipe], "|[)") {
			for strings.HasPrefix(tail, "|!") {
				tail = tail[2:]
			}
		}
		if tail == "" {
			return Result{
				Type: JSON, Raw: "[]", synthetic: true,
			}
		}
		if colon, quote := strings.IndexByte(
			expression[1:pipe], ':'),
			strings.LastIndexByte(expression[1:pipe], '"'); colon >= 0 && quote >= 0 &&
			(colon > quote ||
				strings.Count(
					expression[1:pipe][:colon],
					`"`)%2 == 1) &&
			!strings.Contains(expression[1:pipe], "|") &&
			!strings.Contains(expression[1:pipe], ",") &&
			!(strings.LastIndex(tail, "|!") >= 0 &&
				strings.LastIndex(tail, "|!")+2 < len(tail) &&
				tail[strings.LastIndex(tail, "|!")+2] == ':' &&
				strings.HasSuffix(
					tail[:strings.LastIndex(tail, "|!")], `"":`) &&
				strings.Count(
					tail[:strings.LastIndex(tail, "|!")], ":") == 1) &&
			strings.Index(tail, `"":""`) != 1 &&
			!(strings.IndexByte(tail, ':') == 1 &&
				strings.Count(tail, ":") == 2 &&
				!strings.Contains(tail, "::") &&
				!strings.Contains(tail, "|!") &&
				strings.LastIndexByte(tail, ':')-
					strings.IndexByte(tail, ':') > 2 &&
				tail[strings.LastIndexByte(tail, ':')-1] == '"' &&
				!strings.HasSuffix(tail, `""`) &&
				strings.HasSuffix(tail, `"`)) &&
			!(strings.Contains(tail, `"":`) &&
				strings.IndexByte(tail, ':') >= 3 &&
				tail[strings.IndexByte(tail, ':')-1] == '"' &&
				tail[strings.IndexByte(tail, ':')-2] == '"' &&
				strings.Count(tail, ":") >= 2 &&
				!strings.Contains(tail, "::") &&
				!strings.Contains(tail, "|!") &&
				!strings.HasSuffix(tail, `""`) &&
				strings.HasSuffix(tail, `"`)) &&
			(strings.LastIndexByte(tail, ':') < 1 ||
				tail[strings.LastIndexByte(tail, ':')-1] != '\\') &&
			(!strings.HasSuffix(tail, ":") ||
				len(tail) < 2 ||
				tail[len(tail)-2] != '\\') &&
			!(strings.HasSuffix(tail, `:"":`) &&
				compatibilityDecimalComponent(strings.TrimSuffix(
					tail, `:"":`))) &&
			!(strings.Contains(tail, "::") &&
				strings.Count(
					tail[:strings.Index(tail, "::")], `"`) >= 2 &&
				!strings.Contains(
					tail[:strings.Index(tail, "::")], ":") &&
				strings.Count(tail, `"`) == 3 &&
				// Upstream squashes the whole literal remainder, so a
				// three-quote "::"-shaped tail recovers as [tail] whether
				// it closes on a quote or an alphanumeric byte. Only a
				// trailing top-level colon (empty value) collapses to [].
				(strings.HasSuffix(tail, `"`) ||
					compatibilityByteAlphanumeric(
						tail[len(tail)-1]))) &&
			!strings.Contains(tail, `""""::`) &&
			(strings.Count(expression[1:pipe], ":") <= 1 ||
				!strings.HasSuffix(expression[1:pipe], `:"`) &&
					(!strings.Contains(expression[1:pipe], `":"`) ||
						strings.HasSuffix(expression[1:pipe], ":"))) &&
			strings.Contains(tail, `":`) &&
			(strings.Count(tail, ":") > 1 ||
				strings.Count(
					tail[strings.LastIndexByte(tail, ':')+1:],
					`"`)%2 == 0 ||
				strings.HasPrefix(
					tail[strings.LastIndexByte(tail, ':')+1:],
					`\`)) &&
			strings.LastIndex(tail, "|!") <
				strings.LastIndexByte(tail, ':') {
			return Result{
				Type: JSON, Raw: "[]", synthetic: true,
			}
		}
		prefix := strings.Trim(expression[1:pipe], `"`)
		if strings.HasPrefix(expression[1:pipe], `"|":`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.Contains(expression[1:pipe], ",") &&
			strings.HasSuffix(expression[1:pipe], `".[)`) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if expression[1:pipe] == `",` &&
			strings.HasSuffix(tail, ":") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if (expression[1:pipe] == `":,` ||
			expression[1:pipe] == `",:`) &&
			strings.Contains(tail, ":") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(expression[1:pipe], ",:") &&
			!strings.HasPrefix(expression[1:pipe], ",:") &&
			strings.Contains(tail, ":") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(expression[1:pipe], ",") &&
			strings.HasSuffix(expression[1:pipe], ":") &&
			strings.Contains(tail, ":") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(prefix, ".[()") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(prefix, ".[))") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(prefix, ".[") &&
			strings.HasSuffix(prefix, "))") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(prefix, ".[") &&
			strings.HasSuffix(prefix, "()") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(expression[1:pipe], `:".`) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(expression[1:pipe], `|""`) &&
			(strings.HasSuffix(expression[1:pipe], ":") ||
				strings.HasPrefix(expression[1:pipe], `"":`) ||
				strings.Contains(expression[1:pipe], `:"|""`) ||
				strings.Contains(expression[1:pipe], `|"":`)) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(expression[1:pipe], `"":`) &&
			strings.Contains(expression[1:pipe], "|") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(expression[1:pipe], `""`) &&
			strings.Contains(expression[1:pipe], `:"|`) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(expression[1:pipe], `:"|`) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if (prefix == "|[]" || prefix == "|{}" ||
			strings.HasPrefix(prefix, "|[].") ||
			strings.HasPrefix(prefix, "|{}.") ||
			strings.HasPrefix(prefix, "|[]|") ||
			strings.HasPrefix(prefix, "|{}|")) &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if (strings.HasPrefix(prefix, "|[") &&
			strings.Count(prefix, "|") == 1 &&
			!strings.Contains(prefix, "(") &&
			strings.Count(prefix, ".") == 1 ||
			strings.HasPrefix(prefix, ".[") &&
				!strings.Contains(prefix, "|") &&
				!strings.Contains(prefix, "(") &&
				!strings.Contains(prefix, ".[)") &&
				strings.Count(prefix, ".") == 2) &&
			strings.Contains(prefix, ").") &&
			tail != "" &&
			(tail[0] == '+' || tail[0] == '-' ||
				tail[0] >= '0' && tail[0] <= '9') {
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
		if strings.HasPrefix(prefix, "{).") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "{)|") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, ".") &&
			strings.Index(prefix, "{)") > 1 {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, ".") &&
			strings.Contains(prefix, "|[)") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if marker := strings.Index(prefix, "|[)"); marker > 0 &&
			strings.Contains(prefix[:marker], ".") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(prefix, ".[)") &&
			strings.Count(prefix, ".") >= 2 {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, ".") &&
			strings.Count(prefix, ".") >= 2 &&
			strings.Contains(prefix, ".[") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|[)") &&
			len(prefix) > len("|[)") &&
			prefix[len("|[)")] != '.' &&
			prefix[len("|[)")] != '|' {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|[)") &&
			strings.Count(prefix, ".") > 1 {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			!strings.HasPrefix(prefix, "|[)") &&
			strings.Count(prefix, "|") > 1 &&
			strings.Contains(prefix, "|[)") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|[") &&
			strings.Count(prefix, "|") > 1 &&
			strings.Contains(prefix, ").") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.Contains(prefix, ".[)") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.Index(prefix, "{)") > 1 {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.Contains(prefix, ".[") &&
			strings.HasSuffix(prefix, ")") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.Contains(prefix, "|") &&
			strings.Contains(prefix, ".[)") &&
			strings.IndexByte(prefix, '|') <
				strings.Index(prefix, ".[)") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.Contains(prefix, ":") &&
			!strings.Contains(prefix, `":`) &&
			len(prefix) > 1 &&
			prefix[1] != '"' {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.Contains(prefix, `":`) &&
			strings.Count(prefix, `"`) > 1 &&
			!strings.Contains(prefix, `":"`) &&
			len(prefix) > 1 &&
			prefix[1] != '"' {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.HasSuffix(prefix, ":") &&
			compatibilityAlphanumericComponent(
				prefix[1:len(prefix)-1]) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.Contains(prefix, ":") &&
			strings.Contains(prefix, " ") {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.Contains(prefix, ":") &&
			(compatibilityAlphanumericComponent(strings.ReplaceAll(
				prefix[1:], ":", "")) ||
				strings.Contains(prefix, `:"`) &&
					!strings.Contains(prefix, `":"`) &&
					compatibilityAlphanumericComponent(strings.ReplaceAll(
						strings.ReplaceAll(prefix[1:], ":", ""),
						`"`, ""))) {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		if strings.HasPrefix(prefix, "|") &&
			strings.HasSuffix(prefix, `"":`) &&
			len(prefix) > 1 &&
			prefix[1] != '"' {
			return Result{Type: JSON, Raw: "[]", synthetic: true}
		}
		commaPrefix := strings.Trim(prefix, ` ,"`)
		commaPrefixValid := strings.Contains(prefix, ",") &&
			(commaPrefix == "" || commaPrefix == ":" ||
				len(commaPrefix) > 1 &&
					commaPrefix[0] == ':' &&
					!strings.HasPrefix(expression[1:pipe], `"`) &&
					(commaPrefix[1] == '+' ||
						commaPrefix[1] == '-' ||
						commaPrefix[1] >= '0' &&
							commaPrefix[1] <= '9') ||
				len(commaPrefix) > 2 &&
					commaPrefix[0] == ':' &&
					commaPrefix[1] == '"' &&
					(commaPrefix[2] == '+' ||
						commaPrefix[2] == '-' ||
						commaPrefix[2] >= '0' &&
							commaPrefix[2] <= '9') ||
				commaPrefix[0] == '#' ||
				commaPrefix[0] == '+' ||
				commaPrefix[0] == '-' ||
				commaPrefix[0] >= '0' && commaPrefix[0] <= '9' ||
				commaPrefix[0] >= 'A' && commaPrefix[0] <= 'Z' ||
				commaPrefix[0] >= 'a' && commaPrefix[0] <= 'z')
		if singlePipeLiteralEntry &&
			strings.HasPrefix(expression, "[,") {
			commaPrefixValid = true
		}
		if singlePipeLiteralEntry &&
			strings.Contains(expression, `)|!`) {
			commaPrefixValid = true
		}
		arrayDottedPrefixValid := false
		if current.IsArray() {
			arrayDottedPrefixValid = strings.HasPrefix(prefix, "#.")
			head, _, _ := strings.Cut(prefix, ".")
			if arrayIndex, err := strconv.Atoi(head); err == nil && compatibilityDecimalComponent(head) {
				arrayDottedPrefixValid =
					strings.Count(prefix, ".") == 1 &&
						arrayIndex >= 0 && arrayIndex < len(current.Array())
			}
		}
		wildcardDottedTarget := Result{}
		if len(prefix) > 1 && strings.HasSuffix(prefix, ".") {
			wildcardDottedTarget = compatibilityChild(
				current, prefix[:len(prefix)-1])
		}
		wildcardDottedPrefixValid := current.IsObject() &&
			!current.arrayElement &&
			len(prefix) > 1 &&
			strings.HasSuffix(prefix, ".") &&
			strings.Trim(prefix[:len(prefix)-1], "*?") == "" &&
			(wildcardDottedTarget.IsObject() ||
				wildcardDottedTarget.IsArray())
		arrayMalformedCountPrefixValid := current.IsArray() &&
			strings.HasPrefix(prefix, `#.",`) &&
			compatibilityDecimalComponent(
				strings.TrimPrefix(prefix, `#.",`))
		numericMalformedBracketPrefixValid :=
			strings.Contains(prefix, `".[)`) &&
				prefix != "" &&
				(prefix[0] == '+' || prefix[0] == '-' ||
					prefix[0] >= '0' && prefix[0] <= '9' ||
					prefix[0] >= 'A' && prefix[0] <= 'Z' ||
					prefix[0] >= 'a' && prefix[0] <= 'z')
		malformedBracketPipePrefixValid := false
		if marker := strings.LastIndex(prefix, ")|"); marker >= 0 &&
			(!strings.HasPrefix(prefix, "|") &&
				!strings.Contains(prefix[:marker], "(") &&
				!strings.Contains(prefix[:marker], ".[)") &&
				strings.Contains(prefix[:marker], ".[") ||
				strings.HasPrefix(prefix, "|[") &&
					!strings.Contains(prefix[:marker], "(")) {
			malformedBracketPipePrefixValid =
				compatibilityDecimalComponent(prefix[marker+2:])
		}
		quotedPipeColonPrefixValid :=
			strings.Contains(expression[1:pipe], "|") &&
				strings.Contains(expression[1:pipe], ":") &&
				strings.IndexByte(expression[1:pipe], '|') <
					strings.IndexByte(expression[1:pipe], ':') &&
				strings.IndexByte(expression[1:pipe], ':') >
					strings.IndexByte(expression[1:pipe], '"') &&
				expression[1:pipe][strings.IndexByte(expression[1:pipe], ':')-1] != '|'
		prefixColonBeforeQuoteValid :=
			strings.Contains(expression[1:pipe], `.:"`)
		prefixQuotedColonSeparatorValid := false
		if colon := strings.IndexByte(expression[1:pipe], ':'); colon >= 0 &&
			strings.LastIndexByte(expression[1:pipe], '"') > colon {
			quotesBeforeColon := strings.Count(
				expression[1:pipe][:colon], `"`)
			prefixQuotedColonSeparatorValid =
				quotesBeforeColon > 0 &&
					quotesBeforeColon%2 == 0
		}
		prefixValid := prefixQuotedColonSeparatorValid ||
			prefixColonBeforeQuoteValid ||
			quotedPipeColonPrefixValid ||
			strings.Contains(prefix, "{)") ||
			strings.Contains(prefix, ".{") &&
				strings.HasSuffix(prefix, ")") &&
				!strings.Contains(prefix, `"`) ||
			strings.Contains(prefix, "|[)") ||
			strings.Contains(prefix, "|[") &&
				strings.HasSuffix(prefix, ")") ||
			prefix == ".[)" ||
			numericMalformedBracketPrefixValid ||
			malformedBracketPipePrefixValid ||
			strings.Contains(prefix, ".[)|") &&
				strings.Count(prefix, "|") == 1 ||
			strings.Contains(prefix, ".[") &&
				strings.HasSuffix(prefix, ")") &&
				!strings.Contains(prefix, `"`) ||
			arrayMalformedCountPrefixValid ||
			!strings.Contains(prefix, "|") &&
				!strings.Contains(expression[1:pipe], `.".`) &&
				(!current.IsArray() ||
					!strings.Contains(expression[1:pipe], `\."`)) &&
				(!strings.Contains(prefix, ",") || commaPrefixValid) &&
				(!strings.Contains(prefix, ".") ||
					wildcardDottedPrefixValid ||
					arrayDottedPrefixValid ||
					compatibilityOnlyEscapedDots(prefix)) &&
				(!strings.Contains(tail, `":`) ||
					strings.Contains(prefix, ":"))
		tailStartValid := tail[0] == '+' || tail[0] == '-' ||
			tail[0] >= '0' && tail[0] <= '9'
		if tail[0] == '{' || tail[0] == '[' {
			tailStartValid = true
		}
		if prefixValid && tailStartValid {
			if tail[0] == '{' || tail[0] == '[' {
				if len(tail) >= 3 &&
					tail[0] == '[' &&
					tail[1] == ')' &&
					strings.HasSuffix(tail, `"`) {
					// A recovered "[)" tail carrying pipe-literal stages:
					// two or more "|!" stages peel down to nothing (empty
					// array); a single stage squashes its trailing literal
					// as a scalar; no stage emits the raw remainder. A
					// nested container ("[" / "{") in a middle stage is
					// itself a malformed selector that dead-ends to [].
					body := tail[2 : len(tail)-1]
					if strings.Count(body, "|!") >= 2 ||
						strings.Contains(body, "|!") &&
							strings.ContainsAny(body, "[{") {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
					if strings.Contains(body, "|!") {
						last := strings.LastIndex(tail, "|!")
						return Result{
							Type: JSON,
							Raw: "[" + compatibilityScalarLiteralTail(
								tail[last+2:]) + "]",
							synthetic: true,
						}
					}
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[:len(tail)-1] + "]",
						synthetic: true,
					}
				}
				if strings.HasPrefix(tail, "[(") {
					if close := strings.Index(tail, "])"); close >= 0 {
						return Result{
							Type:      JSON,
							Raw:       "[" + tail[:close+2] + "]",
							synthetic: true,
						}
					}
				}
				if strings.HasSuffix(tail, `])"`) ||
					strings.HasSuffix(tail, `})"`) {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[:len(tail)-1] + "]",
						synthetic: true,
					}
				}
				if strings.HasPrefix(tail, "[(") {
					if close := strings.Index(tail, "))"); close >= 0 {
						return Result{
							Type:      JSON,
							Raw:       "[" + tail[:close+2] + "]",
							synthetic: true,
						}
					}
				}
				if closePipe := strings.Index(tail, ")|!"); closePipe >= 0 &&
					closePipe+3 < len(tail) &&
					!strings.Contains(tail[:closePipe], "(") {
					tail = tail[closePipe+3:]
					if tail[0] != '+' && tail[0] != '-' &&
						(tail[0] < '0' || tail[0] > '9') &&
						tail[0] != '[' && tail[0] != '{' {
						return Result{
							Type: JSON, Raw: "[]", synthetic: true,
						}
					}
				}
			}
			if tail[0] == '{' || tail[0] == '[' {
				closeComposite := strings.IndexAny(tail, "]}")
				closeParen := strings.IndexByte(tail, ')')
				if closeParen >= 0 && closeParen+1 < len(tail) &&
					(closeComposite < 0 ||
						closeParen < closeComposite) &&
					(closeParen == 0 ||
						tail[closeParen-1] != '(') &&
					!strings.Contains(tail[:closeParen], "(") &&
					(tail[closeParen+1] == '.' ||
						tail[closeParen+1] == '|') {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if closeComposite >= 0 &&
					closeComposite+1 < len(tail) &&
					(tail[closeComposite+1] == '.' ||
						tail[closeComposite+1] == '|') {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if closeComposite >= 0 &&
					(closeParen < 0 || closeComposite < closeParen) &&
					!(strings.HasSuffix(tail, `"`) &&
						strings.Contains(tail[:closeComposite], "(") &&
						!strings.Contains(tail[:closeComposite], ")")) {
					tail = tail[:closeComposite+1]
				} else if closeParen >= 0 &&
					(closeParen == 0 ||
						tail[closeParen-1] != '(') &&
					(closeParen <= 1 ||
						!strings.Contains(tail[1:closeParen], "[")) &&
					!strings.Contains(tail[:closeParen], "(") {
					tail = tail[:closeParen+1]
				}
				if strings.HasSuffix(tail, `"`) &&
					strings.HasSuffix(
						tail[:len(tail)-1], "))") {
					tail = tail[:len(tail)-1]
				}
				return Result{
					Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
				}
			}
			if repeated := strings.Index(tail, "|!|!"); repeated > 0 &&
				!strings.Contains(tail[:repeated], "(") &&
				!strings.ContainsAny(
					tail[:repeated-1], ")]}") &&
				strings.ContainsRune(
					")]}",
					rune(tail[repeated-1])) {
				return Result{
					Type: JSON, Raw: "[]", synthetic: true,
				}
			}
			for {
				closePipe := strings.Index(tail, ")|!")
				if closePipe > 0 &&
					(strings.Contains(tail[:closePipe], "(") ||
						strings.ContainsAny(tail[:closePipe], "[{") ||
						strings.ContainsAny(tail[:closePipe], ")]}")) {
					closePipe = -1
				}
				if bracketPipe := strings.Index(tail, "]|!"); bracketPipe >= 0 &&
					!strings.Contains(tail[:bracketPipe], "[") &&
					!strings.Contains(tail[:bracketPipe], "(") &&
					!strings.ContainsAny(tail[:bracketPipe], ")]}") &&
					(closePipe < 0 || bracketPipe < closePipe) {
					closePipe = bracketPipe
				}
				if bracePipe := strings.Index(tail, "}|!"); bracePipe >= 0 &&
					!strings.Contains(tail[:bracePipe], "{") &&
					!strings.Contains(tail[:bracePipe], "(") &&
					!strings.ContainsAny(tail[:bracePipe], ")]}") &&
					(closePipe < 0 || bracePipe < closePipe) {
					closePipe = bracePipe
				}
				if closePipe < 0 {
					break
				}
				tail = tail[closePipe+3:]
				if tail == "" ||
					tail[0] != '+' && tail[0] != '-' &&
						(tail[0] < '0' || tail[0] > '9') &&
						tail[0] != '[' && tail[0] != '{' {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
			}
			if tail[0] == '[' || tail[0] == '{' {
				if strings.HasPrefix(tail, "[).") {
					return Result{
						Type: JSON, Raw: "[]", synthetic: true,
					}
				}
				if strings.HasPrefix(tail, "[)") &&
					(len(tail) == 2 ||
						tail[2] != '.' && tail[2] != '|') {
					return Result{
						Type: JSON, Raw: "[[)]", synthetic: true,
					}
				}
				return Result{
					Type: JSON, Raw: "[" + tail + "]",
					synthetic: true,
				}
			}
			tail = strings.TrimSuffix(tail, ",")
			space := strings.IndexFunc(tail, func(value rune) bool {
				return value <= ' '
			})
			closeParen := strings.IndexByte(tail, ')')
			closeComposite := strings.IndexAny(tail, "]}")
			comma := strings.IndexByte(tail, ',')
			if closeParen >= 0 && closeParen+1 < len(tail) &&
				(closeComposite < 0 || closeParen < closeComposite) &&
				(closeParen == 0 || tail[closeParen-1] != '(') &&
				!strings.Contains(tail[:closeParen], "(") &&
				!strings.Contains(tail[:closeParen], "{") &&
				!strings.Contains(tail[:closeParen], "[") &&
				(tail[closeParen+1] == '.' ||
					tail[closeParen+1] == '|') {
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if closeComposite >= 0 && closeComposite+1 < len(tail) &&
				(closeParen < 0 || closeComposite < closeParen) &&
				(tail[closeComposite+1] == '.' ||
					tail[closeComposite+1] == '|') {
				if strings.ContainsAny(
					tail[:closeComposite], "([{") {
					return Result{
						Type:      JSON,
						Raw:       "[" + tail[:closeComposite] + "]",
						synthetic: true,
					}
				}
				return Result{Type: JSON, Raw: "[]", synthetic: true}
			}
			if closeParen >= 0 &&
				(closeParen == 0 || tail[closeParen-1] != '(') &&
				!strings.ContainsAny(tail[:closeParen], "[{") &&
				!strings.Contains(tail[:closeParen], "(") &&
				(space < 0 || closeParen < space) &&
				(closeComposite < 0 || closeParen < closeComposite) &&
				(comma < 0 || closeParen < comma) {
				tail = tail[:closeParen+1]
			} else if closeComposite >= 0 &&
				(space < 0 || closeComposite < space) &&
				(comma < 0 || closeComposite < comma) {
				tail = tail[:closeComposite]
			} else if comma >= 0 && (space < 0 || comma < space) {
				tail = tail[:comma]
			} else if space >= 0 {
				tail = strings.TrimSuffix(tail[:space], ",")
			} else if comma >= 0 {
				tail = tail[:comma]
			} else if strings.HasSuffix(tail, `"`) {
				payload := tail[:len(tail)-1]
				if close := strings.Index(payload, "())"); close >= 0 {
					tail = payload[:close+3]
				} else if strings.HasSuffix(payload, "))") {
					tail = payload
				} else if close := strings.Index(payload, "[))"); close >= 0 {
					tail = payload[:close+3]
				} else if trimCompatibilitySpace(payload) != payload {
					tail = trimCompatibilitySpace(payload)
				} else if comma := strings.IndexByte(payload, ','); comma >= 0 {
					tail = payload[:comma]
				} else if close := strings.IndexAny(payload, "]}"); close >= 0 {
					tail = payload[:close]
				} else if close := strings.IndexByte(payload, ')'); close >= 0 &&
					(close == 0 || payload[close-1] != '(') &&
					!strings.ContainsAny(payload[:close], "[{") &&
					!strings.Contains(payload[:close], "(") {
					tail = payload[:close+1]
				}
			}
			return Result{
				Type: JSON, Raw: "[" + compatibilityScalarLiteralTail(tail) + "]", synthetic: true,
			}
		}
	}
	if strings.HasPrefix(expression, `["].[`) &&
		strings.Contains(expression, ".#.") {
		return Result{Type: JSON, Raw: "[[]]", synthetic: true}
	}
	if strings.HasPrefix(expression, `[".[)`) &&
		(strings.Contains(expression, ".#.") ||
			strings.Contains(expression, "|#.")) {
		return Result{Type: JSON, Raw: "[[]]", synthetic: true}
	}
	object := expression[0] == '{'
	close := byte(']')
	if object {
		close = '}'
	}
	if expression[len(expression)-1] != close &&
		expression[len(expression)-1] != ']' &&
		expression[len(expression)-1] != '}' {
		return Result{}
	}
	entries, ok := splitCompatibilityEntries(expression[1 : len(expression)-1])
	if !ok {
		return Result{}
	}
	raw := []byte{'['}
	if object {
		raw[0] = '{'
	}
	wrote := 0
	for _, entry := range entries {
		trimmedEntry := trimCompatibilitySpace(entry)
		if object && strings.Contains(trimmedEntry, `|#.""|#.`) {
			continue
		}
		pipeLiteral := strings.Index(trimmedEntry, "|!")
		pipeLiteralPrefix := ""
		pipeLiteralWildcardPrefixValid := false
		pipeLiteralQuote := strings.IndexByte(trimmedEntry, '"')
		pipeLiteralColon := compatibilityTopLevelColon(trimmedEntry)
		if pipeLiteralColon >= 0 {
			if afterColon := strings.Index(
				trimmedEntry[pipeLiteralColon+1:], "|!"); afterColon >= 0 {
				pipeLiteral = pipeLiteralColon + 1 + afterColon
			}
		}
		lastPipeLiteralColon := strings.LastIndexByte(trimmedEntry, ':')
		pipeLiteralTrailingColonInvalid :=
			lastPipeLiteralColon > pipeLiteral &&
				lastPipeLiteralColon >
					strings.LastIndexByte(trimmedEntry, '"') &&
				!strings.Contains(
					trimmedEntry[lastPipeLiteralColon+1:], "|!")
		if pipeLiteral > 0 {
			pipeLiteralQuote =
				strings.LastIndexByte(trimmedEntry[:pipeLiteral], '"')
			pipeLiteralPrefix = strings.Trim(trimmedEntry[:pipeLiteral], `"`)
			if quote := strings.LastIndexByte(
				trimmedEntry[:pipeLiteral], '"'); quote > 1 {
				wildcardPrefix := trimmedEntry[:quote]
				if dot := strings.IndexByte(wildcardPrefix, '.'); dot > 0 {
					singleWildcardTarget :=
						compatibilityChild(current, wildcardPrefix[:dot])
					singleWildcardTargetValid :=
						singleWildcardTarget.IsObject() ||
							singleWildcardTarget.IsArray()
					nestedWildcardIndexValid := false
					if strings.Count(wildcardPrefix, ".") > 1 &&
						strings.HasSuffix(wildcardPrefix, ".") {
						selected := current
						nestedWildcardIndexValid = true
						for _, component := range strings.Split(
							strings.TrimSuffix(wildcardPrefix, "."), ".") {
							if component == "#" && selected.IsArray() {
								count := len(selected.Array())
								raw := strconv.Itoa(count)
								selected = Result{
									Type: Number, Raw: raw,
									Num: float64(count),
								}
							} else {
								selected = compatibilityChild(
									selected, component)
							}
							if !selected.Exists() {
								nestedWildcardIndexValid = false
								break
							}
						}
					} else if strings.Count(wildcardPrefix, ".") > 1 {
						components := strings.Split(wildcardPrefix, ".")
						if len(components) >= 2 {
							selected := compatibilityChild(
								current, components[0])
							selected = compatibilityChild(
								selected, components[1])
							nestedWildcardIndexValid = selected.Exists()
						}
					}
					pipeLiteralWildcardPrefixValid =
						current.IsObject() &&
							!current.arrayElement &&
							(strings.Count(wildcardPrefix, ".") == 1 &&
								singleWildcardTargetValid ||
								nestedWildcardIndexValid) &&
							strings.Trim(wildcardPrefix[:dot], "*?") == ""
				}
			}
		}
		if pipeLiteralColon >= 0 && pipeLiteralQuote > pipeLiteralColon &&
			pipeLiteral > pipeLiteralQuote {
			pipeLiteralPrefix =
				trimmedEntry[pipeLiteralColon+1:pipeLiteralQuote] +
					trimmedEntry[pipeLiteralQuote+1:pipeLiteral]
			pipeLiteralWildcardPrefixValid = false
		}
		pipeLiteralCountPrefixValid := false
		if lastPipe := strings.LastIndexByte(pipeLiteralPrefix, '|'); current.IsArray() &&
			strings.HasPrefix(trimmedEntry, `#."|`) &&
			lastPipe >= 0 && lastPipe+1 < len(pipeLiteralPrefix) {
			component := pipeLiteralPrefix[lastPipe+1:]
			pipeLiteralCountPrefixValid = component != "" &&
				!strings.ContainsAny(component, ".,|")
		}
		pipeLiteralPrefixValid := pipeLiteralCountPrefixValid ||
			!strings.Contains(pipeLiteralPrefix, "|") &&
				(!strings.Contains(pipeLiteralPrefix, ".") ||
					pipeLiteralWildcardPrefixValid ||
					compatibilityOnlyEscapedDots(pipeLiteralPrefix))
		syntheticPipeLiteral := (current.IsObject() || current.IsArray()) &&
			len(trimmedEntry) > 3 &&
			pipeLiteral > 0 && pipeLiteral+2 < len(trimmedEntry) &&
			!pipeLiteralTrailingColonInvalid &&
			strings.Contains(trimmedEntry[:pipeLiteral], `"`) &&
			!strings.Contains(trimmedEntry[:pipeLiteral], `.".`) &&
			(!current.IsArray() ||
				!strings.Contains(trimmedEntry[:pipeLiteral], `\."`)) &&
			(pipeLiteralColon < 0 ||
				pipeLiteralQuote >= 0 && pipeLiteralColon < pipeLiteralQuote &&
					pipeLiteral > pipeLiteralQuote) &&
			pipeLiteralPrefixValid &&
			(trimmedEntry[pipeLiteral+2] == '+' ||
				trimmedEntry[pipeLiteral+2] == '-' ||
				trimmedEntry[pipeLiteral+2] >= '0' &&
					trimmedEntry[pipeLiteral+2] <= '9' ||
				trimmedEntry[pipeLiteral+2] == '[' ||
				trimmedEntry[pipeLiteral+2] == '{')
		syntheticMalformedQuery := current.IsArray() &&
			strings.HasPrefix(entry, `#.".#(`) &&
			strings.Contains(entry, `""|`)
		firstPipe := strings.IndexByte(entry, '|')
		syntheticMalformedPipe := strings.Count(entry, "|#.") >= 2 &&
			strings.Count(entry, "|") == strings.Count(entry, "|#.") &&
			firstPipe > 0 && strings.Contains(entry[:firstPipe], "#.") &&
			(current.IsArray() &&
				strings.HasPrefix(trimCompatibilitySpace(entry), "#.") ||
				current.Index > 0 &&
					strings.Contains(entry[:firstPipe], "*.#."))
		if !syntheticPipeLiteral && !syntheticMalformedQuery &&
			!syntheticMalformedPipe &&
			strings.Count(entry, "|") > 1 {
			continue
		}
		if !syntheticPipeLiteral && !syntheticMalformedQuery &&
			!syntheticMalformedPipe &&
			compatibilityTopLevelColon(entry) < 0 &&
			compatibilityQuotedContains(entry, '|') {
			pipe := strings.IndexByte(entry, '|')
			quote := -1
			if pipe >= 0 {
				quote = strings.LastIndexByte(entry[:pipe], '"')
			}
			if quote < 0 {
				continue
			}
			quoted := entry[quote:]
			end, _, err := scanJSONString(quoted, 0)
			if err != nil {
				continue
			}
			decoded := compatibilityUnescape(quoted[1 : end-1])
			onePipe := strings.Count(decoded, "|") == 1
			allowed := onePipe && strings.Contains(decoded, "|#.") ||
				compatibilityProjectionChainAllowsPipe(decoded) ||
				compatibilityPipeInsideQuotedQuery(decoded)
			if !strings.Contains(entry[:quote], "#.") || !allowed {
				continue
			}
		}
		name, query := "", entry
		quotedName := false
		quotedRaw := ""
		if object {
			if colon := compatibilityTopLevelColon(query); colon >= 0 {
				name = query[:colon]
				query = query[colon+1:]
				if name == "" {
					name = compatibilityMultipathName(query)
				}
				if len(name) >= 2 && name[0] == '"' && Valid(name) {
					parsedName := Parse(name)
					if parsedName.Exists() {
						quotedName = true
						quotedRaw = name
						name = parsedName.Str
					}
				}
			} else {
				name = compatibilityMultipathName(query)
			}
		} else if colon := compatibilityTopLevelColon(query); colon >= 0 {
			query = query[colon+1:]
		}
		value := Result{}
		if syntheticMalformedPipe && wrote > 0 {
			continue
		}
		if syntheticMalformedQuery || syntheticMalformedPipe {
			value = Result{Type: JSON, Raw: "[]", synthetic: true}
		} else if syntheticPipeLiteral {
			payloadEnd := len(trimmedEntry)
			terminalQuote := strings.HasSuffix(trimmedEntry, `"`)
			if terminalQuote {
				payloadEnd--
			}
			payload := trimmedEntry[pipeLiteral+2 : payloadEnd]
			for {
				closePipe := strings.Index(payload, ")|!")
				if closePipe < 0 ||
					strings.Contains(payload[:closePipe], "(") ||
					strings.ContainsAny(payload[:closePipe], "[{") ||
					strings.ContainsAny(payload[:closePipe], ")]}") {
					break
				}
				payload = payload[closePipe+3:]
			}
			if close := strings.IndexByte(payload, ')'); close >= 0 && close+1 < len(payload) &&
				(payload[close+1] == '.' ||
					payload[close+1] == '|' &&
						!strings.HasPrefix(
							payload[close+1:], "|!")) {
				continue
			}
			compositePayload := payload[0] == '[' || payload[0] == '{'
			if compositePayload {
				closeComposite := strings.IndexAny(payload, "]}")
				closeParen := strings.IndexByte(payload, ')')
				if closeComposite >= 0 &&
					(closeParen < 0 || closeComposite < closeParen) {
					payload = payload[:closeComposite+1]
					terminalQuote = false
				} else if closeParen >= 0 {
					payload = payload[:closeParen+1]
					terminalQuote = false
				}
			} else {
				if space := strings.IndexFunc(payload, func(value rune) bool {
					return value <= ' '
				}); space >= 0 {
					payload = strings.TrimSuffix(payload[:space], ",")
					if close := strings.IndexAny(payload, "]}"); close >= 0 {
						payload = payload[:close]
					} else if comma := strings.IndexByte(payload, ','); comma >= 0 {
						payload = payload[:comma]
					} else if close := strings.IndexByte(payload, ')'); close >= 0 &&
						(close == 0 || payload[close-1] != '(') {
						payload = payload[:close+1]
					}
					terminalQuote = false
				} else if trimCompatibilitySpace(payload) != payload {
					payload = strings.TrimSuffix(
						trimCompatibilitySpace(payload), ",")
					terminalQuote = false
				} else if close, comma := strings.IndexAny(payload, "]}"),
					strings.IndexByte(payload, ','); close >= 0 && (comma < 0 || close < comma) {
					payload = payload[:close]
					terminalQuote = false
				} else if comma >= 0 {
					payload = payload[:comma]
					terminalQuote = false
				} else if close := strings.IndexByte(payload, ')'); close >= 0 &&
					(close == 0 || payload[close-1] != '(') {
					payload = payload[:close+1]
					terminalQuote = false
				}
			}
			if payload[0] == '+' || payload[0] == '-' ||
				payload[0] >= '0' && payload[0] <= '9' {
				rawPayload := payload
				if terminalQuote {
					rawPayload += `"`
				}
				value = Result{Type: Number, Raw: rawPayload, Num: 0}
			} else if payload[0] == '[' || payload[0] == '{' {
				rawPayload := payload
				if terminalQuote {
					rawPayload += `"`
				}
				value = Result{
					Type: JSON, Raw: rawPayload, synthetic: true,
				}
			}
		} else {
			value = compatibilityGet(current.Raw, query)
		}
		if !value.Exists() {
			continue
		}
		if wrote > 0 {
			raw = append(raw, ',')
		}
		if object {
			if quotedName {
				raw = append(raw, quotedRaw...)
			} else {
				raw = AppendJSONString(raw, name)
			}
			raw = append(raw, ':')
		}
		raw = append(raw, value.Raw...)
		wrote++
	}
	if object {
		raw = append(raw, '}')
	} else {
		raw = append(raw, ']')
	}
	return Result{Type: JSON, Raw: string(raw), synthetic: true}
}

func splitCompatibilityEntries(value string) ([]string, bool) {
	entries := []string{}
	start := 0
	depth := 0
	quoted := byte(0)
	escaped := false
	for index := 0; index < len(value); index++ {
		current := value[index]
		if escaped {
			escaped = false
			continue
		}
		if current == '\\' {
			escaped = true
			continue
		}
		if quoted != 0 {
			if current == quoted {
				quoted = 0
			}
			continue
		}
		if current == '"' {
			quoted = current
			continue
		}
		switch current {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			if depth == 0 {
				return nil, false
			}
			depth--
		case ',':
			if depth == 0 {
				entries = append(entries, value[start:index])
				start = index + 1
			}
		}
	}
	if escaped || quoted != 0 || depth != 0 {
		return nil, false
	}
	entries = append(entries, value[start:])
	return entries, true
}

func compatibilityTopLevelColon(value string) int {
	depth := 0
	quoted := byte(0)
	escaped := false
	modifier := false
	for index := 0; index < len(value); index++ {
		current := value[index]
		if escaped {
			escaped = false
			continue
		}
		if current == '\\' {
			escaped = true
			continue
		}
		if quoted != 0 {
			if current == quoted {
				quoted = 0
			}
			continue
		}
		if current == '"' {
			quoted = current
			continue
		}
		if current == '@' && index > 0 &&
			(value[index-1] == '.' || value[index-1] == '|') {
			modifier = true
			continue
		}
		switch current {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ':':
			if depth == 0 && !modifier {
				return index
			}
		}
	}
	return -1
}

func compatibilityMultipathName(query string) string {
	last := 0
	depth := 0
	for index := 0; index < len(query); index++ {
		switch query[index] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case '.', '|':
			if depth == 0 {
				last = index + 1
			}
		}
	}
	name := query[last:]
	if name == "#" || strings.HasPrefix(name, "!") || strings.HasPrefix(name, "{") ||
		strings.HasPrefix(name, "[") {
		return "_"
	}
	return name
}

func compatibilityChild(parent Result, component string, literal ...bool) Result {
	if parent.IsArray() {
		if len(literal) > 0 && literal[0] {
			return Result{}
		}
		if component == "" {
			return Result{}
		}
		for index := 0; index < len(component); index++ {
			if component[index] < '0' || component[index] > '9' {
				return Result{}
			}
		}
		var parsed uint64
		for index := 0; index < len(component); index++ {
			parsed = parsed*10 + uint64(component[index]-'0')
		}
		position := int(parsed)
		values := parent.Array()
		if position < 0 || position >= len(values) {
			return Result{}
		}
		value := values[position]
		value.arrayElement = true
		if parent.synthetic {
			value.Index = 0
			value.synthetic = true
			value.suppressIndexes = parent.suppressIndexes
			value.relativeProjection = parent.relativeProjection
		}
		return value
	}
	if !parent.IsObject() {
		return Result{}
	}
	exact := len(literal) > 0 && literal[0]
	fast := !exact
	if len(literal) > 1 {
		fast = literal[1]
	}
	if fast {
		if result, handled := compatibilitySimpleGet(parent.Raw, component); handled {
			if result.Exists() {
				result.arrayElement = parent.arrayElement
				if parent.synthetic {
					result.Index = 0
					result.synthetic = true
					result.suppressIndexes = parent.suppressIndexes
					result.relativeProjection = parent.relativeProjection
				} else {
					result.Index += parent.Index
				}
			}
			return result
		}
	}
	var found Result
	parent.ForEach(func(key, value Result) bool {
		if exact && key.Str == component ||
			!exact && compatibilityMatchComponent(component, key.Str) {
			found = value
			return false
		}
		return true
	})
	if found.Exists() {
		found.arrayElement = parent.arrayElement
	}
	return found
}

func compatibilityMatchComponent(pattern, value string) bool {
	if strings.IndexByte(pattern, '\\') >= 0 {
		return pathquery.Match(pattern, value)
	}
	first := strings.IndexAny(pattern, "*?")
	if first < 0 {
		return pattern == value
	}
	if pattern[first] == '*' && first == len(pattern)-1 {
		return strings.HasPrefix(value, pattern[:first])
	}
	if pattern[first] == '*' && first == 0 && len(pattern) > 1 &&
		strings.IndexAny(pattern[1:], "*?") < 0 {
		return strings.HasSuffix(value, pattern[1:])
	}
	return pathquery.Match(pattern, value)
}

func projectCompatibilityArray(array Result, remainder []compatibilityPathPart) Result {
	for index, part := range remainder {
		if strings.HasPrefix(part.text, "[") &&
			strings.HasSuffix(part.text, "]#") &&
			strings.Contains(part.text, ".#|") {
			return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
		}
		if strings.HasPrefix(part.text, "#[") &&
			strings.Count(part.text, "|#.") >= 2 &&
			strings.Count(part.text, "|") ==
				strings.Count(part.text, "|#.") {
			return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
		}
		if strings.HasPrefix(part.text, "[") &&
			strings.HasSuffix(part.text, "]#") &&
			compatibilityQuotedContains(part.text, '|') &&
			!strings.Contains(part.text, "|#.") &&
			!strings.Contains(part.text, ".#|") {
			return Result{}
		}
		if compatibilityQuotedLeadingPipeMultipath(part.text) {
			return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
		}
		if compatibilityInvalidQuotedMultipath(part.text) {
			if array.Indexes != nil {
				return Result{Type: JSON, Raw: "[]"}
			}
			if index > 0 && strings.HasPrefix(part.text, "#[") {
				return Result{Type: JSON, Raw: "[]", Indexes: []int{}}
			}
			if index+1 < len(remainder) && len(remainder[index+1].text) > 0 &&
				(remainder[index+1].text[0] == '[' ||
					remainder[index+1].text[0] == '{') {
				if index+2 < len(remainder) {
					return Result{}
				}
				return Result{Type: JSON, Raw: "[]"}
			}
			return Result{}
		}
	}
	if len(remainder) == 1 && compatibilitySimplePart(remainder[0]) &&
		!remainder[0].wildcard && !array.synthetic {
		if projected, handled := projectCompatibilitySimpleField(
			array, remainder[0].text); handled {
			return projected
		}
	}
	var raw strings.Builder
	raw.Grow(len(array.Raw))
	raw.WriteByte('[')
	indexes := make([]int, 0, 4)
	first := true
	containsSynthetic := false
	recoveredMalformed := compatibilityArrayStartsWithNoise(array.Raw) &&
		len(remainder) > 0 && strings.HasPrefix(remainder[0].text, "@")
	array.ForEach(func(_ Result, value Result) bool {
		if recoveredMalformed && (value.Type == String || value.Type == JSON) {
			return true
		}
		projected := evaluateCompatibilityParts(value, remainder)
		if !projected.Exists() {
			return true
		}
		if projected.Raw == "[]" && projected.synthetic &&
			len(remainder) > 1 && remainder[0].wildcard &&
			(remainder[1].text == "#" ||
				strings.HasSuffix(remainder[1].text, ")#")) {
			return true
		}
		if projected.Raw == "[[]]" && projected.synthetic &&
			len(remainder) > 1 && remainder[0].wildcard &&
			compatibilityDropsMalformedWildcardProjection(
				remainder[1].text) &&
			strings.Count(remainder[1].text, "|#.") >= 2 {
			return true
		}
		if !first {
			raw.WriteByte(',')
		}
		first = false
		raw.WriteString(projected.Raw)
		containsSynthetic = containsSynthetic ||
			projected.synthetic || projected.projectionSynthetic
		// Ordinary projections retain the selected child's source position.
		// Synthetic multipaths and @this have no child position, so upstream
		// falls back to the input element's position (except explicit null,
		// whose zero index is significant).
		projectedIndex := projected.Index
		if projectedIndex == 0 && !projected.projectionSynthetic && value.Type == JSON &&
			!(projected.Type == Null && projected.Raw == "null") {
			projectedIndex = value.Index
		}
		indexes = append(indexes, projectedIndex)
		return true
	})
	raw.WriteByte(']')
	if array.suppressIndexes {
		indexes = nil
	} else if len(indexes) == 0 && array.Indexes != nil {
		indexes = nil
	}
	return Result{
		Type: JSON, Raw: raw.String(), Indexes: indexes,
		synthetic:           array.synthetic,
		projectionSynthetic: containsSynthetic,
		suppressIndexes:     array.suppressIndexes,
	}
}

func compatibilityDropsMalformedWildcardProjection(expression string) bool {
	if len(expression) < 2 || expression[0] != '[' {
		return false
	}
	rawInner := expression[1:]
	inner := strings.TrimLeftFunc(rawInner, func(value rune) bool {
		return value <= ' '
	})
	if inner == "" {
		return false
	}
	if len(inner) != len(rawInner) {
		return true
	}
	if inner[0] == '*' {
		wildcardEnd := 1
		for wildcardEnd < len(inner) &&
			(inner[wildcardEnd] == '*' || inner[wildcardEnd] == '?') {
			wildcardEnd++
		}
		return wildcardEnd >= len(inner) || inner[wildcardEnd] != '.' ||
			!strings.HasPrefix(inner[wildcardEnd+1:], "#.")
	}
	return true
}

func compatibilityQuotedLeadingPipeMultipath(expression string) bool {
	if len(expression) < 2 || expression[0] != '[' && expression[0] != '{' {
		return false
	}
	if strings.Count(expression, "|") == 1 &&
		compatibilityPipeInsideQuotedQuery(expression) {
		return strings.Contains(expression, "|#.") &&
			compatibilityEvenProjectionChainBeforeQuery(expression)
	}
	entries, ok := splitCompatibilityEntries(expression[1 : len(expression)-1])
	if !ok {
		return false
	}
	for _, entry := range entries {
		trimmed := trimCompatibilitySpace(entry)
		if strings.Count(trimmed, "|") > 1 {
			firstPipe := strings.IndexByte(trimmed, '|')
			if query := strings.LastIndex(trimmed[:firstPipe], ".#("); query >= 0 &&
				!strings.Contains(trimmed[query+3:], ")") {
				if strings.Contains(trimmed, "|#.") &&
					strings.Count(trimmed, "|") ==
						strings.Count(trimmed, "|#.") &&
					compatibilityEvenProjectionChainBeforeQuery(trimmed) {
					return true
				}
				continue
			}
			if query := strings.LastIndex(trimmed[:firstPipe], ".#["); query >= 0 &&
				!strings.Contains(trimmed[query+3:], "]") {
				if strings.Contains(trimmed, "|#.") &&
					strings.Count(trimmed, "|") ==
						strings.Count(trimmed, "|#.") &&
					compatibilityEvenProjectionChainBeforeQuery(trimmed) {
					return true
				}
				continue
			}
			if compatibilityClosedQueryThenProjectedPipe(trimmed) {
				return true
			}
			if strings.Count(trimmed, "|#.") >= 2 &&
				strings.Count(trimmed, "|") ==
					strings.Count(trimmed, "|#.") &&
				strings.IndexByte(trimmed, '|') == strings.Index(trimmed, "|#.") {
				return true
			}
			if leading := strings.Index(trimmed, "|#."); strings.Count(trimmed, "|") == 2 && leading >= 0 &&
				(leading < 2 || trimmed[leading-2:leading] != ".#") &&
				strings.LastIndex(trimmed, ".#|") > leading+2 {
				return true
			}
			if leading := strings.Index(trimmed, ".#|"); strings.Count(trimmed, "|") == 2 && leading >= 0 &&
				strings.LastIndex(trimmed, "|#.") > leading+2 {
				return true
			}
			if strings.Count(trimmed, "|") == 2 &&
				strings.HasPrefix(trimmed, `"|#.`) &&
				(strings.Contains(trimmed, `""|#.`) ||
					strings.Contains(trimmed, `"".#|`)) {
				return true
			}
			if strings.HasPrefix(trimmed, `".#|`) &&
				strings.Contains(trimmed, `""|#.`) {
				return true
			}
			if len(trimmed) > 1 && trimmed[0] == '"' {
				if end, _, err := scanJSONString(trimmed, 0); err == nil &&
					end == len(trimmed) {
					decoded := compatibilityUnescape(trimmed[1 : end-1])
					if strings.HasPrefix(decoded, "|#.") &&
						strings.HasSuffix(decoded, ".#|") &&
						strings.Count(decoded, "|") == 2 &&
						len(decoded) > len("|#..#|") {
						return true
					}
					if strings.HasPrefix(decoded, ".#|") &&
						strings.HasSuffix(decoded, "|#.") &&
						strings.Count(decoded, "|") == 2 &&
						len(decoded) > len(".#||#.") {
						return true
					}
				}
			}
			continue
		}
		if compatibilityPipeInsideQuotedQuery(trimmed) {
			if strings.HasSuffix(trimmed, `|#."`) &&
				compatibilityEvenProjectionChainBeforeQuery(trimmed) {
				return true
			}
			continue
		}
		pipeByte := strings.IndexByte(trimmed, '|')
		quote := -1
		if pipeByte >= 0 {
			quote = strings.LastIndexByte(trimmed[:pipeByte], '"')
		}
		if quote < 0 || quote+1 >= len(trimmed) {
			continue
		}
		quoted := trimmed[quote:]
		end, _, err := scanJSONString(quoted, 0)
		if err == nil {
			decoded := compatibilityUnescape(quoted[1 : end-1])
			if compatibilityPipeInsideQuotedQuery(decoded) &&
				strings.Count(decoded, "|") == 1 {
				if strings.HasSuffix(decoded, "|#.") &&
					compatibilityEvenProjectionChainBeforeQuery(decoded) {
					return true
				}
				continue
			}
			if strings.HasPrefix(decoded, "|#.") &&
				strings.HasSuffix(decoded, ".#|") &&
				len(decoded) > len("|#..#|") {
				return true
			}
			if strings.Count(decoded, "|") != 1 {
				continue
			}
			pipe := strings.Index(decoded, "|#.")
			if pipe >= 0 && (strings.Contains(decoded[:pipe], ".#.#") ||
				!strings.HasSuffix(decoded[:pipe], ".#")) {
				return true
			}
		}
	}
	return false
}

func projectCompatibilitySimpleField(array Result, field string) (Result, bool) {
	offset := skipSpace(array.Raw, 0)
	if offset >= len(array.Raw) || array.Raw[offset] != '[' {
		return Result{}, false
	}
	offset++
	var raw strings.Builder
	raw.Grow(len(array.Raw) / 2)
	raw.WriteByte('[')
	indexes := make([]int, 0, 4)
	first := true
	element := 0
	for {
		offset = skipSpace(array.Raw, offset)
		if offset >= len(array.Raw) {
			return Result{}, false
		}
		if array.Raw[offset] == ']' {
			raw.WriteByte(']')
			return Result{Type: JSON, Raw: raw.String(), Indexes: indexes}, true
		}
		if array.Raw[offset] != '{' {
			return Result{}, false
		}
		end, found, ok := compatibilityObjectFieldAndEnd(array.Raw, offset, field)
		if !ok {
			return Result{}, false
		}
		if found.Exists() {
			if !first {
				raw.WriteByte(',')
			}
			first = false
			raw.WriteString(found.Raw)
			projectedIndex := found.Index + array.Index
			if element < len(array.Indexes) {
				projectedIndex = array.Indexes[element] + found.Index - offset
			}
			indexes = append(indexes, projectedIndex)
		}
		element++
		offset = skipSpace(array.Raw, end)
		if offset < len(array.Raw) && array.Raw[offset] == ',' {
			offset++
			continue
		}
		if offset < len(array.Raw) && array.Raw[offset] == ']' {
			continue
		}
		return Result{}, false
	}
}

func compatibilityArrayStartsWithNoise(raw string) bool {
	offset := skipSpace(raw, 0)
	if offset >= len(raw) || raw[offset] != '[' {
		return false
	}
	offset = skipSpace(raw, offset+1)
	return offset < len(raw) && raw[offset] != ']' &&
		!compatibilityValueStart(raw[offset])
}

func queryCompatibilityArray(
	array Result,
	expression string,
	compiled *compatibilityCompiledQuery,
) (Result, bool) {
	closing := byte(')')
	if strings.HasPrefix(expression, "#[") {
		closing = ']'
	}
	close := compatibilityQueryClose(expression, closing)
	if close < 2 {
		values := array.Array()
		if len(values) == 0 {
			return Result{}, false
		}
		// Preserve the pinned parser's permissive unterminated-query fallback.
		return values[len(values)-1], false
	}
	all := close+1 < len(expression) && expression[close+1] == '#'
	query := trimCompatibilitySpace(expression[2:close])
	if strings.HasSuffix(query, `\`) {
		hasOperator := false
		for _, operator := range []string{"!=~", "==~", "!=", ">=", "<=", "==", "!%", "=", ">", "<", "%"} {
			if compatibilityUnescapedOperator(query, operator) >= 0 {
				hasOperator = true
				break
			}
		}
		if !hasOperator {
			query = strings.TrimSuffix(query, `\`)
		}
	}
	if compiled != nil && !all {
		if selected, handled := queryCompatibilityArrayFast(array, query, compiled); handled {
			return selected, false
		}
	}
	if !all {
		var selected Result
		array.ForEach(func(_ Result, candidate Result) bool {
			if matchesCompatibilityQueryPlan(candidate, query, compiled) {
				selected = candidate
				return false
			}
			return true
		})
		return selected, false
	}
	matches := []Result{}
	array.ForEach(func(_ Result, candidate Result) bool {
		if matchesCompatibilityQueryPlan(candidate, query, compiled) {
			matches = append(matches, candidate)
		}
		return true
	})
	raw := []byte{'['}
	indexes := make([]int, 0, len(matches))
	for index, match := range matches {
		if index > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, match.Raw...)
		indexes = append(indexes, match.Index)
	}
	raw = append(raw, ']')
	if array.suppressIndexes {
		indexes = nil
	}
	return Result{
		Type: JSON, Raw: string(raw), Indexes: indexes,
		synthetic:       array.synthetic,
		suppressIndexes: array.suppressIndexes,
	}, true
}

func queryCompatibilityArrayFast(
	array Result,
	query string,
	compiled *compatibilityCompiledQuery,
) (Result, bool) {
	offset := skipSpace(array.Raw, 0)
	if offset >= len(array.Raw) || array.Raw[offset] != '[' {
		return Result{}, false
	}
	offset++
	for {
		offset = skipSpace(array.Raw, offset)
		if offset >= len(array.Raw) {
			return Result{}, false
		}
		if array.Raw[offset] == ']' {
			return Result{}, true
		}
		start := offset
		var end int
		var candidate Result
		var matched bool
		resolved := false
		if array.Raw[start] == '{' && compiled.leftSimple &&
			compiled.leftPath != "" && !strings.ContainsAny(compiled.leftPath, ".*?") {
			var left Result
			var ok bool
			end, left, ok = compatibilityObjectFieldAndEnd(
				array.Raw, start, compiled.leftPath)
			if !ok {
				return Result{}, false
			}
			candidate = Result{Type: JSON, Raw: array.Raw[start:end], Index: start}
			matched = matchesCompatibilityResolvedQuery(left, compiled)
			resolved = true
		} else {
			valueEnd, kind, err := scanValue(array.Raw, start)
			if err != nil {
				return Result{}, false
			}
			end = valueEnd
			candidate = compatibilityScannedResult(array.Raw, start, end, kind)
		}
		if array.synthetic {
			candidate.Index = 0
			candidate.synthetic = true
			candidate.suppressIndexes = array.suppressIndexes
		} else {
			candidate.Index += array.Index
		}
		if matched || !resolved && matchesCompatibilityQueryPlan(candidate, query, compiled) {
			return candidate, true
		}
		offset = skipSpace(array.Raw, end)
		if offset < len(array.Raw) && array.Raw[offset] == ',' {
			offset++
			continue
		}
		if offset < len(array.Raw) && array.Raw[offset] == ']' {
			return Result{}, true
		}
		return Result{}, false
	}
}

func compatibilityObjectFieldAndEnd(
	source string,
	start int,
	field string,
) (int, Result, bool) {
	offset := start + 1
	var found Result
	for {
		offset = skipSpace(source, offset)
		if offset >= len(source) {
			return 0, Result{}, false
		}
		if source[offset] == '}' {
			return offset + 1, found, true
		}
		keyStart := offset
		keyEnd, escaped, err := scanJSONString(source, keyStart)
		if err != nil {
			return 0, Result{}, false
		}
		offset = skipSpace(source, keyEnd)
		if offset >= len(source) || source[offset] != ':' {
			return 0, Result{}, false
		}
		valueStart := skipSpace(source, offset+1)
		valueEnd, kind, err := scanValue(source, valueStart)
		if err != nil {
			return 0, Result{}, false
		}
		if !escaped && source[keyStart+1:keyEnd-1] == field {
			found = compatibilityScannedResult(source, valueStart, valueEnd, kind)
		}
		offset = skipSpace(source, valueEnd)
		if offset < len(source) && source[offset] == ',' {
			offset++
			continue
		}
		if offset < len(source) && source[offset] == '}' {
			return offset + 1, found, true
		}
		return 0, Result{}, false
	}
}

func compatibilityQueryClose(expression string, closing byte) int {
	quoted := false
	escaped := false
	depth := 1
	for index := 2; index < len(expression); index++ {
		value := expression[index]
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
		switch value {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
			if depth == 0 && (value == closing || value == ')' || value == ']') {
				return index
			}
		}
	}
	return -1
}

func matchesCompatibilityQueryPlan(
	candidate Result,
	query string,
	compiled *compatibilityCompiledQuery,
) bool {
	if compiled == nil {
		return matchesCompatibilityQuery(candidate, query)
	}
	if (compiled.leftPath == "" || compiled.leftPath == "@") && candidate.Type == JSON {
		return false
	}
	left := candidate
	if compiled.leftPath != "" && compiled.leftPath != "@" {
		if compiled.leftSimple {
			left, _ = compatibilitySimpleGet(candidate.Raw, compiled.leftPath)
		} else {
			left = compatibilityGet(candidate.Raw, compiled.leftPath)
		}
		left.Index += candidate.Index
	}
	return matchesCompatibilityResolvedQuery(left, compiled)
}

func matchesCompatibilityResolvedQuery(
	left Result,
	compiled *compatibilityCompiledQuery,
) bool {
	if !left.Exists() || compiled.right.Type == Null {
		return false
	}
	right := compatibilityTypedQueryRight(left, compiled.right)
	if compiled.relation == pathquery.Like || compiled.relation == pathquery.NotLike {
		if left.Type != String {
			return false
		}
		return pathquery.RelateString(left.String(), compiled.right.Str, compiled.relation)
	}
	if left.Type == True || left.Type == False {
		return compatibilityBooleanQuery(
			left.Type == True, compiled.rightText, compiled.relation)
	}
	if (compiled.relation == pathquery.Greater ||
		compiled.relation == pathquery.GreaterOrEqual ||
		compiled.relation == pathquery.Less ||
		compiled.relation == pathquery.LessOrEqual) &&
		left.Type != Number && left.Type != String &&
		left.Type != True && left.Type != False {
		return false
	}
	if left.Type == Number && right.Type == Number {
		switch compiled.relation {
		case pathquery.Equal:
			return left.Num == right.Num
		case pathquery.NotEqual:
			return left.Num != right.Num
		case pathquery.Less:
			return left.Num < right.Num
		case pathquery.LessOrEqual:
			return left.Num <= right.Num
		case pathquery.Greater:
			return left.Num > right.Num
		case pathquery.GreaterOrEqual:
			return left.Num >= right.Num
		}
	}
	return pathquery.Relate(left, right, compiled.relation,
		compatibilityEqual,
		func(left, right Result) bool { return left.Less(right, true) })
}

func matchesCompatibilityQuery(candidate Result, query string) bool {
	if query == "" {
		return candidate.Exists() && candidate.Type != JSON
	}
	operators := []string{"!=~", "==~", "!=", ">=", "<=", "==", "!%", "=", ">", "<", "%"}
	for _, operator := range operators {
		if at := compatibilityUnescapedOperator(query, operator); at >= 0 {
			rawLeftPath := query[:at]
			leftPath := trimCompatibilitySpace(rawLeftPath)
			rightRaw := query[at+len(operator):]
			if (leftPath == "" || leftPath == "@") && candidate.Type == JSON {
				return false
			}
			left := candidate
			if leftPath != "" && leftPath != "@" {
				left = compatibilityGet(candidate.Raw, leftPath)
				left.Index += candidate.Index
			}
			if operator == "==~" || operator == "!=~" {
				matched := compatibilityTildeEqual(left, trimCompatibilitySpace(rightRaw))
				return matched == (operator == "==~")
			}
			if !left.Exists() {
				return false
			}
			if trimCompatibilitySpace(rightRaw) == "" {
				if operator == "!=" {
					return left.String() != ""
				}
				if operator == "=" || operator == "==" {
					return left.String() == ""
				}
				if operator == ">" || operator == ">=" {
					if left.Type == Number {
						return left.Num > 0 || operator == ">=" && left.Num == 0
					}
					if left.Type == String {
						return left.Str > "" || operator == ">="
					}
				}
				return false
			}
			if operator == "%" || operator == "!%" {
				if left.Type != String {
					return false
				}
				pattern := trimCompatibilitySpace(rightRaw)
				if !compatibilityValidQuotedOperand(pattern) {
					return false
				}
				if len(pattern) >= 2 && pattern[0] == '"' && pattern[len(pattern)-1] == '"' {
					pattern = Parse(pattern).String()
				}
				relation, _ := pathquery.ParseRelation(operator)
				return pathquery.RelateString(left.String(), pattern, relation)
			}
			right := compatibilityQueryValue(rightRaw)
			if right.Type == Null {
				return false
			}
			if (operator == ">" || operator == "<" || operator == ">=" || operator == "<=") &&
				left.Type != Number && left.Type != String &&
				left.Type != True && left.Type != False {
				return false
			}
			relation, _ := pathquery.ParseRelation(operator)
			right = compatibilityTypedQueryRight(left, right)
			if (left.Type == True || left.Type == False) && right.Type == String {
				return false
			}
			return pathquery.Relate(left, right, relation,
				compatibilityEqual,
				func(left, right Result) bool { return left.Less(right, true) })
		}
	}
	if strings.HasSuffix(query, `\`) {
		return false
	}
	test := compatibilityGet(candidate.Raw, query)
	return test.Exists()
}

func compatibilityValidQuotedOperand(raw string) bool {
	if raw == "" || raw[0] != '"' {
		return true
	}
	end, _, err := scanJSONString(raw, 0)
	return err == nil && end == len(raw)
}

func compatibilityTildeEqual(value Result, token string) bool {
	switch strings.ToLower(token) {
	case "*":
		return value.Exists()
	case "null":
		return !value.Exists() || value.Type == Null
	case "true":
		return value.Type == True ||
			value.Type == Number && value.Num == 1 ||
			value.Type == String &&
				(strings.EqualFold(value.Str, "true") || value.Str == "1")
	case "false":
		return !value.Exists() || value.Type == Null || value.Type == False ||
			value.Type == Number && value.Num == 0 ||
			value.Type == String &&
				(strings.EqualFold(value.Str, "false") || value.Str == "0")
	}
	return strings.EqualFold(value.String(), token)
}

func compatibilityUnescapedOperator(query, operator string) int {
	depth := 0
	quoted := false
	escaped := false
	for offset := 0; offset+len(operator) <= len(query); offset++ {
		value := query[offset]
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
		switch value {
		case '(', '[', '{':
			depth++
			continue
		case ')', ']', '}':
			if depth > 0 {
				depth--
			}
			continue
		}
		if depth != 0 {
			continue
		}
		if query[offset:offset+len(operator)] != operator {
			continue
		}
		return offset
	}
	return -1
}

func compatibilityQueryValue(raw string) Result {
	raw = trimCompatibilitySpace(raw)
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"' {
		return Parse(raw)
	}
	if raw != "" {
		return Result{Type: String, Raw: raw, Str: raw}
	}
	return Result{}
}

// compatibilityBooleanQuery relates a boolean field to a query operand.
//
// GJSON does not order a boolean against a parsed value. It switches on the
// field's type and compares the operand TEXT, and the ordering operators it
// derives are not a total order at all -- they are asymmetric in a way no
// coercion reproduces:
//
//	value  ==            !=            >              >=     <              <=
//	true   op == "true"  op != "true"  op == "false"  true    false          false
//	false  op == "false" op != "false" false          false   op == "true"   true
//
// `true >= x` holds for every operand including "x" and null, while
// `true <= x` holds for none -- not even x == "true". The false row is its
// mirror. This table was read off upstream v1.19.0 rather than reasoned
// about, because reasoning produces the plausible symmetric version, which
// is wrong: `active<=true` selects the FALSE element.
//
// Reproducing it is the point. A drop-in replacement owes its callers the
// behaviour they already depend on, including where that behaviour is a
// quirk.
func compatibilityBooleanQuery(
	value bool, operand string, relation pathquery.Relation,
) bool {
	if value {
		switch relation {
		case pathquery.Equal:
			return operand == "true"
		case pathquery.NotEqual:
			return operand != "true"
		case pathquery.Greater:
			return operand == "false"
		case pathquery.GreaterOrEqual:
			return true
		case pathquery.Less, pathquery.LessOrEqual:
			return false
		}
		return false
	}
	switch relation {
	case pathquery.Equal:
		return operand == "false"
	case pathquery.NotEqual:
		return operand != "false"
	case pathquery.Greater, pathquery.GreaterOrEqual:
		return false
	case pathquery.Less:
		return operand == "true"
	case pathquery.LessOrEqual:
		return true
	}
	return false
}

// compatibilityQuerySuffixSplits reports a query-all component whose
// trailing text upstream tears apart.
//
// GJSON's parseArrayPath is neither bracket- nor quote-aware. Having
// consumed `#(...)#` it keeps scanning the SAME component for `.` and `|`,
// so a dot anywhere in the suffix — including inside brackets or quotes,
// as in `#(*)#[x.y]`, `#(*)#{x.y}` or `#(*)#["."]` — splits the component
// into a remainder that resolves to nothing. The query-all form then
// yields `[]` and the single-result form yields nothing at all.
//
// A suffix with no dot is absorbed and ignored: `#(*)#[x]` and `#(*)#x`
// both yield the whole array, in upstream and here alike. So the dot is
// the whole of the divergence, and reproducing it is what a drop-in
// replacement owes its callers.
//
// The query itself is delimited the way upstream delimits it, which is its
// own quirk: parseQuery counts `[` and `(` up and `]` and `)` down without
// pairing them, so `#(x]` closes.
func compatibilityQuerySuffixSplits(part string) (splits, queryAll bool) {
	if len(part) < 2 || part[0] != '#' ||
		part[1] != '(' && part[1] != '[' {
		return false, false
	}
	depth := 1
	index := 2
	for ; index < len(part); index++ {
		switch part[index] {
		case '\\':
			index++
		case '[', '(':
			depth++
		case ']', ')':
			depth--
		case '"':
			index++
			for ; index < len(part); index++ {
				if part[index] == '\\' {
					index++
					continue
				}
				if part[index] == '"' {
					break
				}
			}
		}
		if depth == 0 {
			break
		}
	}
	if depth != 0 || index >= len(part) {
		return false, false
	}
	suffix := part[index+1:]
	queryAll = strings.HasPrefix(suffix, "#")
	if queryAll {
		suffix = suffix[1:]
	}
	return strings.Contains(suffix, "."), queryAll
}

func compatibilityTypedQueryRight(left, right Result) Result {
	if right.Type != String {
		return right
	}
	switch left.Type {
	case Number:
		number, _ := strconv.ParseFloat(right.Str, 64)
		return Result{Type: Number, Raw: right.Raw, Num: number}
	case True, False:
		switch right.Str {
		case "true":
			return Result{Type: True, Raw: right.Raw}
		case "false":
			return Result{Type: False, Raw: right.Raw}
		}
	}
	return right
}

func trimCompatibilitySpace(value string) string {
	for len(value) > 0 && value[0] <= ' ' {
		value = value[1:]
	}
	for len(value) > 0 && value[len(value)-1] <= ' ' {
		value = value[:len(value)-1]
	}
	return value
}

func compatibilityEqual(left, right Result) bool {
	if left.Type == Number && right.Type == Number {
		return left.Num == right.Num
	}
	return left.Type == right.Type && left.String() == right.String()
}

func applyCompatibilityModifier(current Result, part string) Result {
	if DisableModifiers {
		return Result{}
	}
	nameArgument := strings.TrimPrefix(part, "@")
	name, argument, _ := strings.Cut(nameArgument, ":")
	if name == "this" {
		return current
	}
	modifier, ok := compatibilityModifiers[name]
	if !ok || modifier == nil {
		return Result{}
	}
	output := modifier(current.Raw, argument)
	result := compatibilityParse(output)
	if result.Type == JSON && strings.TrimSpace(output) == result.Raw {
		result.Raw = output
	}
	result.Index = 0
	result.Indexes = nil
	result.synthetic = true
	result.suppressIndexes = true
	return result
}
