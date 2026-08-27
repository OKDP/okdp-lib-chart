// Copyright 2026 The OKDP Authors.
// Licensed under the Apache License, Version 2.0.

// Package contracts holds the canonical OKDP contract schemas
// (<contract>.schema.json, draft-07): the same documents the okdp-lib chart
// embeds (hack/gen-contracts.sh) and validates connections against.
package contracts

import "embed"

// FS holds every <contract>.schema.json, at the root of the file system.
//
//go:embed *.schema.json
var FS embed.FS
