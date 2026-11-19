# beam_on_beam

beam_on_beam runs the Erlang VM as a WebAssembly guest of
[erlang_wasm](https://github.com/benoitc/erlang_wasm), the WebAssembly runtime
written in Erlang. The guest is Kettlecorn's `beam.wasm`: OTP 29 built for
WASI 0.3 with cooperative threads. You call one function, the guest boots,
evaluates your Erlang code and returns what it printed. It is an experiment:
use it to see how far erlang_wasm goes with a large threaded guest, not to
sandbox code in production.

## When to use it

- You want to try a real program that needs Component Model threads on
  erlang_wasm.
- You want a guest that is slow enough to show where the runtime spends its
  time.

For a fast sandbox for Elixir or Erlang code, use
[Kettlecorn](https://github.com/mjrusso/kettlecorn) with Wasmtime.

## Set it up

You need Erlang/OTP 29, rebar3, and a checkout of erlang_wasm on its
`beam-guest` branch, which has the runtime fixes this guest needs.

```sh
# 1. Link the erlang_wasm branch as a checkout dependency.
mkdir -p _checkouts
ln -s /path/to/erlang_wasm-beam _checkouts/wasm

# 2. Download the Kettlecorn runtime (beam.wasm and the OTP .beam files).
scripts/fetch-runtime.sh

# 3. Build.
rebar3 compile
```

## Evaluate Erlang in the guest

```erlang
1> beam_on_beam:eval("io:format(\"~p~n\", [lists:sum(lists:seq(1, 100))]), halt().").
{ok,#{stdout => <<"5050\n">>,stderr => <<>>,exit_code => 0}}
```

The code runs as `erl -eval` runs it. End it with `halt().`, or the guest
keeps running.

To pass your own `init` arguments, use `run/2`:

```erlang
beam_on_beam:run([~"-eval", ~"erlang:display(node()), halt()."], #{}).
```

## Run a script

`scripts/run.sh` runs a file in the guest and prints what it wrote: an Elixir
script (`.exs`), or an Erlang module with a `main/0` (`.erl`).

```sh
scripts/run.sh examples/enki.erl
scripts/run.sh examples/enki.exs
scripts/run.sh examples/triangle.erl
scripts/run.sh examples/triangle.exs
```

An Erlang file is compiled on the host and the guest loads the `.beam`, so
host and guest must be the same OTP release (29). An Elixir script is
compiled by the guest, which is slower.

`examples/enki.*` draws the Enki Multimedia logo: the program rasterises the
logo's polygons and gradients itself, one process per line of text, in 24-bit
colour. Your terminal must support true colour. `examples/triangle.*`
prints a triangle of blocks the same way:

```text
               ██
              ████
             ██  ██
            ████████
           ██      ██
          ████    ████
         ██  ██  ██  ██
        ████████████████
```

## Load a compiled module

When you already have a `.beam` file, give it to the guest as it is. The
module needs a `main/0`, and it must come from the guest's OTP release (29):

```sh
erlc -o /tmp examples/triangle.erl
scripts/run.sh /tmp/triangle.beam
```

From Erlang, `run_beam/2` takes the module's name and its binary, from a file
or straight from the compiler:

```erlang
{ok, Beam} = file:read_file("/tmp/triangle.beam"),
{ok, #{stdout := Out}} = beam_on_beam:run_beam(triangle, Beam),
io:format("~ts", [Out]).
```

```erlang
{ok, Module, Beam} = compile:file("examples/triangle.erl", [binary]),
{ok, #{stdout := Out}} = beam_on_beam:run_beam(Module, Beam).
```

The guest finds the module in `/work`, which is on its code path, and loads
it the first time `main/0` is called. To give it several modules, add the
others with the `files` option:

```erlang
beam_on_beam:run_beam(Module, Beam,
                      #{files => [{"work/helper.beam", HelperBeam}]}).
```

## Run it from the Erlang shell

```sh
rebar3 shell
```

```erlang
1> beam_on_beam:run_file("examples/enki.erl").
```

`run_file/1` prints what the guest wrote and returns `{ok, ExitCode}`. The
other calls return the output instead of printing it:

| call | what it runs |
| --- | --- |
| `eval/1,2` | Erlang expressions, as `erl -eval` |
| `eval_elixir/1,2` | an Elixir script |
| `run_beam/2,3` | a module compiled on the host: `Module:main()` |
| `run_module/1,2` | an Erlang module the guest compiles itself, then `main/0` |
| `run/2` | your own `init` arguments |

The shell is the host's. The guest has no interactive shell yet: its stdin
is not connected.

## Options

`eval/2` and `run/2` take a map:

| option | what it does |
| --- | --- |
| `runtime` | the runtime directory. Default: `$BEAM_ON_BEAM_RUNTIME`, else `priv/runtime` |
| `files` | a list of `{PathUnderRoot, Contents}` written into the guest's root before it boots |
| any option of `wasi_preview3:run_command/3` | passed on, except `args`, `env` and `preopen`. `fuel` and `max_memory_pages` limit the guest |

## Notes

- One call takes about 90 seconds on a loaded laptop, and about 3 minutes
  for an example. Wasmtime boots the same
  guest in about 0.1 second. [Features](doc/features.md) says where the time
  goes.
- The guest's words are 32 bits and it has one scheduler.
- Each call gets a private copy of the runtime's root directory, removed when
  the call returns. The guest sees no other host file and has no network.
- The guest is an interpreter (the BEAM) run by an interpreter (erlang_wasm)
  run by the BEAM.

## Read next

- [Features](doc/features.md): what works, what does not, and what erlang_wasm
  needed.
- [Prior work](doc/prior-work.md): what Popcorn and Kettlecorn did to build
  `beam.wasm`.
