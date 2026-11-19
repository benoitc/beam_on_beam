-module(beam_on_beam_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1, suite/0]).
-export([evaluates_erlang/1, reports_a_missing_runtime/1,
         a_booted_guest_runs_several_jobs/1]).

%% A boot takes minutes on a loaded machine.
suite() -> [{timetrap, {minutes, 20}}].

all() -> [evaluates_erlang, reports_a_missing_runtime,
          a_booted_guest_runs_several_jobs].

init_per_suite(Config) ->
    case filelib:is_regular(filename:join(beam_on_beam:runtime_dir(), "beam.wasm")) of
        true -> Config;
        false -> {skip, "no runtime: run scripts/fetch-runtime.sh"}
    end.

end_per_suite(_Config) -> ok.

evaluates_erlang(_Config) ->
    Code = "io:format(\"~s ~p~n\", [erlang:system_info(otp_release), "
           "lists:sum(lists:seq(1, 100))]), halt().",
    {ok, #{stdout := <<"29 5050\n">>, exit_code := 0}} = beam_on_beam:eval(Code).

reports_a_missing_runtime(_Config) ->
    {error, {no_runtime, "/nonexistent", enoent}} =
        beam_on_beam:eval("halt().", #{runtime => "/nonexistent"}).

a_booted_guest_runs_several_jobs(Config) ->
    Source = filename:join(proplists:get_value(priv_dir, Config), "rows.erl"),
    ok = file:write_file(Source,
                         "-module(rows).\n-export([main/0]).\n"
                         "main() ->\n"
                         "    Parent = self(),\n"
                         "    [spawn(fun() -> Parent ! {N, N * N} end) || N <- [1, 2, 3]],\n"
                         "    [receive {N, Sq} -> io:format(\"~p ~p~n\", [N, Sq]) end\n"
                         "     || N <- [1, 2, 3]],\n"
                         "    ok.\n"),
    {ok, VM} = beam_on_beam_vm:start(),
    try
        {ok, rows, [{rows, Beam}]} = beam_on_beam:modules(Source),
        {ok, ~"1 1\n2 4\n3 9\n"} = beam_on_beam_vm:run_beam(VM, rows, Beam),
        {ok, ~"1 1\n2 4\n3 9\n"} = beam_on_beam_vm:run_beam(VM, rows, Beam),
        {ok, ~"5050\n"} = beam_on_beam_vm:eval(VM, "lists:sum(lists:seq(1, 100))."),
        {error, {job_failed, _}} = beam_on_beam_vm:eval(VM, "1 = 2.")
    after
        ok = beam_on_beam_vm:stop(VM)
    end.
