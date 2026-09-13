Town = Struct.new(:id, :x, :y, :desired_connections, keyword_init: true) do
  def node
    @node ||= "#{x} #{y}"
  end

  def cell
    $cells[node]
  end

  def region
    $regions[cell.region_id]
  end
end

Region = Struct.new(:id, :instability, :inked, :cells, keyword_init: true) do
  attr_accessor :has_town

  def inkable?
    !has_town
  end
end

Cell = Struct.new(:x, :y, :cost, :region_id, keyword_init: true) do
  attr_accessor :town, :owner, :instability, :inked, :connections

  def node
    @node ||= "#{x} #{y}"
  end

  def buildable?
    (owner.nil? || owner == -1) && !inked? && !town?
  end

  # @return Integer # how many active connections and thus points this scores
  def scoring
    connections.size
  end

  def town?
    town == true
  end

  def region
    $regions[region_id]
  end

  def inkable?
    region.inkable?
  end

  def inked?
    inked
  end

  def my?
    owner == $my_id
  end

  def opp?
    owner == $opp_id
  end

  def inspect
    "'#{node}':#{cost} region=#{region_id} owner=#{owner} conns=#{connections}"
  end
end

class Controller
  attr_reader :my_id, :field, :raw_towns, :towns, :turn, :scores, :raw_cells,
    :cheapest_connections
  attr_accessor :placements

  # @param field String # multiline heredoc style
  # @param towns String # a semicolon-separated list of town data | "0 11 1 x;1 1 2 0,4"
  def initialize(my_id:, field:, towns:)
    $my_id = my_id
    $opp_id = (my_id == 0) ? 1 : 0
    @field = field
    @raw_towns = towns
    ms("> Town init") { init_towns }
    ms("> Grid init") { init_grid }
    ms("> Cheapest connection init") { init_cheapest_connections }
  end

  # @param turn Integer
  # @param cells Hash # the interesting cell data
  # @return String
  def call(turn: 1, scores: [0, 0], raw_cells: {})
    @t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @turn = turn
    @raw_cells = raw_cells
    update_cells!
    @placements = []

    # -- Key rails placing logic
    determine_placements
    # --

    # -- Opp scoring and disruption
    op_cells_by_region = $cells.select { |k, v| v.opp? && v.inkable? }.group_by { |k, v| v.region_id }

    most_scoring_region = op_cells_by_region.to_a.map do |region_id, cells|
      sum = cells.map { |node, cell| cell.scoring }.sum
      [region_id, sum]
    end.sort_by { |k, v| -v }.first

    most_celled_region = op_cells_by_region.to_a.map do |region_id, cells|
      sum = cells.size
      [region_id, sum]
    end.sort_by { |k, v| -v }.first

    disruptable_region_id = (most_scoring_region || [])[0]
    disruptable_region_id = most_celled_region[0] if (most_celled_region || [])[1].to_i > (most_scoring_region || [])[1].to_i.next
    # --

    # PLACE_TRACKS x y : place a track on a free cell.
    # AUTOPLACE fromX fromY toX toY : automatically generates a list of actions for the cheapest path from from to to in terms of paint points. This will do nothing if a path already exists.
    # The generated actions replace this command.
    # DISRUPT regionId || DISRUPT x y
    # WAIT : do nothing.
    c = [
      *placements.map { "PLACE_TRACKS #{_1}" },
      ("DISRUPT #{disruptable_region_id}" if disruptable_region_id)
    ].compact.join("; ")

    return c != "" ? c : "WAIT"
  end

  private

  # @return nil # side-effects of populating @placements only
  def determine_placements
    cheapest_connections.each_pair do |id, path|
      candidates = path.select { $cells[_1].buildable? }.sort_by { $cells[_1].cost }.first(3-placements.size)
      self.placements += candidates

      break if self.placements.size >= 3
    end

    nil
  end

  #===================
  #  INSPECTION METHODS
  #===================

  # @param path Array # sans town cells, only the connecting rail cells
  def path_cost(path)
    sum = 0
    path.each do |node|
      sum += $cells[node].cost
    end
    sum
  end

  def path_turns(path)
    (path_cost(path) / 3.0).ceil
  end

  # Scoring is a bit tricky. We assume best scenario for us - unowned cells will become ours.
  def path_scoring(path)
    turns = path_turns(path)
    length = path.size

    length / turns.to_f
  end

  #===================
  #  GAME INIT SETUP BELOW
  #===================

  # @return Hash # { id => Town}
  def init_towns
    @towns ||= raw_towns.split(";").each_with_object({}) do |input, mem|
      id, x, y, desired_connections = input.split(" ")
      id = id.to_i

      desired_connections =
        if desired_connections == "x"
          Set.new
        else
          desired_connections.split(",").map(&:to_i).to_set
        end

      mem[id] = Town.new(id: id, x: x, y: y, desired_connections: desired_connections)
    end
  end

  def init_grid
    rows = field.split("\n")
    columns = rows.first.split(%r'\s+').size

    $grid = WeightedGrid.new(_width = columns, _height = rows.size)
    $regions = {}
    $cells = {}

    rows.each_with_index do |row, y|
      row.split(%r'\s+').each_with_index do |plot, x|
        node = "#{x} #{y}"

        cost =
          case plot[0]
          when "#"
            2
          when "Δ"
            3
          else
            1
          end

        region_id = plot[1..].to_i

        $regions[region_id] ||= Region.new(id: region_id, instability: 0, inked: false, cells: Set.new)
        $regions[region_id].cells << node

        $cells[node] = Cell.new(x: x, y: y, cost: cost, region_id: region_id)

        $grid.update_cost(node, cost)
      end
    end

    towns.each_pair do |id, town|
      town.cell.town = true
      town.region.has_town = true
    end

    nil
  end

  def init_cheapest_connections
    @cheapest_connections = {}

    towns.each_pair do |id, town|
      town.desired_connections.each do |dest_id|
        destination = towns[dest_id]
        path = $grid.cheapest_path(town.node, destination.node)

        @cheapest_connections["#{town.id},#{destination.id}"] = path[1..-2]
      end
    end


    @cheapest_connections = @cheapest_connections.to_a
      # prefer fewer-turn paths, but among equal-turn, prefer longer ones since they score more.
      .sort_by { |id, path| [path_turns(path), -path_scoring(path)] }
      .to_h

    nil
  end

  #===================
  #  TURN INIT BELOW
  #===================

  def update_cells!
    raw_cells.each_pair do |node, data|
      if data == :i
        $cells[node].owner = nil
        $cells[node].instability = 4
        $cells[node].inked = true
        $cells[node].connections = Set.new
        next
      end

      $cells[node].owner = data[0]
      $cells[node].instability = data[1]
      $cells[node].inked = data[2] == 1
      $cells[node].connections = data[3].split(",").map { _1.gsub("-", ",") }.to_set
    end
  end

  def init_time_taken
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed_ms = ((t1 - init_start) * 1000.0).round
  end

  INIT_TIME = 950
  def init_time_remaining
    INIT_TIME - init_time_taken
  end

  # @return Numeric # in ms
  def turn_time_taken
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed_ms = ((t1 - t0) * 1000.0).round
  end

  # using a value somewhat lower than 50ms stated in rules for safety
  # @return Numeric # in ms
  TURN_TIME = 45
  def turn_time_remaining
    TURN_TIME - turn_time_taken
  end
end
