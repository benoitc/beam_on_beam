#!/bin/sh
# Run an Elixir script (.exs) or an Erlang module with main/0, as source
# (.erl) or compiled (.beam), in the guest BEAM and print what it wrote.
#   scripts/run.sh examples/triangle.exs
#   scripts/run.sh examples/triangle.erl
#   scripts/run.sh triangle.beam
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
[ $# -eq 1 ] || { echo "usage: $0 file.exs|file.erl|file.beam" >&2; exit 64; }
exec erl -noshell \
  -pa "$here"/_build/default/lib/*/ebin \
  -pa "$here"/_build/default/checkouts/*/ebin \
  -eval 'beam_on_beam:main(init:get_plain_arguments()).' \
  -extra "$1"
