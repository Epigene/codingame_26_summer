class WeightedGrid
  DIRECTIONS = [
    [0, -1], # N
    [1,  0], # E
    [0,  1], # S
    [-1, 0]  # W
  ].freeze

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

  # def cheapest_path(from, to)
  #   from = node_index(from)
  #   to = node_index(to)

  #   return nil if @removed[from] || @removed[to]
  #   return [from] if from == to

  #   distances = Array.new(@size, Float::INFINITY)
  #   parents = Array.new(@size)

  #   distances[from] = 0

  #   heap = MinHeap.new
  #   sequence = 0
  #   heap.push([0, sequence, from])

  #   until heap.empty?
  #     distance, _sequence, node = heap.pop

  #     next if distance != distances[node]
  #     return build_path(parents, from, to) if node == to

  #     @neighbors[node].each do |neighbor|
  #       next if @removed[neighbor]

  #       new_distance = distance + @costs[neighbor]
  #       next unless new_distance < distances[neighbor]

  #       distances[neighbor] = new_distance
  #       parents[neighbor] = node

  #       sequence += 1
  #       heap.push([new_distance, sequence, neighbor])
  #     end
  #   end

  #   nil
  # end

  def cheapest_path(from, to)
    from = node_index(from)
    to = node_index(to)

    return nil if @removed[from] || @removed[to]
    return [from] if from == to

    distances = Array.new(@size, Float::INFINITY)
    parents = Array.new(@size)

    distances[from] = 0

    buckets = Array.new(4) { [] }
    buckets[0] << from

    current_distance = 0
    remaining = 1

    while remaining > 0
      bucket = buckets[current_distance % 4]

      while bucket.empty?
        current_distance += 1
        bucket = buckets[current_distance % 4]
      end

      node = bucket.shift
      remaining -= 1

      # Stale entries can exist because we don't decrease-key.
      next unless distances[node] == current_distance

      return build_path(parents, from, to) if node == to

      @neighbors[node].each do |neighbor|
        next if @removed[neighbor]

        new_distance = current_distance + @costs[neighbor]

        next unless new_distance < distances[neighbor]

        distances[neighbor] = new_distance
        parents[neighbor] = node

        buckets[new_distance % 4] << neighbor
        remaining += 1
      end
    end

    nil
  end

  # Unweighted shortest path.
  def shortest_path(from, to)
    from = node_index(from)
    to = node_index(to)

    return nil if @removed[from] || @removed[to]
    return [from] if from == to

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

      @neighbors[node].each do |neighbor|
        next if @removed[neighbor] || visited[neighbor]

        visited[neighbor] = true
        parents[neighbor] = node

        return build_path(parents, from, to) if neighbor == to

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

  # @return Array<StringCell>
  def build_path(parents, from, to)
    path = [to]

    while path.last != from
      path << parents[path.last]
    end

    path.reverse.map { node_from_index(_1) }
  end

  class MinHeap
    def initialize
      @items = []
    end

    def empty?
      @items.empty?
    end

    def peek
      @items.first
    end

    def push(item)
      @items << item
      bubble_up(@items.length - 1)
    end

    def pop
      result = @items.first
      last = @items.pop

      unless @items.empty?
        @items[0] = last
        bubble_down(0)
      end

      result
    end

    private

    def bubble_up(index)
      while index > 0
        parent = (index - 1) / 2

        break if (@items[parent][0, 2] <=> @items[index][0, 2]) <= 0

        @items[parent], @items[index] = @items[index], @items[parent]
        index = parent
      end
    end

    def bubble_down(index)
      length = @items.length

      loop do
        left = index * 2 + 1
        right = left + 1
        smallest = index

        if left < length &&
          (@items[left][0, 2] <=> @items[smallest][0, 2]) < 0
          smallest = left
        end

        if right < length &&
          (@items[right][0, 2] <=> @items[smallest][0, 2]) < 0
          smallest = right
        end

        break if smallest == index

        @items[index], @items[smallest] = @items[smallest], @items[index]
        index = smallest
      end
    end
  end
end
