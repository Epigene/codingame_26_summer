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
      # part_of_active_connections: if this cell is part of one or more railway connections, this will be town ids (separated by -) in a list separated by commas. e.g. 0-1,1-2,1-3. "x" otherwise.
      owner, instability, inked, part_of_active_connections = gets.chomp

      owner = owner.to_i
      instability = instability.to_i
      inked = inked.to_i == 1

      # nothing has happened on cell yet
      next if owner == -1 && instability.zero? && !inked

      @cells["#{x} #{y}"] = [owner, instability, inked, part_of_active_connections]
    end
  end

  debug @cells.to_s

  puts @controller.call(turn: @turn, scores: scores, cells: @cells)
end
