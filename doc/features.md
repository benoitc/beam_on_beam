# Features

This page records what beam_on_beam can do today, what erlang_wasm needed
before the guest would boot, and what is still open. Read it before you spend
time on a part that is known not to work.

## What works

| what | state |
| --- | --- |
| Boot OTP 29.1.2 from Kettlecorn's `beam.wasm` (runtime 0.1.0) | works |
| Evaluate Erlang with `eval/1,2` and read stdout, stderr and the exit code | works |
| Files under the guest's private root | works |
| Run an Elixir script or an Erlang module from a file (`scripts/run.sh`, `run_file/1` in the shell) | works |
| Load a module compiled on the host (`run_beam/2,3`), or let the guest compile it (`run_module/1,2`) | works |
| Floats and 24-bit colour output (`examples/enki.*`) | works |
| Processes and message passing in the guest (`examples/triangle.*`) | works |
| Elixir 1.20.5 in the guest, started from Erlang with `application:ensure_all_started(elixir)` and `'Elixir.Code':eval_string/1` | works |
| stdin, the framed host protocol of Kettlecorn | not wired |
| Network (`wasi:sockets`), `beam-http.wasm` (`wasi:http`) | not tried |
| A guest kept running between calls | not there: every call boots a new one |

## Measured

One run each, on a laptop at a load average between 20 and 50, so read them as
orders of magnitude:

| what | time |
| --- | --- |
| decode and instantiate `beam.wasm` on erlang_wasm | about 6 s |
| boot and evaluate one expression on erlang_wasm | 89 s and 108 s |
| boot, start Elixir and evaluate one Elixir expression on erlang_wasm | 155 s |
| `examples/triangle.exs` | 172 s |
| `examples/triangle.erl`, compiled in the guest | 163 s |
| `triangle.beam`, compiled on the host with `erlc` | 80 s |
| `examples/enki.erl`, compiled in the guest | 535 s |
| `examples/enki.erl`, compiled on the host | 192 s |
| `examples/enki.exs`, compiled in the guest, while another guest ran beside it | 726 s |
| the same boot on Wasmtime 50.0.1, compiled code cached | 0.11 s |

Wasmtime needs about 690 million units of fuel for that boot, which is close
to the number of WebAssembly instructions it runs.

## What erlang_wasm needed

The guest did not start on erlang_wasm 0.10.2. These changes are on the
`beam-guest` branch of erlang_wasm, in the order the boot ran into them:

1. **`run` lifted without the async option.** wasi-libc lifts the async
   function `wasi:cli/run` as a plain function that blocks. The runner only
   called a 0.3 `run` in its async-lifted form.
2. **Context slots during `realloc`.** `context.get` and `context.set`
   trapped while a `realloc` ran. The specification lets them through, and
   wasi-libc reads the stack pointer there.
3. **Async imports lowered without the async option.** `open-at`, `stat` and
   others are called as blocking functions. The host bound every async import
   in its async form and read the arguments from the wrong place.
4. **A lift that lives in a core without memory.** wit-component wraps `run`
   in a small module of its own. The built-ins of the call read and wrote that
   module instead of the one that owns the memory.
5. **A thread calls through another core's table.** An explicit thread is a
   process, and it knew only its own core instance.
6. **Context slots are per thread.** They were per task, so every thread
   shared one stack pointer.
7. **A main thread that waits lets the others run.** `waitable-set.wait` on
   the implicit thread blocked the whole instance. A thread that only yields
   also kept a thread whose event had come from running.
8. **The cost of a host call from a thread.** Each call sent the whole
   instance to the owner process: 250 MB and 0.38 s a call. The owner now
   keeps the host functions and a thread sends a key.
9. **`realloc` runs with context slots of its own.** The specification runs
   it in a new thread whose slots are zero, then puts the caller's back.
   wasi-libc's `cabi_realloc` leaves the stack pointer at zero.

## Open

- **Speed.** The guest runs in erlang_wasm's interpreter. The compiled tier
  never starts: it compiles a module after 32 outer calls, and this guest is
  one call that never returns.
- **Memory.** The host process reached about 9 GB in a run made before
  change 8. It has not been measured since.
- **Tests in erlang_wasm.** The changes above have no test of their own yet.
  Each needs a small WAT case that fails without it.
- **A compiled guest.** Compiling the program on the host removes the guest's
  compile time, not the boot: about 90 s of every call is OTP starting. The
  real gain is erlang_wasm compiling `beam.wasm` itself to BEAM code and
  keeping it in its code cache, which the tier cannot do yet for this guest.
- **The network, a long-lived guest.** See the table above.
