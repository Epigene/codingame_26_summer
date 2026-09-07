Town = Struct.new(:id, :x, :y, :desired_connections, keyword_init: true) do
  def node
    @node ||= "#{x} #{y}"
  end
end

class Controller
  attr_reader :field, :raw_towns, :towns, :turn, :grid

  # @param field String # multiline heredoc style
  # @param towns String # a semicolon-separated list of town data | "0 11 1 x;1 1 2 0,4"
  def initialize(field:, towns:)
    @field = field
    @raw_towns = towns
    ms("> Town init") { init_towns }
  end

  # def inspect
  #   # "#<#{self.class} field=#{@field.inspect}>"
  # end

  # @param turn Integer
  # @param cells Hash # the interesting cell data
  # @return String
  def call(turn: 1, scores: [0, 0], cells: {})
    @t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @turn = turn
    debug(@raw_cells = cells)
    # init_turn_variables!

    _, start = towns.find { |k, v| v.desired_connections.any? }
    dest_id = start.desired_connections.first

    # PLACE_TRACKS x y : place a track on a free cell.
    # AUTOPLACE fromX fromY toX toY : automatically generates a list of actions for the cheapest path from from to to in terms of paint points. This will do nothing if a path already exists.
    # The generated actions replace this command.
    # WAIT : do nothing.
    return "AUTOPLACE #{start.node} #{towns[dest_id].node}"
  end

  private

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
  TURN_TIME = 45
  def turn_time_remaining
    TURN_TIME - turn_time_taken
  end
end
