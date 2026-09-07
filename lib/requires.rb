require "set"
require "benchmark"

STDOUT.sync = true # DO NOT REMOVE

def debug(message)
  STDERR.puts message
end

def ms(label, &block)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
ensure
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  elapsed_ms = (t1 - t0) * 1000.0

  debug "#{label} #{elapsed_ms.round}ms"
end

def xms(label, &block)
  block.call
end

# Monkeypatching String '1 -1' to behave like a Point, have x, y
class String
  def x
    split.first.to_i
  end

  def y
    split[1].to_i
  end
end

module QuickMaxBy
  def quick_max_by(&block)
    if one?
      first
    else
      max_by(&block)
    end
  end
  def quick_min_by(&block)
    if one?
      first
    else
      min_by(&block)
    end
  end
end

Array.include QuickMaxBy
Set.include QuickMaxBy
