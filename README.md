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

You need Erlang/OTP 29 and rebar3. For Elixir modules you also need Elixir
1.20 on the host.

```sh
# 1. Download the Kettlecorn runtime (beam.wasm and the OTP .beam files).
scripts/fetch-runtime.sh

# 2. Build.
rebar3 compile
```

erlang_wasm comes from its `main` branch: the runtime fixes this guest needs
([pull request 139](https://github.com/benoitc/erlang_wasm/pull/139)) are
merged and not in a release yet. To work on erlang_wasm at the same time,
link your checkout as `_checkouts/wasm`.

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

## Boot once, run many times

Every call above boots OTP again, which is most of its time. To pay for the
boot once, start a guest and keep it:

```erlang
1> {ok, VM} = beam_on_beam_vm:start().                    % about 70 s
2> beam_on_beam_vm:run_file(VM, "examples/triangle.erl"). % about 1 to 4 s
3> beam_on_beam_vm:run_file(VM, "examples/enki.erl").     % about 40 s
4> beam_on_beam_vm:run_file(VM, "examples/triangle.ex").  % 19 s, then under 1 s
5> beam_on_beam_vm:run_file(VM, "examples/enki.ex").
6> beam_on_beam_vm:eval(VM, "length(processes()).").
7> beam_on_beam_vm:stop(VM).
```

`run_file/2` takes a module with `main/0` (`.erl`, `.ex` or `.beam`), prints
what it wrote and returns `{ok, Milliseconds}`. `run_beam/3` and `eval/2`
return the output instead. Sources are compiled on the host, as below.

The first Elixir module a guest runs also starts the `elixir` application,
once, which is the 19 s above.

The guest is one BEAM that keeps its state: a module you run again is loaded
again, but processes a job leaves behind stay. Jobs run one at a time.

## Run a script

`scripts/run.sh` runs a file in the guest and prints what it wrote:

| file | what it is | where it is compiled |
| --- | --- | --- |
| `.erl` | an Erlang module with `main/0` | on the host |
| `.ex` | an Elixir module with `main/0` | on the host, with `elixirc` |
| `.beam` | a compiled module with `main/0` | already compiled |
| `.exs` | an Elixir script | in the guest, which is slower |

```sh
scripts/run.sh examples/enki.erl
scripts/run.sh examples/enki.ex
scripts/run.sh examples/triangle.erl
scripts/run.sh examples/triangle.ex
scripts/run.sh examples/triangle.exs
```

The host compiles with its own Erlang and Elixir, so it must run the same OTP
release as the guest (29) and a close Elixir (the guest has 1.20.5).

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

An Elixir module is the same, under its full name. Compile it with `elixirc`
and run the `.beam`, or let `run_file/1` do both from the `.ex` file:

```sh
elixirc -o /tmp examples/enki.ex
scripts/run.sh /tmp/Elixir.Enki.beam
```

```erlang
{ok, Beam} = file:read_file("/tmp/Elixir.Enki.beam"),
{ok, #{stdout := Out}} = beam_on_beam:run_beam('Elixir.Enki', Beam).
```

For a module whose name starts with `Elixir.`, the guest starts the `elixir`
application before it calls `main/0`.

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
2> beam_on_beam:run_file("examples/enki.ex").
```

`run_file/1` prints what the guest wrote and returns `{ok, ExitCode}`. The
other calls return the output instead of printing it:

| call | what it runs |
| --- | --- |
| `eval/1,2` | Erlang expressions, as `erl -eval` |
| `eval_elixir/1,2` | an Elixir script |
| `run_beam/2,3` | a compiled module, Erlang or Elixir: `Module:main()` |
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

- One call of `beam_on_beam` takes 70 to 90 seconds on a loaded laptop
  before your code starts. `beam_on_beam_vm` pays that once. Wasmtime boots the same
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
