package gjson

import "goforge.dev/gpgjson/typed"

var (
	_ func(string, string) Result                                                                = Get
	_ func([]byte, string) Result                                                                = GetBytes
	_ func(string, ...string) []Result                                                           = GetMany
	_ func([]byte, ...string) []Result                                                           = GetManyBytes
	_ func(string) Result                                                                        = Parse
	_ func([]byte) Result                                                                        = ParseBytes
	_ func(string) bool                                                                          = Valid
	_ func([]byte) bool                                                                          = ValidBytes
	_ func(string) string                                                                        = Escape
	_ func(string) (*Path, error)                                                                = CompilePath
	_ func(string) (Document, error)                                                             = ParseDocument
	_ func(typed.Path[typed.StringView], typed.TypedDocument[Document], *typed.StringView) State = LookupStringInto
)
