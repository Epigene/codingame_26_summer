class WeightedGrid
  # Direction index itself is the tie-break priority:
  # N = 0, E = 1, S = 2, W = 3
  DIRECTIONS = [
    [0, -1], # N
    [1,  0], # E
    [0,  1], # S
    [-1, 0]  # W
  ].freeze

  INF = Float::INFINITY

  def initialize(width, height)
    @width = width
    @height = height
    @size = width * height

    @costs = Array.new(@size, 1)
    @removed = Array.new(@size, false)

    @neighbors = Array.new(@size) { [] }

    height.times do |y|
      width.times do |x|
        node = y * width + x
        neighbors = @neighbors[node]

        neighbors << node - width if y > 0
        neighbors << node + 1 if x < width - 1
        neighbors << node + width if y < height - 1
        neighbors << node - 1 if x > 0
      end
    end
  end

  # @param from String # monkeypatched to respond to #x and #y
  # @return Array<StringCell>,nil
  def cheapest_path(from, to)
    from = node_index(from)
    to = node_index(to)

    return [] if @removed[from] || @removed[to]
    return [node_from_index(from)] if from == to

    distances = Array.new(@size, INF)
    parents = Array.new(@size)
    path_keys = Array.new(@size)

    distances[from] = 0
    path_keys[from] = +""

    # Four buckets are enough in principle, but we keep a bucket for
    # each possible distance modulo 4.
    buckets = Array.new(4) { [] }

    buckets[0] << [from, 0, +""]

    current_distance = 0
    remaining = 1

    while remaining > 0
      bucket = buckets[current_distance & 3]

      # Entries can remain in buckets after becoming stale.
      while bucket.empty?
        current_distance += 1
        bucket = buckets[current_distance & 3]
      end

      # Among equal-distance entries, select the lexicographically
      # smallest NESW direction sequence.
      best_index = 0
      best_entry = bucket[0]

      i = 1
      while i < bucket.length
        entry = bucket[i]

        if entry[1] < best_entry[1] ||
           (entry[1] == best_entry[1] && entry[2] < best_entry[2])
          best_index = i
          best_entry = entry
        end

        i += 1
      end

      node, distance, key = bucket.delete_at(best_index)
      remaining -= 1

      # Stale entry.
      next unless distance == distances[node] && key == path_keys[node]

      return build_path(parents, from, to) if node == to

      neighbors = @neighbors[node]

      i = 0
      while i < neighbors.length
        neighbor = neighbors[i]
        i += 1

        next if @removed[neighbor]

        cost = @costs[neighbor]
        new_distance = distance + cost

        # Direction is determined from the two node indices.
        direction = direction_between(node, neighbor)
        new_key = key + direction

        if new_distance < distances[neighbor] ||
           (new_distance == distances[neighbor] &&
            (path_keys[neighbor].nil? || new_key < path_keys[neighbor]))

          distances[neighbor] = new_distance
          parents[neighbor] = node
          path_keys[neighbor] = new_key

          buckets[new_distance & 3] << [neighbor, new_distance, new_key]
          remaining += 1
        end
      end
    end

    nil
  end

  # Unweighted shortest path.
  #
  # NESW order is naturally preserved by BFS.
  def shortest_path(from, to)
    from = node_index(from)
    to = node_index(to)

    return [] if @removed[from] || @removed[to]
    return [node_from_index(from)] if from == to

    parents = Array.new(@size)
    visited = Array.new(@size, false)

    queue = Array.new(@size)
    head = 0
    tail = 0

    queue[tail] = from
    tail += 1
    visited[from] = true

    while head < tail
      node = queue[head]
      head += 1

      neighbors = @neighbors[node]

      i = 0
      while i < neighbors.length
        neighbor = neighbors[i]
        i += 1

        next if @removed[neighbor] || visited[neighbor]

        parents[neighbor] = node

        return build_path(parents, from, to) if neighbor == to

        visited[neighbor] = true
        queue[tail] = neighbor
        tail += 1
      end
    end

    nil
  end

  def remove_node(node)
    @removed[node_index(node)] = true
  end

  def update_cost(node, cost)
    @costs[node_index(node)] = cost
  end

  private

  def node_index(node)
    node.y * @width + node.x
  end

  def node_from_index(index)
    "#{index % @width} #{index / @width}"
  end

  def direction_between(from, to)
    delta = to - from

    if delta == -@width
      "0" # N
    elsif delta == 1
      "1" # E
    elsif delta == @width
      "2" # S
    else
      "3" # W
    end
  end

  def build_path(parents, from, to)
    path = [to]

    while path.last != from
      path << parents[path.last]
    end

    path.reverse.map { node_from_index(_1) }
  end
end
