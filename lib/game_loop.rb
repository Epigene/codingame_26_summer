debug "Game starts!"

# game loop
@turn = 0
loop do
  @turn += 1

  scores = []

  my_score = gets.chomp
  scores << my_score.to_i
  foe_score = gets.chomp
  scores << foe_score.to_i

  debug scores.to_s

  @cells = {}

  height.times do |y|
    width.times do |x|
      # instability: region inked (destroyed) when this >= 3.
      # inked: true if region is destroyed.
      # active_connections: if this cell is part of one or more railway connections, this will be town ids (separated by -) in a list separated by commas. e.g. 0-1,1-2,1-3. "x" otherwise.
      line = gets.chomp #=> -1 0 0 x
      owner, instability, inked, active_connections = line.split(" ")

      owner = owner.to_i
      instability = instability.to_i
      inked = inked.to_i
      active_connections = "" if active_connections == "x"

      # nothing has happened on cell yet
      next if owner == -1 && instability.zero? && !inked

      @cells["#{x} #{y}"] =
        if inked == 1
          :i
        else
          [owner, instability, inked, active_connections]
        end
    end
  end

  @cells.each_slice(4) { |(k, v), (k2, v2), (k3, v3), (k4, v4)| debug("\"#{k}\"=>#{v}, \"#{k2}\"=>#{v2}, \"#{k3}\"=>#{v3}, \"#{k4}\"=>#{v4},") }

  puts @controller.call(turn: @turn, scores: scores, raw_cells: @cells)
end
