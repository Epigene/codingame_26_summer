# Put the one-time game setup code that comes before `loop do` here.

# == GAME INIT ==

my_id = gets.to_i # 0 or 1
width = gets.to_i # map size
height = gets.to_i

debug "#{my_id},#{width},#{height}"

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
        "."
      when 1
        "#"
      when 2
        "Δ"
      else # POI
        "P"
      end

    @row << "#{terrain}#{region.to_s.ljust(2)}"
  end
  @rows << @row.join(" ")
end

@rows.each { debug _1.to_s }

town_count = gets.to_i
@towns = []
town_count.times do
  # town_id, town_x, town_y, desired_connections = gets.split
  # town_id = town_id.to_i
  # town_x = town_x.to_i
  # town_y = town_y.to_i
  # desired_connections: comma-separated town ids e.g. 0,1,2,3
  @towns << gets.chomp
end

debug @towns.join(";") #=> "0 11 1 x;1 1 2 0,4;2 6 6 0,1;3 18 8 0,1;4 1 10 0,2,3"

@controller = Controller.new(my_id: my_id, field: @rows.join("\n"), towns: @towns.join(";"))
