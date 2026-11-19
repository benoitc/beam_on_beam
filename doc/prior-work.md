# Prior work: Popcorn and Kettlecorn

This page says what the two projects this one stands on did to make OTP's
emulator build and run as WebAssembly. Read it when you want to know why the
guest behaves as it does, or before you build your own `beam.wasm`.

## Popcorn

[Popcorn](https://github.com/software-mansion/popcorn), by Software Mansion,
runs Elixir in the browser. Until 1.0 it used AtomVM. Its 1.0 rewrite moved to
the real OTP emulator, compiled with Emscripten.

It carries 13 patches on OTP (about 2700 lines), numbered `0001` to `0014`:

| patch | what it does |
| --- | --- |
| `0001-emscripten-support` | teaches `configure` and the cross-compile files about `wasm32-emscripten` |
| `0002-without-zstd` | builds stdlib and the emulator without zstd |
| `0003-without-native-sockets` | removes the inet driver; `prim_inet` answers without it |
| `0005-without-crash-dumps` | a fatal error prints one line to stderr in place of writing a crash dump |
| `0006-without-dynamic-loading` | no `dlopen`: NIFs and drivers are linked statically |
| `0007-bootstrap-trim` | leaves wx, snmp, runtime_tools, xmerl and common_test out of the native bootstrap, which no enabled application needs |
| `0008-driver-start-callbacks` | gives the built-in drivers (fd, spawn, forker) a start callback of their own, apart from a loadable driver's |
| `0009-signal-shutdown` | no signal handling; the main thread polls for the halt code |
| `0010-disable-os-processes` | no `fork`: `open_port({spawn, ...})` is refused |
| `0011-wasm-bridge` | the `wasm` NIF and preloaded module that connect the VM to its host, and a `prim_tty` that reads from it |
| `0012-asn-one-erlang-fallback` | ASN.1 BER decoding falls back to Erlang when the NIF is not loaded |
| `0013-module-checksum-xxh` | a module's checksum is computed with XXH3 (128 bits) in place of MD5 |
| `0014-no-jump-table` | builds the interpreter loop as a `switch` (`NO_JUMP_TABLE`), since WebAssembly has no computed goto |

The emulator is the interpreter (`--disable-jit`): BeamAsm emits machine code
at run time, which WebAssembly does not allow.

## Kettlecorn

[Kettlecorn](https://github.com/mjrusso/kettlecorn), by Michael Russo, takes
Popcorn's patches unchanged and adds five more (about 600 lines) and about
1300 lines of C to target WASI 0.3 in place of the browser:

| patch | what it does |
| --- | --- |
| `0101-wasi-platform` | a platform header and Makefile hooks; shares the browser's restrictions under one macro |
| `0102-cooperative-threads` | the scheduler yields: every spin iteration, every 8 context switches of a busy scheduler, and in `scheduler_wait`; spinlocks become mutexes |
| `0103-stdio-bridge` | a thread that reads framed messages from stdin and delivers them with `enif_send`; framed writes to stdout |
| `0104-sockets-dns` | puts the inet driver back, over wasi-libc's `wasi:sockets`; DNS through a NIF |
| `0106-terminal` | raw mode in `prim_tty` without terminfo, for IEx |

The piece that matters most to a host is threads. OTP needs pthreads
(schedulers, the aux thread, the poll thread). wasi-libc for `wasm32-wasip3`
implements them with the Component Model's cooperative threads: every pthread
is a component thread made with `thread.new-indirect`, and one runs at a time.
A thread gives up its turn only when it blocks or yields, which is why patch
`0102` adds yields to every place the emulator would spin.

The result is `beam.wasm`: one component, 5.6 MB, OTP 29.1.2. It imports
`wasi:cli`, `wasi:clocks`, `wasi:filesystem`, `wasi:random` and `wasi:sockets`
at 0.3.2, and exports `wasi:cli/run@0.3.2`. Kettlecorn runs it with an
embedded Wasmtime 50 and component-model threading turned on.

## What this asks of a host

A host that runs `beam.wasm` must provide, besides WASI 0.3:

- cooperative threads: `thread.new-indirect`, `thread.yield`,
  `thread.suspend`, `thread.resume-later`, `thread.yield-then-resume`,
  `thread.index`;
- thread-local context slots (`context.get` and `context.set`): wasi-libc
  keeps each thread's C stack pointer in slot 0 and its TLS base in slot 1, so
  nearly every C function reads one;
- an async function lifted without the async option: `run` blocks inside its
  one core call;
- async imports lowered without the async option: `open-at`, `stat` and the
  like are called as plain blocking functions.

[Features](features.md) says which of these erlang_wasm had and which this
project added.
