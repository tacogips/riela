#!/usr/bin/env bash
# Regenerate the checked-in control-plane SDL
# (Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift) from
# GraphQLSchemaGenerator plus the SurfaceCatalog GraphQL bindings.
#
# The generator runs inside `swift test` so there is no separate tool target
# (design delta D4). Run this after changing a contract descriptor or a catalog
# GraphQL binding, then rerun the suite.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RIELA_WRITE_GENERATED_SDL=1 arch -arm64 /bin/zsh -lc \
  'swift test --filter SurfaceParityGraphQLTests/testRegenerateGeneratedSDLWhenRequested'

echo "Regenerated Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift"
