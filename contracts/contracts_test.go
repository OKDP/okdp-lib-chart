// Copyright 2026 The OKDP Authors.
// Licensed under the Apache License, Version 2.0.

package contracts

import (
	"encoding/json"
	"io/fs"
	"strings"
	"testing"
)

// Every embedded schema is named after the contract it declares.
func TestSchemasNamedAfterTheirContract(t *testing.T) {
	names, err := fs.Glob(FS, "*.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	if len(names) == 0 {
		t.Fatal("no contract schema embedded")
	}
	for _, name := range names {
		raw, err := FS.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		var s struct {
			Contract string `json:"x-okdp-contract"`
		}
		if err := json.Unmarshal(raw, &s); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if want := strings.TrimSuffix(name, ".schema.json"); s.Contract != want {
			t.Errorf("%s declares x-okdp-contract %q, want %q", name, s.Contract, want)
		}
	}
}
