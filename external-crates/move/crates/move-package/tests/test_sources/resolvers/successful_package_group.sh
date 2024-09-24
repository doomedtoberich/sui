#!/bin/sh
# Copyright (c) The Move Contributors
# SPDX-License-Identifier: Apache-2.0

ROOT="$(git rev-parse --show-toplevel)"
TYPE="dependencies"
PACKAGE="$2"

# Print Diagnostics for test output
cat <<EOF >&2
Successful External Resolver
PWD:     $(pwd | sed "s,^$ROOT,\$ROOT,")
Type:    $TYPE
Package: $PACKAGE
EOF

foo=$(cat <<'EOF'
[move]
version = 3
manifest_digest = "42"
deps_digest = "7"
dependencies = [
    { id = "foo", name = "foo" },
]

[[move.package]]
id = "foo"
source = { local = "./deps_only/foo" }
EOF
)

bar=$(cat <<'EOF'
[move]
version = 3
manifest_digest = "42"
deps_digest = "7"
dependencies = [
    { id = "bar", name = "bar" },
]

[[move.package]]
id = "bar"
source = { local = "./deps_only/bar" }
EOF
)

# Echo the content twice with a null separator between
echo "$foo\0$bar"
