-module(beam_on_beam).
-moduledoc """
Run the BEAM as a guest of erlang_wasm.

The guest is Kettlecorn's `beam.wasm`: OTP's emulator built as a WASI 0.3
component with cooperative threads. `eval/1,2` boots it, evaluates an Erlang
expression in it and returns what it printed.
""".

-export([eval/1, eval/2, eval_elixir/1, eval_elixir/2, run_module/1, run_module/2,
         run/2, runtime_dir/0]).
-export([run_beam/2, run_beam/3, run_file/1, run_file/2, main/1]).
-export([modules/1, scratch_root/0, copy_tree/2]).

-type result() :: {ok, #{stdout := binary(), stderr := binary(),
                         exit_code := integer()}}
                | {error, term()}.

-doc """
Boot the guest BEAM and evaluate `Code`, a sequence of Erlang expressions
ending with a dot. The guest keeps running until the code calls `halt()`.
""".
-spec eval(iodata()) -> result().
eval(Code) ->
    eval(Code, #{}).

-doc """
As `eval/1`. `Opts` may hold `runtime`, the runtime directory, `files`, a list
of `{PathUnderRoot, Contents}` written into the guest's root before it boots,
and any option of `wasi_preview3:run_command/3` except `args`, `env` and
`preopen`.
""".
-spec eval(iodata(), map()) -> result().
eval(Code, Opts) ->
    run([~"-eval", iolist_to_binary(Code)], Opts).

-doc "Boot the guest BEAM and run `Code`, an Elixir script.".
-spec eval_elixir(iodata()) -> result().
eval_elixir(Code) ->
    eval_elixir(Code, #{}).

-doc """
As `eval_elixir/1`, with the options of `eval/2`. The script is written to
`/work/script.exs` in the guest's root and run as the `elixir` command runs a
file.
""".
-spec eval_elixir(iodata(), map()) -> result().
eval_elixir(Code, Opts) ->
    Files = maps:get(files, Opts, []),
    run([~"-s", ~"elixir", ~"start_cli", ~"-extra", ~"/work/script.exs"],
        Opts#{files => [{"work/script.exs", Code} | Files]}).

-doc "Boot the guest BEAM, compile `Source`, an Erlang module, and call its `main/0`.".
-spec run_module(iodata()) -> result().
run_module(Source) ->
    run_module(Source, #{}).

-doc """
As `run_module/1`, with the options of `eval/2`. The module is written to
`/work/main.erl` in the guest's root and compiled there, by the guest's own
compiler.
""".
-spec run_module(iodata(), map()) -> result().
run_module(Source, Opts) ->
    Files = maps:get(files, Opts, []),
    Code = "{ok, M, B} = compile:file(\"/work/main.erl\", [binary, report]), "
           "{module, M} = code:load_binary(M, \"/work/main.erl\", B), "
           "M:main(), halt().",
    run([~"-eval", list_to_binary(Code)],
        Opts#{files => [{"work/main.erl", Source} | Files]}).

-doc """
Run the file `Path` in the guest and print what it wrote: an Elixir script
(`.exs`), or a module with `main/0`: Erlang source (`.erl`), Elixir source
(`.ex`), or compiled (`.beam`). Sources of modules are compiled on the host. This is the call to make
from the Erlang shell. Returns the guest's exit code.
""".
-spec run_file(file:name_all()) -> {ok, integer()} | {error, term()}.
run_file(Path) ->
    run_file(Path, #{}).

-doc "As `run_file/1`, with the options of `eval/2`.".
-spec run_file(file:name_all(), map()) -> {ok, integer()} | {error, term()}.
run_file(Path, Opts) ->
    maybe
        {ok, #{stdout := Out, stderr := Err, exit_code := Status}} ?=
            file_result(Path, Opts),
        io:format("~ts", [Out]),
        io:format(standard_error, "~ts", [Err]),
        {ok, Status}
    end.

file_result(Path, Opts) ->
    case file:read_file(Path) of
        {ok, Source} ->
            case filename:extension(Path) of
                Ext when Ext =:= ".erl"; Ext =:= ~".erl" -> precompiled(Path, Opts);
                Ext when Ext =:= ".beam"; Ext =:= ~".beam" -> beam_file(Source, Opts);
                Ext when Ext =:= ".ex"; Ext =:= ~".ex" -> elixir_module(Path, Opts);
                _ -> eval_elixir(Source, Opts)
            end;
        {error, Reason} ->
            {error, {Path, Reason}}
    end.

%% An Elixir file of modules is compiled here, on the host, with `elixirc',
%% and the guest loads the results. The module to run is the one that exports
%% `main/0'.
elixir_module(Path, Opts) ->
    elixirc(Path, fun(Out) -> compiled_elixir(Out, Opts) end).

elixirc(Path, Then) ->
    case os:find_executable("elixirc") of
        false ->
            {error, no_elixirc};
        Elixirc ->
            Out = scratch_root(),
            ok = filelib:ensure_path(Out),
            try
                Port = open_port({spawn_executable, Elixirc},
                                 [{args, ["-o", Out, Path]}, exit_status,
                                  stderr_to_stdout, binary]),
                case port_output(Port, []) of
                    {0, _} -> Then(Out);
                    {_, Log} -> {error, {compile, Log}}
                end
            after
                _ = file:del_dir_r(Out)
            end
    end.

port_output(Port, Acc) ->
    receive
        {Port, {data, Data}} -> port_output(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    end.

compiled_elixir(Dir, Opts) ->
    Beams = [begin
                 {ok, Beam} = file:read_file(File),
                 {filename:basename(File), Beam}
             end || File <- filelib:wildcard(filename:join(Dir, "*.beam"))],
    Mains = [Module || {_, Beam} <- Beams,
                       {ok, {Module, [{exports, Exports}]}} <-
                           [beam_lib:chunks(Beam, [exports])],
                       lists:member({main, 0}, Exports)],
    case Mains of
        [Module] ->
            {value, {_, Main}, Others} =
                lists:keytake(atom_to_list(Module) ++ ".beam", 1, Beams),
            Files = [{"work/" ++ Name, Beam} || {Name, Beam} <- Others],
            run_beam(Module, Main,
                     Opts#{files => Files ++ maps:get(files, Opts, [])});
        [] -> {error, no_main};
        _ -> {error, {several_mains, Mains}}
    end.

-doc """
The compiled modules of the file `Path`, an Erlang source (`.erl`), an Elixir
source (`.ex`) or a compiled module (`.beam`): the module that has `main/0`,
and every module with its binary. Sources are compiled on the host.
""".
-spec modules(file:name_all()) ->
          {ok, module(), [{module(), binary()}]} | {error, term()}.
modules(Path) ->
    case filename:extension(Path) of
        Ext when Ext =:= ".erl"; Ext =:= ~".erl" ->
            case compile:file(Path, [binary, return_errors]) of
                {ok, Module, Beam} -> {ok, Module, [{Module, Beam}]};
                {error, Errors, _Warnings} -> {error, {compile, Errors}}
            end;
        Ext when Ext =:= ".beam"; Ext =:= ~".beam" ->
            maybe
                {ok, Beam} ?= file:read_file(Path),
                {ok, Module} ?= module_of(Beam),
                {ok, Module, [{Module, Beam}]}
            end;
        Ext when Ext =:= ".ex"; Ext =:= ~".ex" ->
            elixirc(Path, fun elixir_modules/1);
        Other ->
            {error, {not_a_module_file, Other}}
    end.

module_of(Beam) ->
    case beam_lib:info(Beam) of
        {error, beam_lib, Reason} -> {error, {not_a_beam_file, Reason}};
        Info -> {ok, proplists:get_value(module, Info)}
    end.

elixir_modules(Dir) ->
    Beams = [begin
                 {ok, Beam} = file:read_file(File),
                 {ok, Module} = module_of(Beam),
                 {Module, Beam}
             end || File <- filelib:wildcard(filename:join(Dir, "*.beam"))],
    Mains = [Module || {Module, Beam} <- Beams,
                       {ok, {_, [{exports, Exports}]}} <-
                           [beam_lib:chunks(Beam, [exports])],
                       lists:member({main, 0}, Exports)],
    case Mains of
        [Main] -> {ok, Main, Beams};
        [] -> {error, no_main};
        _ -> {error, {several_mains, Mains}}
    end.

%% A compiled module: its name is the one inside the file, whatever the file
%% is called.
beam_file(Beam, Opts) ->
    case beam_lib:info(Beam) of
        {error, beam_lib, Reason} -> {error, {not_a_beam_file, Reason}};
        Info ->
            {module, Module} = lists:keyfind(module, 1, Info),
            run_beam(Module, Beam, Opts)
    end.

%% An Erlang file is compiled here, on the host, and the guest loads the
%% result: the guest's own compiler takes minutes for what takes the host
%% milliseconds. Host and guest must be the same OTP release.
precompiled(Path, Opts) ->
    case compile:file(Path, [binary, return_errors]) of
        {ok, Module, Beam} -> run_beam(Module, Beam, Opts);
        {error, Errors, _Warnings} -> {error, {compile, Errors}}
    end.

-doc "Boot the guest BEAM, load the compiled module `Beam` and call `Module:main()`.".
-spec run_beam(module(), binary()) -> result().
run_beam(Module, Beam) ->
    run_beam(Module, Beam, #{}).

-doc """
As `run_beam/2`, with the options of `eval/2`. `Beam` is what `compile:file/2`
returns with the `binary` option, from the same OTP release as the guest's.
""".
-spec run_beam(module(), binary(), map()) -> result().
run_beam(Module, Beam, Opts) ->
    Files = maps:get(files, Opts, []),
    Name = atom_to_list(Module),
    %% An Elixir module runs with the `elixir' application started, as it
    %% would under `elixir' or `mix'.
    Start = case Name of
                "Elixir." ++ _ -> "{ok, _} = application:ensure_all_started(elixir), ";
                _ -> ""
            end,
    Code = [Start, io_lib:format("~p:main(), halt().", [Module])],
    run([~"-pa", ~"/work", ~"-eval", iolist_to_binary(Code)],
        Opts#{files => [{"work/" ++ Name ++ ".beam", Beam} | Files]}).

-doc """
The entry point of `scripts/run.sh`: as `run_file/1`, then stop with the
guest's exit code.
""".
-spec main([string()]) -> no_return().
main([Path]) ->
    case file_result(Path, #{}) of
        {ok, #{stdout := Out, stderr := Err, exit_code := Status}} ->
            %% The guest's bytes go out as they are: with a unicode device
            %% each byte of its UTF-8 would be encoded again.
            ok = io:setopts(standard_io, [{encoding, latin1}]),
            ok = io:setopts(standard_error, [{encoding, latin1}]),
            ok = file:write(standard_io, Out),
            ok = file:write(standard_error, Err),
            halt(Status);
        {error, Reason} ->
            io:format(standard_error, "~p~n", [Reason]),
            halt(1)
    end.

-doc """
Boot the guest BEAM with `InitArgs` added after the runtime's own `init`
arguments, as you would pass them to `erl`.
""".
-spec run([binary()], map()) -> result().
run(InitArgs, Opts) ->
    %% The runner loads the guest's core modules through the module cache.
    {ok, _} = application:ensure_all_started(wasm),
    Runtime = maps:get(runtime, Opts, runtime_dir()),
    case file:read_file(filename:join(Runtime, "beam.wasm")) of
        {ok, Bin} ->
            Root = scratch_root(),
            try
                ok = copy_tree(filename:join(Runtime, "root"), Root),
                ok = write_files(Root, maps:get(files, Opts, [])),
                WasiOpts = maps:without([runtime, files, extra_preopens], Opts),
                %% The private root is `/'; `extra_preopens' adds host
                %% directories beside it, as `{GuestPath, HostDir, Writable}'.
                Mounts = [{~"/", Root, true} | maps:get(extra_preopens, Opts, [])],
                wasi_preview3:run_command(
                  Bin, <<>>,
                  WasiOpts#{args => args(Runtime, InitArgs),
                            env => env(Runtime),
                            preopens => Mounts})
            after
                _ = file:del_dir_r(Root)
            end;
        {error, Reason} ->
            {error, {no_runtime, Runtime, Reason}}
    end.

-doc """
Where the runtime is looked for: `$BEAM_ON_BEAM_RUNTIME`, else `priv/runtime`,
which `scripts/fetch-runtime.sh` fills.
""".
-spec runtime_dir() -> file:filename_all().
runtime_dir() ->
    case os:getenv("BEAM_ON_BEAM_RUNTIME") of
        false -> filename:join(code:priv_dir(beam_on_beam), "runtime");
        Dir -> Dir
    end.

%% The command line Kettlecorn's launcher builds: the emulator flags, `--',
%% then the arguments of `init'. One scheduler: the guest's threads take
%% turns, so more schedulers add nothing.
args(Runtime, InitArgs) ->
    [~"beam.wasm", ~"-S", ~"1:1"]
        ++ lines(Runtime, "launch/emulator-args")
        ++ [~"--"]
        ++ lines(Runtime, "launch/init-args")
        ++ InitArgs.

env(Runtime) ->
    [list_to_tuple(binary:split(Line, ~"="))
     || Line <- lines(Runtime, "launch/env")].

lines(Runtime, Name) ->
    {ok, Bin} = file:read_file(filename:join(Runtime, Name)),
    binary:split(Bin, ~"\n", [global, trim_all]).

%% The guest writes under its root (`/tmp', `/home'), so each run gets a copy
%% of its own, removed afterwards.
scratch_root() ->
    Name = io_lib:format("beam_on_beam-~b-~b",
                         [erlang:system_time(microsecond),
                          erlang:unique_integer([positive])]),
    filename:join(tmp_dir(), lists:flatten(Name)).

tmp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

%% Files the caller adds to the guest's root, as `{PathUnderRoot, Contents}'.
write_files(Root, Files) ->
    lists:foreach(
      fun({Path, Contents}) ->
              File = filename:join(Root, Path),
              ok = filelib:ensure_dir(File),
              ok = file:write_file(File, Contents)
      end, Files).

copy_tree(From, To) ->
    ok = filelib:ensure_path(To),
    {ok, Names} = file:list_dir(From),
    lists:foreach(
      fun(Name) ->
              Src = filename:join(From, Name),
              Dst = filename:join(To, Name),
              case filelib:is_dir(Src) of
                  true -> ok = copy_tree(Src, Dst);
                  false -> {ok, _} = file:copy(Src, Dst), ok
              end
      end, Names).
