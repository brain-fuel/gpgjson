// Go+ immutable JSON document semantics.
package gjson

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
)

// Document is an immutable, validated JSON string. Borrowed results keep its
// source alive, and repeated compiled-path queries require no revalidation.
type indexedValue struct {
	start, end             int
	kind                   Type
	stringStart, stringEnd int
	escaped                bool
}

type Document struct {
	source     string
	start, end int
	index      map[string]indexedValue
}

func ParseDocument(source string) (Document, error) {
	start := skipSpace(source, 0)
	end, err := validateValue(source, start)
	if err != nil {
		return Document{}, err
	}
	if trailing := skipSpace(source, end); trailing != len(source) {
		return Document{}, fmt.Errorf("gjson: trailing data at byte %d", trailing)
	}
	index := make(map[string]indexedValue)
	if err := indexValue(source, start, end, "", index); err != nil {
		return Document{}, err
	}
	return Document{source: source, start: start, end: end, index: index}, nil
}

// ParseDocumentBytes owns a copy so future caller mutation cannot invalidate
// borrowed views.
func ParseDocumentBytes(source []byte) (Document, error) { return ParseDocument(string(source)) }
func (d Document) Raw() string                           { return d.source[d.start:d.end] }
func (d Document) Query(path *Path) Lookup {
	if path == nil {
		return Lookup{state: MalformedState, err: fmt.Errorf("gjson: nil path")}
	}
	entry, ok := d.index[path.key]
	if !ok {
		return path.queryRange(d.source, d.start, d.end)
	}
	value := Borrowed{source: d.source, start: entry.start, end: entry.end, kind: entry.kind, stringStart: entry.stringStart, stringEnd: entry.stringEnd, escaped: entry.escaped}
	if value.kind == Null {
		return Lookup{state: NullState, value: value}
	}
	return Lookup{state: ValueState, value: value}
}

func (d Document) queryKey(key string) Lookup {
	entry, ok := d.index[key]
	if !ok {
		return Lookup{state: MissingState}
	}
	value := Borrowed{source: d.source, start: entry.start, end: entry.end, kind: entry.kind, stringStart: entry.stringStart, stringEnd: entry.stringEnd, escaped: entry.escaped}
	if value.kind == Null {
		return Lookup{state: NullState, value: value}
	}
	return Lookup{state: ValueState, value: value}
}

func (p *Path) queryRange(source string, start, end int) Lookup {
	var err error
	for _, part := range p.segments {
		start, end, err = descend(source, start, end, part)
		if err != nil {
			return Lookup{state: MalformedState, err: err}
		}
		if start < 0 {
			return Lookup{state: MissingState}
		}
	}
	value, err := borrowedAt(source, start, end)
	if err != nil {
		return Lookup{state: MalformedState, err: err}
	}
	if value.kind == Null {
		return Lookup{state: NullState, value: value}
	}
	return Lookup{state: ValueState, value: value}
}

func indexValue(source string, start, end int, prefix string, index map[string]indexedValue) error {
	value, err := borrowedAt(source, start, end)
	if err != nil {
		return err
	}
	if _, exists := index[prefix]; !exists {
		index[prefix] = indexedValue{start: value.start, end: value.end, kind: value.kind, stringStart: value.stringStart, stringEnd: value.stringEnd, escaped: value.escaped}
	}
	if value.kind != JSON {
		return nil
	}
	if source[start] == '{' {
		return indexObject(source, start, end, prefix, index)
	}
	return indexArray(source, start, end, prefix, index)
}

func childKey(prefix, component string) string {
	component = Escape(component)
	if prefix == "" {
		return component
	}
	return prefix + "." + component
}
func indexObject(source string, start, end int, prefix string, index map[string]indexedValue) error {
	i := skipSpace(source, start+1)
	if i < end && source[i] == '}' {
		return nil
	}
	for i < end {
		keyEnd, escaped, err := scanJSONString(source, i)
		if err != nil {
			return err
		}
		key := source[i+1 : keyEnd-1]
		if escaped {
			decoded, err := appendDecodedString(nil, key)
			if err != nil {
				return err
			}
			key = string(decoded)
		}
		i = skipSpace(source, keyEnd) + 1
		valueStart := skipSpace(source, i)
		valueEnd, _, err := scanValue(source, valueStart)
		if err != nil {
			return err
		}
		if err := indexValue(source, valueStart, valueEnd, childKey(prefix, key), index); err != nil {
			return err
		}
		i = skipSpace(source, valueEnd)
		if i < end && source[i] == ',' {
			i = skipSpace(source, i+1)
			continue
		}
		return nil
	}
	return nil
}
func indexArray(source string, start, end int, prefix string, index map[string]indexedValue) error {
	i := skipSpace(source, start+1)
	if i < end && source[i] == ']' {
		return nil
	}
	position := 0
	for i < end {
		valueStart := i
		valueEnd, _, err := scanValue(source, valueStart)
		if err != nil {
			return err
		}
		if err := indexValue(source, valueStart, valueEnd, childKey(prefix, strconv.Itoa(position)), index); err != nil {
			return err
		}
		position++
		i = skipSpace(source, valueEnd)
		if i < end && source[i] == ',' {
			i = skipSpace(source, i+1)
			continue
		}
		return nil
	}
	return nil
}

func validateValue(source string, start int) (int, error) {
	start = skipSpace(source, start)
	if start >= len(source) {
		return start, fmt.Errorf("gjson: expected value at byte %d", start)
	}
	switch source[start] {
	case '{':
		return validateObject(source, start)
	case '[':
		return validateArray(source, start)
	default:
		end, _, err := scanValue(source, start)
		return end, err
	}
}

func validateObject(source string, start int) (int, error) {
	i := skipSpace(source, start+1)
	if i < len(source) && source[i] == '}' {
		return i + 1, nil
	}
	for {
		i = skipSpace(source, i)
		if i >= len(source) || source[i] != '"' {
			return i, fmt.Errorf("gjson: expected object key at byte %d", i)
		}
		end, _, err := scanJSONString(source, i)
		if err != nil {
			return i, err
		}
		i = skipSpace(source, end)
		if i >= len(source) || source[i] != ':' {
			return i, fmt.Errorf("gjson: expected ':' at byte %d", i)
		}
		i, err = validateValue(source, i+1)
		if err != nil {
			return i, err
		}
		i = skipSpace(source, i)
		if i < len(source) && source[i] == '}' {
			return i + 1, nil
		}
		if i >= len(source) || source[i] != ',' {
			return i, fmt.Errorf("gjson: expected ',' or '}' at byte %d", i)
		}
		i++
	}
}
func validateArray(source string, start int) (int, error) {
	i := skipSpace(source, start+1)
	if i < len(source) && source[i] == ']' {
		return i + 1, nil
	}
	for {
		var err error
		i, err = validateValue(source, i)
		if err != nil {
			return i, err
		}
		i = skipSpace(source, i)
		if i < len(source) && source[i] == ']' {
			return i + 1, nil
		}
		if i >= len(source) || source[i] != ',' {
			return i, fmt.Errorf("gjson: expected ',' or ']' at byte %d", i)
		}
		i++
	}
}

// LineScanner incrementally traverses a JSON-lines stream. Each successful
// Next owns only the current line; callers may retain its Document safely.
type LineScanner struct {
	scanner  *bufio.Scanner
	document Document
	err      error
}

func NewLineScanner(reader io.Reader) *LineScanner {
	return &LineScanner{scanner: bufio.NewScanner(reader)}
}
func (s *LineScanner) Next() bool {
	if s.err != nil || !s.scanner.Scan() {
		if s.err == nil {
			s.err = s.scanner.Err()
		}
		return false
	}
	s.document, s.err = ParseDocumentBytes(s.scanner.Bytes())
	return s.err == nil
}
func (s *LineScanner) Document() Document { return s.document }
func (s *LineScanner) Err() error         { return s.err }
