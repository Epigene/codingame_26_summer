debug "Game starts!"

# game loop
@turn = 0
loop do
  @turn += 1

  lines = [
    gets.chomp,
    gets.chomp,
    gets.chomp
  ]

  lines.last.to_i.times do
    lines << gets.chomp
  end

  lines << gets.chomp
  lines.last.to_i.times do
    lines << gets.chomp
  end

  puts @controller.call(turn: @turn, input: lines.join("\n"))
end
