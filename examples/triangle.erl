-module(triangle).
-export([main/0]).

%% One process per row computes it and sends it to the parent, which prints
%% the rows in order.
main() ->
    Parent = self(),
    [spawn(fun() -> Parent ! {Y, row(Y)} end) || Y <- lists:seq(0, 15)],
    [receive
         {Y, Row} ->
             io:format("~ts~ts~n", [lists:duplicate(15 - Y, $\s), Row])
     end || Y <- lists:seq(0, 15)],
    ok.

row(Y) ->
    [case X band Y of
         X -> ~"██";
         _ -> ~"  "
     end || X <- lists:seq(0, Y)].
