-module(beam_on_beam_agent).
-moduledoc """
The loop a long-lived guest runs (`beam_on_beam_vm`). The host and the guest
share one directory, `/jobs` in the guest: the host puts a job there, the
guest runs it and puts the result beside it.
""".
-export([loop/0]).

-define(DIR, "/jobs").
-define(POLL_MS, 20).

loop() ->
    ok = file:write_file(?DIR "/ready", <<>>),
    wait().

wait() ->
    case file:list_dir(?DIR) of
        {ok, Names} ->
            case lists:sort([N || N <- Names, filename:extension(N) =:= ".job"]) of
                [Name | _] -> job(filename:join(?DIR, Name));
                [] -> timer:sleep(?POLL_MS)
            end;
        {error, _} ->
            timer:sleep(?POLL_MS)
    end,
    wait().

%% A result is one byte, 0 when the job ended normally, then what it printed.
%% It is written under another name first: the host reads only whole results.
job(File) ->
    {ok, Bin} = file:read_file(File),
    ok = file:delete(File),
    Result = run(binary_to_term(Bin)),
    Base = filename:rootname(File),
    ok = file:write_file(Base ++ ".tmp", Result),
    ok = file:rename(Base ++ ".tmp", Base ++ ".result").

run(stop) ->
    halt(0);
run({beam, Module, Beams}) ->
    capture(fun() ->
                    lists:foreach(fun load/1, Beams),
                    ok = started(atom_to_list(Module)),
                    Module:main()
            end);
run({eval, Code}) ->
    capture(fun() ->
                    {ok, Tokens, _} = erl_scan:string(Code),
                    {ok, Exprs} = erl_parse:parse_exprs(Tokens),
                    {value, Value, _} = erl_eval:exprs(Exprs, []),
                    io:format("~tp~n", [Value])
            end).

load({Module, Beam}) ->
    _ = code:purge(Module),
    {module, Module} = code:load_binary(Module, atom_to_list(Module) ++ ".beam", Beam),
    ok.

%% An Elixir module runs with the `elixir' application started.
started("Elixir." ++ _) ->
    {ok, _} = application:ensure_all_started(elixir),
    ok;
started(_) ->
    ok.

%% Run `Fun' in a process of its own whose output comes here.
capture(Fun) ->
    Me = self(),
    {Job, Mon} = spawn_monitor(fun() ->
                                       group_leader(Me, self()),
                                       Fun()
                               end),
    collect(Job, Mon, []).

collect(Job, Mon, Acc) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Acc1} = io_request(Request, Acc),
            From ! {io_reply, ReplyAs, Reply},
            collect(Job, Mon, Acc1);
        {'DOWN', Mon, process, Job, normal} ->
            iolist_to_binary([0 | lists:reverse(Acc)]);
        {'DOWN', Mon, process, Job, Reason} ->
            Report = io_lib:format("~n** the job failed: ~tp~n", [Reason]),
            iolist_to_binary([1, lists:reverse(Acc),
                              unicode:characters_to_binary(Report)])
    end.

io_request({put_chars, Encoding, Chars}, Acc) ->
    {ok, [unicode:characters_to_binary(Chars, Encoding, utf8) | Acc]};
io_request({put_chars, Encoding, M, F, A}, Acc) ->
    io_request({put_chars, Encoding, apply(M, F, A)}, Acc);
io_request({put_chars, Chars}, Acc) ->
    io_request({put_chars, latin1, Chars}, Acc);
io_request({put_chars, M, F, A}, Acc) ->
    io_request({put_chars, latin1, apply(M, F, A)}, Acc);
io_request({requests, Requests}, Acc) ->
    lists:foldl(fun(Request, {_, A}) -> io_request(Request, A) end,
                {ok, Acc}, Requests);
io_request(getopts, Acc) ->
    {[{encoding, unicode}], Acc};
io_request(_Other, Acc) ->
    {{error, enotsup}, Acc}.
