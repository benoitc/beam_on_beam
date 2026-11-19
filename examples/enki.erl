-module(enki).
-export([main/0]).

%% Draws the Enki Multimedia logo in the terminal. The logo is a few polygons
%% with gradients; the program rasterises them itself. One process per line
%% of text computes it and sends it to the parent, which prints the lines in
%% order. A line of text is two rows of pixels: the upper half block takes
%% the top pixel as its foreground and the bottom one as its background.

-define(COLS, 60).
-define(LINES, 20).
%% The part of the logo's 100 by 100 canvas that is drawn, and a pixel's size.
-define(LEFT, 5).
-define(TOP, 20).
-define(STEP, 1.5).

main() ->
    Parent = self(),
    Lines = lists:seq(0, ?LINES - 1),
    [spawn(fun() -> Parent ! {L, line(L)} end) || L <- Lines],
    [receive {L, Text} -> io:format("~ts\e[0m~n", [Text]) end || L <- Lines],
    ok.

line(L) ->
    [cell(pixel(C, 2 * L), pixel(C, 2 * L + 1)) || C <- lists:seq(0, ?COLS - 1)].

pixel(Col, Row) ->
    colour(?LEFT + (Col + 0.5) * ?STEP, ?TOP + (Row + 0.5) * ?STEP).

cell(none, none) -> ~"\e[0m ";
cell(Top, none) -> [~"\e[0m", fg(Top), ~"▀"];
cell(none, Bottom) -> [~"\e[0m", fg(Bottom), ~"▄"];
cell(Top, Bottom) -> [fg(Top), bg(Bottom), ~"▀"].

fg({R, G, B}) -> io_lib:format("\e[38;2;~b;~b;~bm", [R, G, B]).
bg({R, G, B}) -> io_lib:format("\e[48;2;~b;~b;~bm", [R, G, B]).

%% The colour of the topmost shape that covers the point, or `none'.
colour(X, Y) ->
    colour(X, Y, lists:reverse(shapes())).

colour(_X, _Y, []) ->
    none;
colour(X, Y, [{Shape, Paint} | Rest]) ->
    case inside(X, Y, Shape) of
        true -> paint(Paint, X, Y, box(Shape));
        false -> colour(X, Y, Rest)
    end.

inside(X, Y, {ellipse, Cx, Cy, Rx, Ry}) ->
    Dx = (X - Cx) / Rx,
    Dy = (Y - Cy) / Ry,
    Dx * Dx + Dy * Dy =< 1;
inside(X, Y, {polygon, [First | _] = Points}) ->
    crossings(X, Y, Points ++ [First], 0) rem 2 =:= 1.

%% How many edges a ray from the point to the right crosses.
crossings(X, Y, [{X1, Y1}, {X2, Y2} = Next | Rest], N) ->
    Crosses = (Y1 > Y) =/= (Y2 > Y)
        andalso X < X1 + (Y - Y1) * (X2 - X1) / (Y2 - Y1),
    crossings(X, Y, [Next | Rest], case Crosses of true -> N + 1; false -> N end);
crossings(_X, _Y, _Last, N) ->
    N.

box({ellipse, Cx, Cy, Rx, Ry}) ->
    {Cx - Rx, Cy - Ry, Cx + Rx, Cy + Ry};
box({polygon, Points}) ->
    {Xs, Ys} = lists:unzip(Points),
    {lists:min(Xs), lists:min(Ys), lists:max(Xs), lists:max(Ys)}.

%% A gradient runs across the shape's own box: `down' from its top to its
%% bottom, `falling' from its top left corner to its bottom right one,
%% `rising' from its bottom left corner to its top right one.
paint({solid, RGB}, _X, _Y, _Box) ->
    RGB;
paint({Direction, Stops}, X, Y, {X0, Y0, X1, Y1}) ->
    U = (X - X0) / (X1 - X0),
    V = (Y - Y0) / (Y1 - Y0),
    T = case Direction of
            down -> V;
            falling -> (U + V) / 2;
            rising -> (U + 1 - V) / 2
        end,
    blend(T, Stops).

blend(T, [_, {At, _} = Next | Rest]) when T > At, Rest =/= [] ->
    blend(T, [Next | Rest]);
blend(T, [{A, {R1, G1, B1}}, {B, {R2, G2, B2}} | _]) ->
    K = min(1.0, max(0.0, (T - A) / (B - A))),
    {round(R1 + (R2 - R1) * K), round(G1 + (G2 - G1) * K),
     round(B1 + (B2 - B1) * K)}.

shapes() ->
    Red = {falling, [{0.0, {231, 76, 60}}, {0.5, {255, 107, 107}},
                     {1.0, {255, 140, 66}}]},
    Gold = {rising, [{0.0, {255, 165, 2}}, {0.5, {255, 140, 66}},
                     {1.0, {253, 121, 168}}]},
    Dark = {down, [{0.0, {192, 57, 43}}, {1.0, {231, 76, 60}}]},
    Orange = {solid, {255, 140, 66}},
    [{{polygon, [{45, 50}, {25, 25}, {15, 25}, {10, 35}, {20, 40}, {30, 42}]}, Red},
     {{polygon, [{45, 50}, {30, 42}, {25, 45}, {30, 48}]}, Dark},
     {{polygon, [{45, 50}, {25, 75}, {15, 75}, {10, 65}, {20, 60}, {30, 58}]}, Gold},
     {{polygon, [{45, 50}, {30, 58}, {25, 55}, {30, 52}]}, Orange},
     {{polygon, [{55, 50}, {75, 25}, {85, 25}, {90, 35}, {80, 40}, {70, 42}]}, Red},
     {{polygon, [{55, 50}, {70, 42}, {75, 45}, {70, 48}]}, Dark},
     {{polygon, [{55, 50}, {75, 75}, {85, 75}, {90, 65}, {80, 60}, {70, 58}]}, Gold},
     {{polygon, [{55, 50}, {70, 58}, {75, 55}, {70, 52}]}, Orange},
     {{ellipse, 50, 50, 3, 8}, {solid, {192, 57, 43}}},
     {{ellipse, 25, 30, 2, 2}, {solid, {231, 76, 60}}},
     {{ellipse, 75, 30, 2, 2}, {solid, {231, 76, 60}}},
     {{ellipse, 20, 50, 2, 2}, {solid, {255, 107, 107}}},
     {{ellipse, 80, 50, 2, 2}, {solid, {255, 107, 107}}},
     {{ellipse, 25, 70, 2, 2}, {solid, {255, 165, 2}}},
     {{ellipse, 75, 70, 2, 2}, {solid, {255, 165, 2}}}].
