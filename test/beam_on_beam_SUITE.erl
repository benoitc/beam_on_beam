-module(beam_on_beam_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1, suite/0]).
-export([evaluates_erlang/1, reports_a_missing_runtime/1]).

%% A boot takes minutes on a loaded machine.
suite() -> [{timetrap, {minutes, 20}}].

all() -> [evaluates_erlang, reports_a_missing_runtime].

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
