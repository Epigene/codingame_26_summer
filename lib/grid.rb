# Implements a cell-based Grid - a special sub-type of a directionless and weightless graph structure.
# Node IDs are "x y" String objects monkeypatched to respond to #x and #y.
# "0 0" origin is assumed to be in the upper left, "1 1" is to the lower right of it.
# Allows special concepts like "row", "column", "straight line along a row/column", and "diagonally".
#
# Initialization gives you an empty grid. Use #add_cell to populate the grid. By default the new
# cell will be connected to all four neighbour cells and . Use kwargs to :except or :only needed connections.
# Use `add_cell(trim_excess: false)` to opt out of 'outside bounds auto-trim'
class Grid
  # Key data storage.
  # Each key is a node (key == name),
  # and the value set represents the neighbouring nodes.
  # private attr_reader :structure

  NEIGHBORS = [
    N = [0, -1].freeze, # North
    E = [1, 0].freeze, # East
    S = [0, 1].freeze, # South
    W = [-1, 0].freeze, # West
  ].freeze

  DIAGONALS = [
    NW = [-1, -1],
    NE = [1, -1],
    SW = [-1, 1],
    SE = [1, 1]
  ].freeze

  N8 = (NEIGHBORS + DIAGONALS).freeze

  attr_reader :width, :height

  # @param fill Boolean # whether to run naive structure fillout
  def initialize(width, height, fill: false)
    @width = width
    @height = height

    @structure =
      Hash.new do |hash, key|
        hash[key] = Set.new
      end

    if fill
      width.times do |x|
        height.times do |y|
          add_cell("#{x} #{y}")
        end
      end
    end
  end

  def max_x
    width - 1
  end

  def max_y
    height - 1
  end

  # Returns a new
  # @return Grid
  def dup
    duplicate = self.class.new(width, height)
    new_structure = {}
    nodes.each { new_structure[_1] = self[_1].dup }
    duplicate.instance_variable_set("@structure", new_structure)
    duplicate
  end

  # A shorthand access to underlying node structure
  def [](node)
    structure[node]
  end

  def nodes
    structure.keys
  end

  # adds a new cell node. By default all 4 neighbors, but kwars allow tweaking that.
  #
  # @param node String#x#y
  # @param except Array<neighbor>
  # @param only Array<neighbor>
  def add_cell(node, except: nil, only: nil, auto_trim: true)
    raise ArgumentError.new("Only one of :except or :only kwards is supported") if !except.nil? && !only.nil?

    neighbors = NEIGHBORS.dup

    if !except.nil?
      neighbors -= except
    elsif !only.nil?
      neighbors &= only
    end

    raise ArgumentError.new(":except/:only use made a cell have no neighbors") if neighbors.none?

    structure[node] ||= Set.new

    neighbors.each do |neighbor|
      neighbor = "#{node.x + neighbor.first} #{node.y + neighbor.last}"

      next if auto_trim && cell_outside_norms?(neighbor)

      structure[node] << neighbor
      structure[neighbor] << node
    end

    nil
  end

  def cell_outside_norms?(cell)
    cell.x.negative? ||
    cell.y.negative? ||
    cell.x > width - 1 ||
    cell.y > height - 1
  end

  # Removes a list of cells and any connections to it from the neighbors
  # @return [nil]
  def remove_cells(cells)
    cells.each do |cell|
      remove_cell(cell)
    end

    nil
  end

  # Removes the cell and any connections to it from the neighbors
  # @return [nil]
  def remove_cell(cell)
    return if structure[cell].nil?

    structure[cell].each do |other_cell|
      structure[other_cell].delete(cell)
      structure.delete(other_cell) if structure[other_cell].none?
    end

    structure.delete(cell)

    nil
  end

  # Removes one side of a possibly existing connection. Useful for creating one-way connections,
  # such as:
  #   1. "only able to leave camp, never return to it"
  #   2. "trap, only able to step on it, never leave"
  def remove_connection(from_node, to_node)
    structure[from_node].delete(to_node)
    nil
  end

  # Uses bi-directional path lookup approach, 40% more efficient than naive dijkstra
  # @return [Array<Node>, nil]
  def shortest_path(start, goal, excluding: nil)
    return [start] if start == goal

    # Initialize forward and backward search queues
    forward_queue = [start]
    backward_queue = [goal]

    # Sets to track visited nodes for both directions
    exclusions = excluding.to_a.each_with_object({}) do |node, mem|
      mem[node] = nil
    end

    forward_visited = exclusions.dup
    forward_visited[start] = nil
    backward_visited = exclusions.dup
    backward_visited[goal] = nil

    loop do
      # Expand the forward search
      unless forward_queue.empty?
        intersect = expand_layer(forward_queue, forward_visited, backward_visited, structure)
        return build_path(intersect, forward_visited, backward_visited) if intersect
      end

      # Expand the backward search
      unless backward_queue.empty?
        intersect = expand_layer(backward_queue, backward_visited, forward_visited, structure)
        return build_path(intersect, forward_visited, backward_visited) if intersect
      end

      # If neither queue can proceed, no path exists
      # return if forward_queue.empty? && backward_queue.empty?
      return if forward_queue.empty? || backward_queue.empty?
    end

    nil # No path found
  end

  # Feed in for example shortest path found to get its distance. Useful when comparing routes
  #
  # @param path [Array<cell>]
  # @return Integer
  def path_length(path)
    path.size - 1
  end

  # @return Integer
  def manhattan_distance(nodeA, nodeB)
    (nodeA.x - nodeB.x).abs + (nodeA.y - nodeB.y).abs
  end

  def manhattan_distance_from_mid(node)
    closest_mid_x = width.odd? ? (width / 2) : ([(width / 2), (width / 2) - 1].sort_by { (node.x - _1).abs }.first)
    closest_mid_y = height.odd? ? (height / 2) : ([(height / 2), (height / 2) - 1].sort_by { (node.y - _1).abs }.first)

    manhattan_distance(node, "#{closest_mid_x}_#{closest_mid_y}")
  end

  # @return Array<Coords>
  def area(x_range, y_range)
    coords = []
    x_range.each do |x|
      y_range.each do |y|
        coords << "#{x} #{y}"
      end
    end

    coords
  end

  # Useful for finding longest rows in a grid
  #
  # @return Hash # { y => [[P[0, 0], P[1, 0], P[2, 0]]] } each row lists its segment x-es
  def row_segments
    rows = Hash.new { |hash, key| hash[key] = [] }
    nodes.each do |node|
      rows[node.y] << node.x
    end

    segments = {}

    rows.each do |y, x_coords|
      x_coords.sort! # Sort x-coordinates in the row
      row_segments = []

      current_segment = ["#{x_coords.first} #{y}"]

      x_coords.each_cons(2) do |a, b|
        if b == a.next
          current_segment << Point[b, y]
        else # break in contiguity
          row_segments << current_segment

          current_segment = [Point[b, y]]
        end
      end

      # Add the last segment
      row_segments << current_segment
      segments[y] = row_segments
    end

    segments
  end

  # Given an arena of known dimensions, we can split it in two horizontal halves (odd mid column gets excluded)
  # and ask for one of the halves.
  #
  # @return Set<node>
  def horizontally_opposite_side_cells(from:)
    mid_x =
      if width.odd?
        (width - 1) / 2
      else
        mid_indexes = (0..width-1).to_a.mid
        mid_indexes.sort_by { |i| (from.x - i).abs }.first
      end

    left_root = from.x < mid_x

    nodes.each_with_object(Set.new) do |node, mem|
      on_other_side =
        if left_root
          node.x > mid_x
        else
          node.x < mid_x
        end

      mem << node if on_other_side
    end
  end

  # As in navigable neighbors # use #n8 to get just cell-geometry level data
  def neighbors(node)
    structure[node]
  end

  # assumes no out-of bounds per width*height cells are present
  # @return Array<Node> # array of node strings
  def n4(node)
    NEIGHBORS.filter_map do |delta|
      new_x = node.x + delta[0]
      new_y = node.y + delta[1]
      n = "#{new_x} #{new_y}"

      next if cell_outside_norms?(n)
      n
    end
  end

  # assumes no out-of bounds per width*height cells are present
  # @return Array<String> # array of node strings
  def n8(node)
    N8.filter_map do |delta|
      new_x = node.x + delta[0]
      new_y = node.y + delta[1]
      n = "#{new_x} #{new_y}"

      next if cell_outside_norms?(n)
      n
    end
  end

  # Returns cells that are specified distance away from a given cell. Useful for telling
  # which cells are covered by a bombard attack 2-3 cells away etc.
  #
  # @param range Range
  # @return Set
  def cells_at_distance(node, range)
    visited = Set.new
    queue = [[node, 0]] # Each element is [current_cell, current_distance]
    result = Set.new

    while queue.any?
      current_cell, current_distance = queue.shift

      # Skip if already visited
      next if visited.include?(current_cell)

      visited.add(current_cell)

      # Add to result if within the range
      if range.include?(current_distance)
        result << current_cell
      end

      # Stop exploring if the current distance exceeds the maximum range
      next if current_distance > range.max

      # Enqueue all neighbors with incremented distance
      structure[current_cell].each do |neighbor|
        queue << [neighbor, current_distance.next]
      end
    end

    result
  end

  def cells_at_diagonal_distance(node, range)
    diagonal_as_direct_ranges = range.map { (_1 * 2)..(_1 * 2) }

    cells_at_distances = diagonal_as_direct_ranges.map do |range|
      cells_at_distance(node, range)
    end.flatten.reduce { |a, b| a += b }

    cells_at_distances.reject do |cell|
      cell.x == node.x || cell.y == node.y
    end.to_set
  end

  # Assumes points on at least same row/column. Tells the cardinal direction of the pair.
  # @return String # one of %w[N E S W]
  def direction(node_a, node_b)
    if node_a.x == node_b.x && node_a.y > node_b.y
      return "N"
    elsif node_a.x == node_b.x && node_a.y < node_b.y
      return "S"
    elsif node_a.y == node_b.y && node_a.x > node_b.x
      return "W"
    elsif node_a.y == node_b.y && node_a.x < node_b.x
      return "E"
    end

    raise "Hmm, same nodes?"
  end

  private

    def structure
      @structure
    end

    def expand_layer(queue, visited, other_visited, structure)
      current_node = queue.shift

      structure[current_node].sort_by { |neighbor| manhattan_distance_from_mid(neighbor) }.each do |neighbor|
        next if visited.key?(neighbor)

        visited[neighbor] = current_node
        return neighbor if other_visited.key?(neighbor) # Intersection found

        queue << neighbor
      end

      nil
    end

    def build_path(intersect, forward_visited, backward_visited)
      path = []

      # Build path from start to intersection
      current = intersect
      while current
        path.unshift(current)
        current = forward_visited[current]
      end

      # Build path from intersection to goal
      current = backward_visited[intersect]
      while current
        path << current
        current = backward_visited[current]
      end

      path
    end
end
