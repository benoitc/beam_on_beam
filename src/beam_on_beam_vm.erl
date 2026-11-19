-module(beam_on_beam_vm).
-moduledoc """
A guest BEAM that stays up. `start/0` boots it once, which takes as long as
any call of `beam_on_beam`; each `run_file/2`, `run_beam/3` or `eval/2` after
that runs in the booted guest and pays only for its own work.

The host and the guest share one directory. The host puts a job there, the
guest (`priv/agent/beam_on_beam_agent.erl`) runs it and puts what it printed
beside it.
""".

-export([start/0, start/1, stop/1, run_file/2, run_beam/3, eval/2]).
-export_type([vm/0]).

-opaque vm() :: #{pid := pid(), jobs := file:filename_all()}.

-define(BOOT_TIMEOUT, 900000).
-define(JOB_TIMEOUT, 900000).
%% Past this the guest is killed, and its private root is left behind.
-define(STOP_TIMEOUT, 60000).
-define(POLL_MS, 10).

-doc "Boot a guest and wait until it takes jobs.".
-spec start() -> {ok, vm()} | {error, term()}.
start() ->
    start(#{}).

-doc "As `start/0`, with the options of `beam_on_beam:eval/2`.".
-spec start(map()) -> {ok, vm()} | {error, term()}.
start(Opts) ->
    Agent = filename:join([code:priv_dir(beam_on_beam), "agent",
                           "beam_on_beam_agent.erl"]),
    case compile:file(Agent, [binary, return_errors]) of
        {ok, Module, Beam} ->
            Jobs = beam_on_beam:scratch_root(),
            ok = filelib:ensure_path(Jobs),
            Pid = spawn(fun() -> guest(Module, Beam, Jobs, Opts) end),
            VM = #{pid => Pid, jobs => Jobs},
            case await(VM, filename:join(Jobs, "ready"), ?BOOT_TIMEOUT) of
                {ok, _} -> {ok, VM};
                {error, _} = Error -> _ = stop(VM), Error
            end;
        {error, Errors, _Warnings} ->
            {error, {compile, Errors}}
    end.

%% The guest runs in a process of its own: its one call returns when it halts.
guest(Module, Beam, Jobs, Opts) ->
    Name = atom_to_list(Module),
    Code = io_lib:format("~p:loop().", [Module]),
    Files = maps:get(files, Opts, []),
    Preopens = maps:get(extra_preopens, Opts, []),
    try
        beam_on_beam:run([~"-pa", ~"/work", ~"-eval", iolist_to_binary(Code)],
                         Opts#{files => [{"work/" ++ Name ++ ".beam", Beam} | Files],
                               extra_preopens => [{~"/jobs", Jobs, true} | Preopens]})
    after
        _ = file:del_dir_r(Jobs)
    end.

-doc "Stop the guest and remove its files.".
-spec stop(vm()) -> ok.
stop(#{pid := Pid} = VM) ->
    Mon = monitor(process, Pid),
    _ = submit(VM, stop),
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    after ?STOP_TIMEOUT ->
        exit(Pid, kill),
        receive {'DOWN', Mon, process, Pid, _} -> ok end,
        _ = file:del_dir_r(maps:get(jobs, VM)),
        ok
    end.

-doc """
Run the file `Path` in the guest and print what it wrote: a module with
`main/0`, as Erlang source (`.erl`), Elixir source (`.ex`) or compiled
(`.beam`). Sources are compiled on the host. Returns how long the guest took,
in milliseconds.
""".
-spec run_file(vm(), file:name_all()) -> {ok, non_neg_integer()} | {error, term()}.
run_file(VM, Path) ->
    maybe
        {ok, Main, Beams} ?= beam_on_beam:modules(Path),
        T0 = erlang:monotonic_time(millisecond),
        {Status, Out} ?= job(VM, {beam, Main, Beams}),
        io:format("~ts", [Out]),
        case Status of
            ok -> {ok, erlang:monotonic_time(millisecond) - T0};
            failed -> {error, job_failed}
        end
    end.

-doc "Load the compiled module `Beam` in the guest, call `Module:main()` and return what it printed.".
-spec run_beam(vm(), module(), binary()) -> {ok, binary()} | {error, term()}.
run_beam(VM, Module, Beam) ->
    result(job(VM, {beam, Module, [{Module, Beam}]})).

-doc "Evaluate `Code`, Erlang expressions ending with a dot, in the guest, and return the value printed.".
-spec eval(vm(), iodata()) -> {ok, binary()} | {error, term()}.
eval(VM, Code) ->
    result(job(VM, {eval, unicode:characters_to_list(Code)})).

result({ok, Out}) -> {ok, Out};
result({failed, Out}) -> {error, {job_failed, Out}};
result({error, _} = Error) -> Error.

job(VM, Job) ->
    maybe
        {ok, Base} ?= submit(VM, Job),
        {ok, Result} ?= await(VM, Base ++ ".result", ?JOB_TIMEOUT),
        _ = file:delete(Base ++ ".result"),
        case Result of
            <<0, Out/binary>> -> {ok, Out};
            <<1, Out/binary>> -> {failed, Out}
        end
    end.

%% A job is written under another name first: the guest reads only whole jobs.
submit(#{jobs := Jobs}, Job) ->
    Id = io_lib:format("~20..0b", [erlang:unique_integer([positive, monotonic])]),
    Base = filename:join(Jobs, lists:flatten(Id)),
    maybe
        ok ?= file:write_file(Base ++ ".new", term_to_binary(Job)),
        ok ?= file:rename(Base ++ ".new", Base ++ ".job"),
        {ok, Base}
    end.

await(#{pid := Pid} = VM, File, Left) ->
    case file:read_file(File) of
        {ok, Bin} -> {ok, Bin};
        {error, _} when Left =< 0 -> {error, timeout};
        {error, _} ->
            case is_process_alive(Pid) of
                true ->
                    timer:sleep(?POLL_MS),
                    await(VM, File, Left - ?POLL_MS);
                false ->
                    {error, guest_stopped}
            end
    end.
