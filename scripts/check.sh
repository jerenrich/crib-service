#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test
cd worker
npm run typecheck
npm test
