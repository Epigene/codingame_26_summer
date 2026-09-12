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
    @costs = Hash.new(1)
  end

  def update_cost(node, cost)
    @costs[node] = cost
  end

  def cheapest_path(from, to)
    return [from] if from == to

    distances = Hash.new(Float::INFINITY)
    parents = {}
    distances[from] = 0

    heap = MinHeap.new
    sequence = 0
    heap.push([0, sequence, from])

    until heap.empty?
      distance, = heap.peek
      distance, _sequence, node = heap.pop

      next if distance != distances[node]
      return build_path(parents, from, to) if node == to

      neighbors(node).each do |neighbor|
        new_distance = distance + @costs[neighbor]

        next unless new_distance < distances[neighbor]

        distances[neighbor] = new_distance
        parents[neighbor] = node

        sequence += 1
        heap.push([new_distance, sequence, neighbor])
      end
    end

    nil
  end

  # Unweighted shortest path.
  def shortest_path(from, to)
    return [from] if from == to

    parents = {}
    visited = { from => true }
    queue = [from]
    head = 0

    while head < queue.length
      node = queue[head]
      head += 1

      neighbors(node).each do |neighbor|
        next if visited[neighbor]

        visited[neighbor] = true
        parents[neighbor] = node

        return build_path(parents, from, to) if neighbor == to

        queue << neighbor
      end
    end

    nil
  end

  # Compatibility with the spec's plural name.
  alias cheapest_paths cheapest_path

  private

  def neighbors(node)
    x = node.x
    y = node.y

    DIRECTIONS.filter_map do |dx, dy|
      nx = x + dx
      ny = y + dy

      next unless nx.between?(0, @width - 1)
      next unless ny.between?(0, @height - 1)

      "#{nx} #{ny}"
    end
  end

  def build_path(parents, from, to)
    path = [to]

    while path.last != from
      path << parents.fetch(path.last)
    end

    path.reverse
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
