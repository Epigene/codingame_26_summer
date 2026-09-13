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

Region = Struct.new(:id, keyword_init: true) do
  attr_accessor :has_town

  def nodes
    @nodes ||= Set.new
  end

  def inkable?
    !has_town
  end

  def instability
    example_cell.instability
  end

  def inked?
    example_cell.inked?
  end

  def cells
    nodes.map { $cells[_1] }
  end

  # how many points per turn I get if this keeps being uninked
  def my_scoring
    cells.select(&:my?).flat_map { _1.connections.to_a }.uniq
      .sum { $connections[_1].my_scoring }
  end

  # how many points per turn OPP gets if this keeps being uninked
  def opp_scoring
    # binding.pry
    cells.select(&:opp?).flat_map { _1.connections.to_a }.uniq
      .sum { $connections[_1].opp_scoring }
  end

  private

  def example_cell
    $cells[nodes.first]
  end
end

Connection = Struct.new(:id, keyword_init: true) do
  def nodes
    @nodes ||= Set.new
  end

  # @return Integer
  def my_scoring
    nodes.sum { $cells[_1].my? ? 1 : 0 }
  end

  # @return Integer
  def opp_scoring
    nodes.sum { $cells[_1].opp? ? 1 : 0 }
  end
end

Cell = Struct.new(:x, :y, :cost, :region_id, keyword_init: true) do
  attr_accessor :town, :owner, :instability, :inked, :connections

  def node
    @node ||= "#{x} #{y}"
  end

  def instability
    @instability || 0
  end

  def connections
    @connections ||= Set.new
  end

  def buildable?
    (owner.nil? || owner == -1) && !inked? && !town?
  end

  def likely_scorable_by_me?
    my? || buildable?
  end

  def likely_scorable_by_opp?
    opp? || buildable?
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
    :cheapest_connections, :t0, :t1
  attr_accessor :placements, :disruptable_region_id

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
    ms("> Cheapest connection turn init #{turn}") { init_cheapest_connections }
    @placements = []

    # -- Key rails placing logic
    determine_placements
    raise("DUPLICATE PLACEMENTS DETECTED! placements:#{placements}") if placements.size != placements.uniq.size
    # --

    # -- Opp scoring and disruption
    ms("> disruptable_region #{turn}") { determine_disruptable_region_id }
    #--

    # PLACE_TRACKS x y : place a track on a free cell.
    # AUTOPLACE fromX fromY toX toY : automatically generates a list of actions for the cheapest path from from to to in terms of paint points. This will do nothing if a path already exists.
    # The generated actions replace this command.
    # DISRUPT regionId || DISRUPT x y
    # WAIT : do nothing.
    c = [
      *placements.map { "PLACE_TRACKS #{_1}" },
      ("DISRUPT #{disruptable_region_id}" if disruptable_region_id)
    ].compact.join("; ")

    raise("Oops, ran out of time. Turn #{turn} took #{turn_time_taken}") if turn_time_remaining <= 0

    return c != "" ? c : "WAIT"
  end

  private

  SHUFFLABLE_COST = [1, 1, 2].freeze

  # @return nil # side-effects of populating @placements only
  def determine_placements
    # 1. working on finishing connections
    cheapest_connections.each_pair do |id, path|
      # TODO, if path consists of unbuilt 1,1,2,2 prefer [1,2],[1,2] not [1, 1],[2],[2]

      candidates = (path - placements).select { $cells[_1].buildable? }
        .sort_by { [$cells[_1].cost, $cells[_1].inkable? ? 1 : 0] }
        .first(3-placements.size)

      if placements.none? && candidates.map { $cells[_1].cost } == SHUFFLABLE_COST
        self.placements = [candidates.first, candidates.last]
        break
      end

      self.placements += candidates

      break if self.placements.size >= 3
    end

    # TODO 2. optimizing connections so that we take rails away from OPP.
    # idea, raise when this would have been best move to get situations

    nil
  end

  def determine_disruptable_region_id
    op_cells_by_region = $cells.select { |k, v| v.opp? && v.inkable? }.group_by { |k, v| v.region_id }

    if_inked_changes = {}

    op_cells_by_region.each_pair do |region_id, opp_cells|
      region = $regions[region_id]
      my_loss = region.my_scoring
      opp_loss = region.opp_scoring

      diff = (opp_loss * region.instability) - my_loss
      if_inked_changes[region_id] = { me: my_loss, opp: opp_loss, diff: diff}
    end

    region_id, data = if_inked_changes
      .select { |region_id, data| data[:diff].positive? }
      .sort_by { |region_id, data| [-data[:diff], -$regions[region_id].cells.select(&:opp?).size] }
      .first

    return self.disruptable_region_id = region_id if region_id

    # If got here means nothing is scoring yet.
    _, path = cheapest_connections
      .select { |k, path| path_opp_length(path) >= 2 }
      .sort_by { |k, path| [path_turns(path), -path_opp_scoring(path)] }
      .first

    return if path.nil?

    region_id, score = path.each_with_object(Hash.new(0)) do |node, mem|
      cell = $cells[node]
      next unless cell.region.inkable?

      mem[cell.region_id] += (cell.opp? ? 2 : 0) + (cell.buildable? ? 1 : 0)
    end.max_by { _2 }

    self.disruptable_region_id = region_id
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
    likely_owned_length = path_likely_owned_length(path)

    likely_owned_length / turns.to_f
  end

  def path_opp_scoring(path)
    turns = path_turns(path)
    likely_owned_length = path_likely_opp_length(path)

    likely_owned_length / turns.to_f
  end

  def path_likely_owned_length(path)
    path.sum { $cells[_1].likely_scorable_by_me? ? 1 : 0 }
  end

  # -- Definitely opp's VS maybe
  def path_opp_length(path)
    path.sum { $cells[_1].opp? ? 1 : 0 }
  end

  def path_likely_opp_length(path)
    path.sum { $cells[_1].likely_scorable_by_opp? ? 1 : 0 }
  end
  #--

  #===================
  #  Per-turn gamestate refresh
  #===================

  def update_cells!
    $connections = {}

    raw_cells.each_pair do |node, data|
      if data == :i
        $cells[node].owner = nil
        $cells[node].instability = 4
        $cells[node].inked = true
        $cells[node].connections = Set.new
      else
        owner = data[0]
        $cells[node].owner = owner
        $cells[node].instability = data[1]
        $cells[node].inked = data[2] == 1
        $cells[node].connections = data[3].split(",").map { _1.gsub("-", ",") }.to_set

        # cost of zero for already built cells will play a role in cheapest path determination
        $cells[node].cost = 0 if owner == 0 || owner == 1 || owner == 2 || $cells[node].town?
      end

      $grid.remove_node(node) if $cells[node].inked?
      $grid.update_cost(node, $cells[node].cost)

      $cells[node].connections.each do |connection_id|
        $connections[connection_id] ||= Connection.new(id: connection_id)
        $connections[connection_id].nodes << node
      end
    end
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

        $regions[region_id] ||= Region.new(id: region_id)
        $regions[region_id].nodes << node

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
        next if path.nil?

        @cheapest_connections["#{town.id},#{destination.id}"] = path[1..-2]
      end
    end

    @cheapest_connections = @cheapest_connections.to_a
      # throwing away already built cheapest paths
      .select { |id, path| !$cells[path.first].connections.include?(id) }
      # prefer fewer-turn paths, but among equal-turn, prefer longer ones since they score more.
      .sort_by { |id, path| [path_turns(path), -path_scoring(path)] }
      .to_h

    nil
  end

  #===================
  #  TURN INIT BELOW
  #===================

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
  TURN_TIME = 50
  def turn_time_remaining
    TURN_TIME - turn_time_taken
  end
end
