# One process per row computes it and sends it to the parent, which prints
# the rows in order.
parent = self()

for y <- 0..15 do
  spawn(fn ->
    row = for x <- 0..y, into: "",
      do: if(Bitwise.band(x, y) == x, do: "██", else: "  ")

    send(parent, {y, row})
  end)
end

for y <- 0..15 do
  receive do
    {^y, row} -> IO.puts(String.pad_leading(row, y + 17))
  end
end
