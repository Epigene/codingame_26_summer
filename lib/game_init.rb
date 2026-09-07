# Put the one-time game setup code that comes before `loop do` here.

# == GAME INIT ==

# @width, @height = gets.split.map { |x| x.to_i }

# @lines = []
# @height.times do
#   line = gets.chomp
#   @lines << line
#   debug line
# end

my_id = gets.to_i # 0 or 1
width = gets.to_i # map size
height = gets.to_i

@rows = []

height.times do
  @row = []
  width.times do
    # type: 0 (PLAINS), 1 (RIVER), 2 (MOUNTAIN), 3 (POI)
    # region_id, type = gets.split.map { |x| x.to_i }
    region, terrain_id = gets.chomp.split.map { _1.to_i }
    terrain =
      case terrain_id
      when 0
        "_"
      when 1
        "#"
      when 2
        "Δ"
      else # POI
        "T"
      end

    @row << "#{terrain}#{region.to_s.ljust(2)}"
  end
  @rows << @row.join(" ")
end

@rows.each { debug _1.to_s }

town_count = gets.to_i
@towns = []
town_count.times do
  # desired_connections: comma-separated town ids e.g. 0,1,2,3
  #town_id, town_x, town_y, desired_connections = gets.split
  #town_id = town_id.to_i
  # town_x = town_x.to_i
  #town_y = town_y.to_i
  @towns << gets.chomp
end
debug @towns.join(";")

@controller = Controller.new(field: @rows.join("\n"), towns: @towns.join(";"))
