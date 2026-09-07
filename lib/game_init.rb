# Put the one-time game setup code that comes before `loop do` here.

# == GAME INIT ==

@width, @height = gets.split.map { |x| x.to_i }

@lines = []
@height.times do
  line = gets.chomp
  @lines << line
  debug line
end

@controller = Controller.new(field: @lines.join("\n"))
