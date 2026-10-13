#!/bin/sh
cd "$(dirname "$0")" || exit 1

[ -f lindale_collection.txt ] || echo ./lindale > lindale_collection.txt
LINDALE=$(head -n 1 lindale_collection.txt | tr -d '\r')

exec odin run . -collection:lindale="$LINDALE/src" -- "$@"
