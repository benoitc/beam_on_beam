# Draws the Enki Multimedia logo in the terminal. The logo is a few polygons
# with gradients; the module rasterises them itself. One process per line of
# text computes it and sends it to the parent, which prints the lines in
# order. A line of text is two rows of pixels: the upper half block takes the
# top pixel as its foreground and the bottom one as its background.
defmodule Enki do
  @cols 60
  @lines 20
  # The part of the logo's 100 by 100 canvas that is drawn, and a pixel's size.
  @left 5
  @top 20
  @step 1.5

  def main do
    parent = self()

    for l <- 0..(@lines - 1), do: spawn(fn -> send(parent, {l, line(l)}) end)

    for l <- 0..(@lines - 1) do
      receive do
        {^l, text} -> IO.puts([text, "\e[0m"])
      end
    end
  end

  defp line(l) do
    for c <- 0..(@cols - 1), do: cell(pixel(c, 2 * l), pixel(c, 2 * l + 1))
  end

  defp pixel(col, row) do
    colour(@left + (col + 0.5) * @step, @top + (row + 0.5) * @step)
  end

  defp cell(nil, nil), do: "\e[0m "
  defp cell(top, nil), do: ["\e[0m", fg(top), "▀"]
  defp cell(nil, bottom), do: ["\e[0m", fg(bottom), "▄"]
  defp cell(top, bottom), do: [fg(top), bg(bottom), "▀"]

  defp fg({r, g, b}), do: "\e[38;2;#{r};#{g};#{b}m"
  defp bg({r, g, b}), do: "\e[48;2;#{r};#{g};#{b}m"

  # The colour of the topmost shape that covers the point, or nil.
  defp colour(x, y) do
    Enum.find_value(Enum.reverse(shapes()), fn {shape, paint} ->
      if inside?(x, y, shape), do: paint(paint, x, y, box(shape))
    end)
  end

  defp inside?(x, y, {:ellipse, cx, cy, rx, ry}) do
    dx = (x - cx) / rx
    dy = (y - cy) / ry
    dx * dx + dy * dy <= 1
  end

  # A ray from the point to the right crosses an odd number of edges.
  defp inside?(x, y, {:polygon, [first | _] = points}) do
    (points ++ [first])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [{x1, y1}, {x2, y2}] ->
      y1 > y != y2 > y and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1)
    end)
    |> rem(2) == 1
  end

  defp box({:ellipse, cx, cy, rx, ry}), do: {cx - rx, cy - ry, cx + rx, cy + ry}

  defp box({:polygon, points}) do
    {xs, ys} = Enum.unzip(points)
    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  # A gradient runs across the shape's own box: :down from its top to its
  # bottom, :falling from its top left corner to its bottom right one,
  # :rising from its bottom left corner to its top right one.
  defp paint({:solid, rgb}, _x, _y, _box), do: rgb

  defp paint({direction, stops}, x, y, {x0, y0, x1, y1}) do
    u = (x - x0) / (x1 - x0)
    v = (y - y0) / (y1 - y0)

    t =
      case direction do
        :down -> v
        :falling -> (u + v) / 2
        :rising -> (u + 1 - v) / 2
      end

    blend(t, stops)
  end

  defp blend(t, [_, {at, _} = next | rest]) when t > at and rest != [],
    do: blend(t, [next | rest])

  defp blend(t, [{a, {r1, g1, b1}}, {b, {r2, g2, b2}} | _]) do
    k = min(1.0, max(0.0, (t - a) / (b - a)))
    {round(r1 + (r2 - r1) * k), round(g1 + (g2 - g1) * k), round(b1 + (b2 - b1) * k)}
  end

  defp shapes do
    red = {:falling, [{0.0, {231, 76, 60}}, {0.5, {255, 107, 107}}, {1.0, {255, 140, 66}}]}
    gold = {:rising, [{0.0, {255, 165, 2}}, {0.5, {255, 140, 66}}, {1.0, {253, 121, 168}}]}
    dark = {:down, [{0.0, {192, 57, 43}}, {1.0, {231, 76, 60}}]}
    orange = {:solid, {255, 140, 66}}

    [
      {{:polygon, [{45, 50}, {25, 25}, {15, 25}, {10, 35}, {20, 40}, {30, 42}]}, red},
      {{:polygon, [{45, 50}, {30, 42}, {25, 45}, {30, 48}]}, dark},
      {{:polygon, [{45, 50}, {25, 75}, {15, 75}, {10, 65}, {20, 60}, {30, 58}]}, gold},
      {{:polygon, [{45, 50}, {30, 58}, {25, 55}, {30, 52}]}, orange},
      {{:polygon, [{55, 50}, {75, 25}, {85, 25}, {90, 35}, {80, 40}, {70, 42}]}, red},
      {{:polygon, [{55, 50}, {70, 42}, {75, 45}, {70, 48}]}, dark},
      {{:polygon, [{55, 50}, {75, 75}, {85, 75}, {90, 65}, {80, 60}, {70, 58}]}, gold},
      {{:polygon, [{55, 50}, {70, 58}, {75, 55}, {70, 52}]}, orange},
      {{:ellipse, 50, 50, 3, 8}, {:solid, {192, 57, 43}}},
      {{:ellipse, 25, 30, 2, 2}, {:solid, {231, 76, 60}}},
      {{:ellipse, 75, 30, 2, 2}, {:solid, {231, 76, 60}}},
      {{:ellipse, 20, 50, 2, 2}, {:solid, {255, 107, 107}}},
      {{:ellipse, 80, 50, 2, 2}, {:solid, {255, 107, 107}}},
      {{:ellipse, 25, 70, 2, 2}, {:solid, {255, 165, 2}}},
      {{:ellipse, 75, 70, 2, 2}, {:solid, {255, 165, 2}}}
    ]
  end
end
