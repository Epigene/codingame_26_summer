# Camp = Struct.new(:my, :x, :y) do
#   def node
#     @node ||= "#{x} #{y}"
#   end
# end

class Controller
  # attr_reader :field, :turn, :input, :grid,

  # @param field String # multiline heredoc style
  def initialize(field:)
    # @field = field
    # ms("> Grid init") { init_grid }
  end

  # def inspect
  #   # "#<#{self.class} field=#{@field.inspect}>"
  # end

  # @param turn Integer
  # @param input String # the raw as-is multiline input provided by game
  # @return String
  def call(turn:, input:)
    @t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @turn = turn
    debug(@input = input)
    init_turn_variables!
    @training = nil
    @messages = []
    @plans = {} # worker-id-keyed

    if turn <= 1 && !use_shortscale?
      # in how many turns is it OK to scale straight to chopper. Can probably go lower than 70, maybe 50.
      if turns_till_chopper > 65
        potential_worker = my_inventory.best_intermediate_worker(my_workers.size)
        if potential_worker
          @training = "TRAIN #{potential_worker}"
        end
      end
    end

    if chopper.nil? && my_inventory.can_afford?(best_prediction.costs)
      debug("= OK, time to get chopper #{best_prediction.name} and start chopping!")
      @training = "TRAIN #{best_prediction.name}"
    end

    if chopper
      ms("> chopper plan calc") do
        organize_chopping(chopper)
      end
    end

    ms("> helper plan calc") do
      organize_helper(helper) # helper is calculated before inter because inter will be able to work around helper
    end

    if inter
      ms("> inter plan calc") do
        organize_intermediate(inter)
      end
    end

    result = [
      messages.any? ? "MSG #{messages.join(", ")}" : nil,
      training,
      *plans.values.sort_by { -_1.weight }.map(&:command)
    ].compact.join("; ")

    if turn_time_remaining > 5
      prefill_tree_paths
    end

    elapsed_ms = turn_time_taken
    debug("== turn #{turn} took #{elapsed_ms}ms to calculate")
    raise("Turn #{turn} took #{elapsed_ms}ms to calculate, too slow!") if elapsed_ms > 55

    result == "" ? "WAIT" : result
  end
  # Each turn you can print any number of commands, separated by ;.
  # MOVE id x y Move troll id to cell (x, y).
  # HARVEST id Make troll id harvest on its current cell.
  # PLANT id type Make troll id plant a type on its current cell: PLUM, LEMON, APPLE or BANANA.
  # CHOP id Make troll id chop on its current cell.
  # PICK id type Make troll id pick one type from the shack: PLUM, LEMON, APPLE or BANANA.
  # DROP id Make troll id drop all carried items at the shack.
  # TRAIN moveSpeed carryCapacity harvestPower chopPower | Train a new troll with the given attributes.
  # MINE id Make troll id mine a nearby IRON.
  # WAIT to do nothing.
  # MSG text to display a message in the replay.

  private

  # @return Prediction
  def predict(move, carry, harvest, chop)
    xms("== #{move} #{carry} #{harvest} #{chop} chopper") do
      costs = worker_cost(move, carry, harvest, chop)

      turns =
        turns_to_gather("PLUM", costs["PLUM"] - my_inventory.plum) +
        turns_to_gather("LEMON", costs["LEMON"] - my_inventory.lemon) +
        turns_to_gather("APPLE", costs["APPLE"] - my_inventory.apple) +
        turns_to_gather("IRON", costs["IRON"] - my_inventory.iron)

      remaining_turns = 300 - (turn + turns)

      p = Prediction.new(
        move, carry, harvest, chop, costs, turns, remaining_turns
      )
      p.report
      p
    end
  end

  def organize_chopping(worker)
    # interrupt hobbling if full of wood and their seed trees will take time to grow
    if worker.carry_wood.positive? && worker.full?
      turns_till_opp_lemon =
        trees.select { _1.type?("LEMON") }
        .select { nodes_within_3_of_opp_camp.include?(_1.node) }
        .map { _1.turns_till_fruit }.min

      if turns_till_opp_lemon.nil? || turns_till_opp_lemon > 12
        return go_and_drop(worker, closest_dropoff(worker.node))
      end
    end

    # OPP HOBBLING, comes before unloading wood
    if inter.nil? && (my_workers.size >= workers.select { !_1.my? }.size) && chopper.carry_capacity > workers.select { !_1.my? }.max_by(&:carry_capacity).carry_capacity
      debug("- chopper checking need to eliminte opp's lemons")

      opps_wet_lemontree, _dist = trees.select { _1.type?("LEMON") }
        .select { wet_nodes_within_3_of_opp_camp.include?(_1.node) }
        .map do |tree|
          [
            tree,
            tree.turns_till_fruit_in_hand(worker, shortest_path(worker.node, tree.node))
          ]
        end
        .sort_by { |tree, dist_from_opp| [dist_from_opp, shortest_path(worker.node, tree.node).size] }.first
      if opps_wet_lemontree
        messages << "hee hee"
        return go_and_chop(worker, opps_wet_lemontree.node)
      end

      opps_dry_lemontree, _dist = trees.select { _1.type?("LEMON") }
        .select { nodes_within_3_of_opp_camp.include?(_1.node) }
        .map do |tree|
          [
            tree,
            tree.turns_till_fruit_in_hand(worker, shortest_path(worker.node, tree.node))
          ]
        end
        .sort_by { |tree, dist_from_opp| [dist_from_opp, shortest_path(worker.node, tree.node).size] }.first
      if opps_dry_lemontree
        messages << "hee hee"
        return go_and_chop(worker, opps_dry_lemontree.node)
      end
    end

    # 0. unload if carrying wood for some reason
    if (trees.any?(&:grown?) ? worker.carry_wood.positive? : worker.full?) || (worker.full? && worker.carry_iron.positive?)
      return go_and_drop(worker, closest_dropoff(worker.node))
    end

    # WAR, seek to fight over chopping if opp within 2 turns can be cought
    chop_wars(worker)
    return if plans[worker.id]

    # 0, if outside base squares (beelined previously), continue on to nearest grown tree
    # if !nodes_within_3_of_camp.include?(worker.node)
    #   closest_grown_tree = trees.select(&:grown?).min_by { shortest_path(worker.node, _1.node).size }
    #   if closest_grown_tree
    #     messages << "beeline"
    #     return go_and_chop(worker, closest_grown_tree.node)
    #   end
    # end

    # 0, ENDGAME CLEAR
    if turn > 287
      nearby_bananas = nodes_within_3_of_camp
        .select { cells[_1]&.tree && cells[_1].tree.grown? && cells[_1].tree.type?("BANANA") }

      if nearby_bananas.any?
        node = nearby_bananas.quick_min_by { shortest_path(worker.node, _1).size }
        messages << "fullclear"
        go_and_chop(worker, node)
        return
      end

      nearby_non_bananas = nodes_within_3_of_camp
        .select { cells[_1]&.tree && cells[_1].tree.grown? && !cells[_1].tree.type?("BANANA") }

      if nearby_non_bananas.any?
        node = nearby_non_bananas.quick_min_by { shortest_path(worker.node, _1).size }
        messages << "fullclear"
        go_and_chop(worker, node)
        return
      end
    end

    # 1. clear seed node if it does not have a banana on it
    if cells[seed_node]&.tree && !cells[seed_node].tree.type?("BANANA")
      return go_and_chop(worker, seed_node)
    end

    # 2. seed is open, now chop bananas
    choppable = nodes_within_3_of_camp_except_seed
      .select { cells[_1]&.tree && cells[_1].tree.type?("BANANA") && cells[_1].tree.choppable_for_full_yield(worker.chop_power) }

    if choppable.any?
      closest = choppable.min_by { shortest_path(worker.node, _1).size }
      return go_and_chop(worker, closest)
    end

    grown_next_to_seed = nodes_within_3_of_camp_except_seed
      .select { cells[_1]&.tree && cells[_1].tree.grown? && grid.neighbors(seed_node).include?(_1) }

    if grown_next_to_seed.any?
      closest = grown_next_to_seed.min_by { shortest_path(worker.node, _1).size }
      return go_and_chop(worker, closest)
    end

    grown = nodes_within_3_of_camp_except_seed
      .select { cells[_1]&.tree && cells[_1].tree.grown? }

    if grown.any?
      closest = grown.min_by { shortest_path(worker.node, _1).size }
      return go_and_chop(worker, closest)
    end

    debug("= Hmm, no choppable trees, guess lets go to soonest choppable")

    growing = nodes_within_3_of_camp_except_seed
      .select { cells[_1]&.tree && cells[_1].tree.turns_till_size(4) <= 2 }

    if growing.any?
      growest = growing.min_by { cells[_1].tree.turns_till_size(4) }

      if worker.node == growest # already there!
        debug("= Chopper waiting on a growing tree")
        return
      else # go if not there
        return go(worker, growest)
      end
    end

    debug("= Hmmmm, no choppable nor growing trees, helper slacking off?")

    closest_grown_tree = trees
      .select { _1.grown? && _1.node != seed_node }
      .min_by { shortest_path(worker.node, _1.node).size }

    if closest_grown_tree
      messages << "beeline"
      return go_and_chop(worker, closest_grown_tree.node)
    end

    debug("= D'oh, no grown trees, checking any trees")

    closest_tree = trees.min_by { shortest_path(worker.node, _1.node).size }
    if closest_tree
      messages << "slim pickings"
      return go_and_chop(worker, closest_tree.node)
    end

    debug("= no trees on map, entering endgame")
    messages << "hugging opp"
    go_and_chop(worker, opp_dropoff_nodes.min_by { shortest_path(worker.node, _1).size })
  end

  def organize_helper(worker)
    # 0. unload if carrying wood for some reason
    if worker.carry_wood.positive? || (worker.full? && worker.carry_iron.positive?)
      return go_and_drop(worker, closest_dropoff(worker.node))
    end

    # WAR, seek to fight over chopping if opp within 2 turns can be cought
    chop_wars(worker)
    return if plans[worker.id]

    # ENDGAME, I'm winning, let's liquidate
    if my_inventory.score > opp_inventory.score + 40 && trees.size < 6
      tree = trees.min_by { shortest_path(worker.node, _1.node) }
      messages << "endgame"
      seek_to_chop(worker, tree.node) if tree
    end
    return if plans[worker.id]

    if use_shortscale? && chopper.nil? && best_prediction
      debug("- helper will SHORTscale to #{best_prediction.name}")

      # Too risky, need to maintain tiered gather approach
      # harvest_already_stood_on_tree(
      #   worker,
      #   *[(my_inventory.lemon < aimed_chopper_cost["LEMON"] ? "LEMON" : nil), (my_inventory.plum < aimed_chopper_cost["PLUM"] ? "PLUM" : nil)].compact
      # )

      best_prediction.satisfyable_tiers(my_workers.size).each do |tier_data|
        # == next if tier already gathered ==
        tier_cost = worker_cost(*tier_data)
        next if my_inventory.can_afford?(tier_cost.except("IRON"))
        # ==

        (my_inventory.lemon < tier_cost["LEMON"] && gather_initial_fruit(worker, "LEMON", 1)) ||
        (my_inventory.plum < tier_cost["PLUM"] && gather_initial_fruit(worker, "PLUM", 1)) ||
        (my_inventory.lemon < tier_cost["LEMON"] && gather_initial_fruit(worker, "LEMON", 5)) ||
        (my_inventory.plum < tier_cost["PLUM"] && gather_initial_fruit(worker, "PLUM", 5)) ||
        (my_inventory.apple < tier_cost["APPLE"] && gather_initial_fruit(worker, "APPLE", 2)) ||
        (my_inventory.lemon < tier_cost["LEMON"] && gather_initial_fruit(worker, "LEMON", 8)) ||
        (my_inventory.plum < tier_cost["PLUM"] && gather_initial_fruit(worker, "PLUM", 8)) ||
        (my_inventory.apple < tier_cost["APPLE"] && gather_initial_fruit(worker, "APPLE", 4)) ||
        (my_inventory.lemon < tier_cost["LEMON"] && gather_anywhere_fruit(worker, "LEMON", 10)) ||
        (my_inventory.plum < tier_cost["PLUM"] && gather_anywhere_fruit(worker, "PLUM", 10)) ||
        (my_inventory.apple < tier_cost["APPLE"] && gather_anywhere_fruit(worker, "APPLE", 10))

        break if plans[worker.id]
      end
      return if plans[worker.id]

      # TODO, may need to detect inter already grabbing last piece
      (my_inventory.iron < aimed_chopper_cost["IRON"] && gather_iron(worker))
    end
    return if plans[worker.id]

    # 65 turns are known to be too many, 50 likely ok, but may go lower
    # if no_way_to_scale_to_chopper
    #   debug("= Helper sees no time to scale to chopper, self-planting")

    #   # dropping carried wood is handled

    #   seek_to_self_plant(worker)
    #   return if plans[worker.id]

    #   # hmm, no seeds left, time to chop anything
    #   tree = trees.min_by { shortest_path(worker.node, _1.node).size }
    #   return go_and_chop(worker, tree.node) if tree
    # end

    # Initial boosting has one goal - be able to afford an excellent chopper worker.
    # It consists of 3 subgoals:
    #  1. Reach 17 lemons
    #  2. 10 iron
    #  3. 5 plums (easy)
    if chopper.nil? && !training.to_s.match?(%r'TRAIN \d+ \d+ 0') && best_prediction
      debug("- helper will scale to chopper #{best_prediction.name}")

      seek_to_plant_carried_banana(worker) ||
        (turn < 40 && my_inventory.lemon < aimed_chopper_cost["LEMON"] && ensure_sufficient_lemon_growth(worker)) ||
        (turn < 40 && my_inventory.plum < aimed_chopper_cost["PLUM"] && ensure_sufficient_plum_growth(worker)) ||
        harvest_already_stood_on_tree(
          worker,
          *[(my_inventory.lemon < aimed_chopper_cost["LEMON"] ? "LEMON" : nil), (my_inventory.plum < aimed_chopper_cost["PLUM"] ? "PLUM" : nil)].compact
        ) ||
        (my_inventory.lemon < aimed_chopper_cost["LEMON"] && gather_initial_fruit(worker, "LEMON", 5)) ||
        (my_inventory.plum < aimed_chopper_cost["PLUM"] && gather_initial_fruit(worker, "PLUM", 5)) ||
        (my_inventory.apple < aimed_chopper_cost["APPLE"] && gather_initial_fruit(worker, "APPLE", 2)) ||
        (my_inventory.iron < aimed_chopper_cost["IRON"] && inter.nil? && gather_iron(worker)) ||
        (
          my_inventory.lemon >= aimed_chopper_cost["LEMON"] && my_inventory.plum >= aimed_chopper_cost["PLUM"] &&
            gather_iron(worker)
        ) ||
        (inter && (turns_till_chopper < 15) && seek_to_plant_banana(worker)) ||
        (my_inventory.lemon < aimed_chopper_cost["LEMON"] && gather_initial_fruit(worker, "LEMON", 10)) ||
        (my_inventory.plum < aimed_chopper_cost["PLUM"] && gather_initial_fruit(worker, "PLUM", 10)) ||
        (my_inventory.apple < aimed_chopper_cost["APPLE"] && gather_anywhere_fruit(worker, "APPLE", 10)) ||
        (my_inventory.lemon < aimed_chopper_cost["LEMON"] && gather_anywhere_fruit(worker, "LEMON", 10)) ||
        (my_inventory.plum < aimed_chopper_cost["PLUM"] && gather_anywhere_fruit(worker, "PLUM", 10)) ||
        (my_inventory.iron < aimed_chopper_cost["IRON"] && gather_iron(worker)) # TODO, may need to detect inter already grabbing last piece

      debug("= not clear how helper could help scale to chopper!") if plans[worker.id].nil?

      harvest_closest_harvestable(worker) unless plans[worker.id]
    end
    return if plans[worker.id]

    # == Regular helping starts ==

    # detect self-seeding phase
    if trees.select(&:grown?).none?
      seek_to_self_plant(worker)
      return if plans[worker.id]
    end

    if worker.full? && worker.carry_banana.zero?
      return go_and_drop(worker, closest_dropoff(worker.node))
    end

    # Get off square chopper wants to get to
    if plans.values.any? { _1.node == worker.node }
      # prefer an empty nearby square (if any) if carrying a seed banana
      if worker.full? && worker.carry_banana.positive?
        nearby_plantable_node = grid.neighbors(worker.node)
          .select { cells[_1]&.tree.nil? }
          .min_by { shortest_path(my_camp.node, _1) }

        return go_and_plant(worker, nearby_plantable_node, "BANANA") if nearby_plantable_node

        nearby_tree_node = grid.neighbors(worker.node)
          .select { cells[_1]&.tree }
          .quick_min_by { cells[_1].tree.turns_till_size(4) }

        return go_and_chop(worker, nearby_tree_node) if nearby_tree_node
      end

      # Worker is not carrying anything now

      # 1. prefer stepping on a nearby banana fruit
      nearby_banana = grid.neighbors(worker.node)
        .select { cells[_1]&.tree&.type?("BANANA") && cells[_1]&.tree&.turns_till_fruit <= 1 }
        .quick_min_by { shortest_path(seed_node, _1) }
      return go_and_harvest(worker, nearby_banana) if nearby_banana

      # 2. or just step out of the way
      nearby_tree_node = grid.neighbors(worker.node)
        .select { cells[_1]&.tree }
        .quick_min_by { cells[_1].tree.turns_till_size(4) }
      return go_and_chop(worker, nearby_tree_node) if nearby_tree_node

      nearby_empty_node = grid.neighbors(worker.node)
        .select { cells[_1]&.tree.nil? }
        .min_by { shortest_path(my_camp.node, _1) }
      return go_and_chop(worker, nearby_empty_node) if nearby_empty_node
    end

    seek_to_plant_banana(worker)
  end

  def organize_intermediate(worker)
    disallowed_nodes = plans.values.map(&:node).compact

    # Get off square chopper or helper want to get to
    if plans.values.any? { _1.node == worker.node }
      # looks like inter will drop, shooing away
      if worker.full? && dropoff_nodes.include?(worker.node)
        alternate_dropoff = dropoff_nodes.reject {  node_reserved_by_any_plan?(_1) }
          .min_by { shortest_path(worker.node, _1).size }

        if alternate_dropoff.nil?
          messages << "buggering off somewhere"
          return go(worker, grid.neighbors(worker.node).first)
        end

        messages << "sidestepping"
        return go_and_drop(worker, alternate_dropoff)
      end

      # looks like inter will harvest, shooing away
      if !worker.full? && cells[worker.node]&.tree&.fruit?
        messages << "sidestepping"
        return harvest_closest_harvestable(worker, _except_nodes = [worker.node])
      end
    end

    # 0. unload if carrying wood for some reason
    if worker.carry_wood.positive? || (worker.full? && worker.carry_iron.positive?)
      return go_and_drop(worker, closest_dropoff(worker.node))
    end

    xms("> inter chop wars") do
      chop_wars(worker) if chopper.nil?
      return if plans[worker.id]
    end

    # OPP HOBBLING
    if my_workers.size > workers.select { !_1.my? }.size
      debug("- inter checking need to eliminte opp's lemons")

      opps_wet_lemontree, _dist = trees.select { _1.type?("LEMON") }.select { wet_nodes.include?(_1.node) }
        .map do |tree|
          [
            tree,
            shortest_path(opp_camp.node, tree.node).size - 1
          ]
        end
        .select { |tree, dist_from_opp| dist_from_opp <= 3 }
        .sort_by { |tree, dist_from_opp| [dist_from_opp, shortest_path(worker.node, tree.node).size] }.first
      if opps_wet_lemontree
        messages << "hee hee"
        return go_and_chop(worker, opps_wet_lemontree.node)
      end

      opps_dry_lemontree, _dist = trees.select { _1.type?("LEMON") }
        .map do |tree|
          [
            tree,
            shortest_path(opp_camp.node, tree.node).size - 1
          ]
        end
        .select { |tree, dist_from_opp| dist_from_opp <= 3 }
        .sort_by { |tree, dist_from_opp| [dist_from_opp, shortest_path(worker.node, tree.node).size] }.first
      if opps_dry_lemontree
        messages << "hee hee"
        return go_and_chop(worker, opps_dry_lemontree.node)
      end
    end

    # ENDGAME, I'm winning, let's liquidate
    xms("> inter endgame") do
      if my_inventory.score > opp_inventory.score + 40 && trees.size < 6
        tree = trees.min_by { shortest_path(worker.node, _1.node) }
        seek_to_chop(worker, tree.node) if tree
      end
      return if plans[worker.id]
    end

    if no_way_to_scale_to_chopper
      debug("== inter sees #{turns_till_own_lemon_tree} turns till lemon as too far for scaling")

      messages << "race to bottom"

      # don't get in the way of helper's self-seed harvesting
      helper_chop = cells[helper.node]&.tree&.node

      bananatree = trees.select { _1.type?("BANANA") && _1.node != helper_chop }
        .min_by { _1.turns_till_chop(worker, shortest_path(worker.node, _1.node)) }

      if bananatree
        return seek_to_chop(worker, bananatree.node)
      end

      plumtree = trees.select { _1.type?("PLUM") && _1.node != helper_chop }
        .min_by { _1.turns_till_chop(worker, shortest_path(worker.node, _1.node)) }
      if plumtree
        return seek_to_chop(worker, plumtree.node)
      end

      lemontree = trees.select { _1.type?("LEMON") && _1.node != helper_chop }
        .min_by { _1.turns_till_chop(worker, shortest_path(worker.node, _1.node)) }
      if lemontree
        return seek_to_chop(worker, lemontree.node)
      end

      appletree = trees.select { _1.type?("APPLE") && _1.node != helper_chop }
        .min_by { _1.turns_till_chop(worker, shortest_path(worker.node, _1.node)) }
      if appletree
        return seek_to_chop(worker, appletree.node)
      end
    end

    xms("> inter chopper scaling") do
      if chopper.nil? && !training.to_s.match?(%r'TRAIN \d+ \d+ 0') && best_prediction
        debug("- inter helping scale to chopper")

        (my_inventory.lemon.zero? && trees_within_3_of_camp.none? { _1.type?("LEMON") } && gather_and_plant(worker, "LEMON")) ||
          (my_inventory.plum.zero? && trees_within_3_of_camp.none? { _1.type?("PLUM") } && gather_and_plant(worker, "PLUM")) ||
          (my_inventory.lemon < 2 && gather_initial_fruit(worker, "LEMON", 1)) ||
          (my_inventory.plum < 2 && gather_initial_fruit(worker, "PLUM", 1)) ||
          (my_inventory.lemon < 2 && gather_initial_fruit(worker, "LEMON", 2)) ||
          (my_inventory.plum < 2 && gather_initial_fruit(worker, "PLUM", 2)) ||
          (my_inventory.lemon < 6 && gather_initial_fruit(worker, "LEMON", 1)) ||
          (my_inventory.plum < 6 && gather_initial_fruit(worker, "PLUM", 1)) ||
          (my_inventory.lemon < 6 && gather_initial_fruit(worker, "LEMON", 2)) ||
          (my_inventory.plum < 6 && gather_initial_fruit(worker, "PLUM", 2)) ||
          (my_inventory.lemon < aimed_chopper_cost["LEMON"] && gather_initial_fruit(worker, "LEMON", 1)) ||
          (my_inventory.plum < aimed_chopper_cost["PLUM"] && gather_initial_fruit(worker, "PLUM", 1)) ||
          (my_inventory.lemon < aimed_chopper_cost["LEMON"] && gather_anywhere_fruit(worker, "LEMON", 2)) ||
          (my_inventory.plum < aimed_chopper_cost["PLUM"] && gather_anywhere_fruit(worker, "PLUM", 2)) ||
          (my_inventory.apple < aimed_chopper_cost["APPLE"] && gather_anywhere_fruit(worker, "APPLE", 30)) ||
          (my_inventory.iron < aimed_chopper_cost["IRON"] && gather_iron(worker)) ||
          debug("= Huh? inter has nothing to do for scaling to chopper!")
          # (my_inventory.plum < aimed_chopper_cost["PLUM"] && gather_initial_fruit(worker, "PLUM", 20)) ||
          # (my_inventory.lemon < aimed_chopper_cost["LEMON"] && gather_initial_fruit(worker, "LEMON", 20))
      end
      return if plans[worker.id]
    end

    xms("> inter dropoff calc") do
      if worker.full?
        return go_and_drop(worker, closest_dropoff(worker.node))
      end
    end

    # regular harvesting
    # xms("> regular inter harvesting") do
    #   harvest_closest_harvestable(worker)
    #   return if plans[worker.id]
    # end

    #== Regular chop-harassing
    opps_lemontree = trees.select { _1.type?("LEMON") }
      .sort_by { [shortest_path(opp_camp.node, _1.node).size, shortest_path(worker.node, _1.node).size] }.first
    if opps_lemontree
      messages << "hee hee"
      return go_and_chop(worker, opps_lemontree.node)
    end

    opps_banana = trees.select { _1.type?("BANANA") }
      .select { shortest_path(opp_camp.node, _1.node).size < 4 }
      .sort_by { [shortest_path(opp_camp.node, _1.node).size, shortest_path(worker.node, _1.node).size] }.first
    return go_and_chop(worker, opps_banana.node) if opps_banana

    opps_plum = trees.select { _1.type?("PLUM") }
      .sort_by { [shortest_path(opp_camp.node, _1.node).size, shortest_path(worker.node, _1.node).size] }.first
    return go_and_chop(worker, opps_plum.node) if opps_plum
    #==

    if trees.select(&:grown?).none?
      seek_to_self_plant(worker)
      return if plans[worker.id]
    end

    debug("XX hmm, inter has nothing to do")

    # TODO, have inter live on opp base corner to be abel to steal
  end

  # relies on @best_prediction having been set
  def aimed_chopper_cost
    best_prediction.costs
  end

  # Regular harvesting for inter, but chopping is preferred
  def harvest_closest_harvestable(worker, except_nodes=[])
    closest_harvestable_tree = trees.select do |tree|
      next false if except_nodes.include?(tree.node)
      # let's never try to harvest what chopper is cutting down
      next false if plans[chopper&.id]&.chop? && plans[chopper.id].node == tree.node
      next false if tree.node == seed_node

      tree.size > 1
    end
    .sort_by { grid.manhattan_distance(worker.node, _1.node) }.first(10)
    .select do |tree|
      turns_to_reach = ((shortest_path(worker.node, tree.node).size - 1) / worker.move_speed.to_f).ceil

      tree.fruits_at_arrival(_turns = turns_to_reach) >= worker.free_capacity
    end
    .sort_by do |tree|
      [shortest_path(worker.node, tree.node).size, tree.period]
    end.first

    if closest_harvestable_tree
      return go_and_harvest(worker, closest_harvestable_tree.node)
    end

    false
  end

  # used by helper and inter
  def seek_to_chop(worker, node)
    if worker.full?
      return go_and_drop(worker, closest_dropoff(worker.node))
    else
      go_and_chop(worker, node)
    end
  end

  # seek to plant in a cell on my side
  def seek_to_self_plant(worker)
    # TODO, this could be improved to actual opp worker speed checks
    return if workers.any? { !_1.my? && nodes_within_3_of_camp.include?(_1.node) }

    if worker.carry_seed?
      closest_my_node = my_nodes.select { cells[_1]&.tree.nil? }
        .sort_by { [shortest_path(my_camp.node, _1).size, shortest_path(worker.node, _1)] }.first

      return go_and_plant(worker, closest_my_node, worker.carried_seed)
    end

    if cells[worker.node]&.tree
      return go_and_chop(worker, worker.node)
    end

    # go grab a seed
    seed = self_harvest_seed
    if seed
      my_side_candidates = (my_nodes & dropoff_nodes) - plans.values.map(&:node)

      self_seeding_node =
        if my_side_candidates.any?
          my_side_candidates.min_by { shortest_path(worker.node, _1).size }
        else
          dropoff_nodes.min_by { shortest_path(worker.node, _1).size }
        end

      return go_and_pick(worker, self_seeding_node, seed)
    end
  end

  def seek_to_plant_carried_banana(worker)
    return unless worker.carry_banana.positive?

    # 1. seek to plant a banana on seed node
    if cells[seed_node]&.tree.nil?
      return go_and_plant(worker, seed_node, "BANANA")
    end

    # 2. seek to plant next to seed node
    closest = nodes_within_3_of_camp_except_seed
      .select { cells[_1]&.tree.nil? }
      .sort_by do |node|
        [
          shortest_path(worker.node, node).size + shortest_path(my_camp.node, node).size +
            shortest_path(seed_node, node).size -
            # wetness is treated as being half a square closer, giving a tiebreaking advantage
            (wet_nodes.include?(node) ? 0.5 : 0),
          # further from opp is better as tiebreaker
          -shortest_path(opp_camp.node, node).size
        ]
      end.first

    if closest
      return go_and_plant(worker, closest, "BANANA")
    end

    false
  end

  def seek_to_plant_banana(worker)
    seek_to_plant_carried_banana(worker)
    return if plans[worker.id]

    # 1. ON a harvestable banana
    if (tree = cells[worker.node]&.tree) && tree.type?("BANANA") && tree.fruit?
      return go_and_harvest(worker, tree.node)
    end

    # not carrying a banana, should get one
    seeding_bananas =
      cells[seed_node]&.tree&.type?("BANANA") &&
      cells[seed_node]&.tree&.turns_till_fruit_in_hand(worker, shortest_path(worker.node, seed_node)) < 5

    if seeding_bananas
      return go_and_harvest(worker, seed_node)
    elsif my_inventory.banana.positive?
      return go_and_pick(worker, closest_dropoff(worker.node), "BANANA")
    elsif (banana_nodes = cells.select { |node, cell| cell&.tree&.type?("BANANA") }).any?
      closest, _cell = banana_nodes.min_by do |node, cell|
        cell.tree.turns_till_fruit_in_hand(worker, shortest_path(worker.node, node))
      end

      if closest
        return go_and_harvest(worker, closest)
      end
    else
      debug("= Hmm, no banana trees on map?")
    end
  end

  def harvest_already_stood_on_tree(worker, *types)
    return if worker.full?

    tree = cells[worker.node]&.tree
    return unless tree
    return unless types.include?(tree.type)
    return unless tree.fruit?

    messages << "oh #{tree.type}"
    go_and_harvest(worker, tree.node)
  end

  def ensure_sufficient_lemon_growth(worker)
    expected_lemon_production_near_camp_per_turn = nodes_within_3_of_camp.sum do |near_node|
      cell = cells[near_node]
      next 0 if cell.nil? || cell.tree.nil? || cell.tree.type != "LEMON"

      wet_nodes.include?(near_node) ? (1/3.0) : (1/8.0)
    end
    debug "= Eventual Lemon production near camp per turn #{expected_lemon_production_near_camp_per_turn}"

    return if expected_lemon_production_near_camp_per_turn >= (2/8.0) # one watered or 2 regular

    wet_path = wet_nodes_within_3_of_camp
      # clear of trees
      .select { cells[_1].nil? || cells[_1].tree.nil? }
      .map { shortest_path(my_camp.node, _1) }
      .sort_by { [_1.size - (node_secluded?(_1.last) ? 1.1 : 0), -shortest_path(opp_camp.node, _1.last).size]}
      .first

    if wet_path
      return handle_planting_at_end_of(worker, wet_path, "LEMON")
    end

    regular_path, _ = nodes_within_3_of_camp.select { cells[_1].nil? || cells[_1].tree.nil? }
      .map { [shortest_path(my_camp.node, _1), shortest_path(worker.node, _1), shortest_path(opp_camp.node, _1)] }
      .min_by { _1.size + _2.size - _3.size }

    if regular_path
      return handle_planting_at_end_of(worker, regular_path, "LEMON")
    end
  end

  def ensure_sufficient_plum_growth(worker)
    expected_plum_production_near_camp_per_turn = nodes_within_3_of_camp.sum do |near_node|
      cell = cells[near_node]
      next 0 if cell.nil? || cell.tree.nil? || cell.tree.type != "PLUM"

      wet_nodes.include?(near_node) ? (1/8.0) : (1/3.0)
    end
    debug "= Eventual Plum production near camp per turn #{expected_plum_production_near_camp_per_turn}"

    return if expected_plum_production_near_camp_per_turn >= (1/8.0) # one tree on any wetness is sufficient

    wet_path = wet_nodes_within_3_of_camp.select { cells[_1].nil? || cells[_1].tree.nil? }
      .map { shortest_path(my_camp.node, _1) }
      .min_by { _1.size - (node_secluded?(_1.last) ? 1.1 : 0)}

    if wet_path
      return handle_planting_at_end_of(worker, wet_path, "PLUM")
    end

    regular_path, _ = nodes_within_3_of_camp.select { cells[_1].nil? || cells[_1].tree.nil? }
      .map { [shortest_path(my_camp.node, _1), shortest_path(worker.node, _1)] }
      .min_by { _1.size + _2.size }

    if regular_path
      return handle_planting_at_end_of(worker, regular_path, "PLUM")
    end
  end

  # @path Array<Node> # starts at camp and ends at desired tree node
  def handle_planting_at_end_of(worker, path, tree_type)
    if worker.node == path.last && worker.carrying?(tree_type)
      return plans[worker.id] = Plan.new("PLANT", worker.id, tree_type)
    elsif worker.carrying?(tree_type)
      return go(worker, path.last)
    elsif worker.node == path[1] && !worker.carrying?(tree_type) && my_inventory.has?(tree_type)
      return plans[worker.id] = Plan.new("PICK", worker.id, tree_type)
    elsif my_inventory.has?(tree_type) # as in no lemon in hand, go to near camp
      return go(worker, path[1])
    end

    false
  end

  def gather_iron(worker)
    if worker.full?
      return go_and_drop(worker, closest_dropoff(worker.node))
    end

    closest_mine = mining_nodes.min_by { shortest_path(worker.node, _1).size }
    return go_and_mine(worker, closest_mine)
  end

  # a generic going. Checks about having reached should occur beforehand in callers.
  def go(worker, node)
    path = shortest_path(worker.node, node)
    target = path[worker.move_speed] || path.last

    if node_reserved_by_any_plan?(target)
      alternate_path = shortest_path(worker.node, node, excluding: [target])
      if alternate_path
        debug ">> go target taken, rerouted"
        path = alternate_path
      else
        debug "XX go target taken, no reroute possible!"
      end
    end

    plans[worker.id] = Plan.new("MOVE", worker.id, nil, path[worker.move_speed] || path.last)
  end

  def go_and_mine(worker, node)
    if worker.node == node # already there!
      plans[worker.id] = Plan.new("MINE", worker.id) # "MINE #{worker.id}"
    else # go if not there
      messages << "IROON!"
      go(worker, node)
    end
  end

  def go_and_harvest(worker, node)
    if worker.node == node # already there!
      plans[worker.id] = Plan.new("HARVEST", worker.id)
    else # go if not there
      go(worker, node)
    end
  end

  def go_and_pick(worker, node, type)
    if worker.node == node # already there!
      plans[worker.id] = Plan.new("PICK", worker.id, type)
    else # go if not there
      go(worker, node)
    end
  end

  def go_and_plant(worker, node, type)
    if worker.node == node # already there!
      plans[worker.id] = Plan.new("PLANT", worker.id, type)
    else # go if not there
      go(worker, node)
    end
  end

  def go_and_chop(worker, node)
    if worker.node == node # already there!
      plans[worker.id] = Plan.new("CHOP", worker.id, nil, node)
    else # go if not there
      go(worker, node)
    end
  end

  # Used to allow any dropoff, but exclusions necessitate exact one, EVEN IF WORKER ALREADY IS ON A DROPOFF
  def go_and_drop(worker, node)
    if node_reserved_by_any_plan?(node)
      path = shortest_path(worker.node, node)
      # and worker is one step away from the reserved dropoff
      if ((path.size - 1) / worker.move_speed.to_f) == 1
        # try an alternate dropoff
        alternate_dropoff = (dropoff_nodes - [node]).min_by { shortest_path(worker.node, _1).size }

        return go(worker, alternate_dropoff) if alternate_dropoff
      end
    end

    if worker.node == node # already at specified dropoff
      plans[worker.id] = Plan.new("DROP", worker.id)
    else
      go(worker, node)
    end
  end

  def gather_and_plant(worker, fruit_type)
    if worker.carrying?(fruit_type)
      plantable_node = nodes_within_3_of_camp_except_seed.select { cells[_1]&.tree.nil? }
        # TODO, camps being near can result in stupid situations where I plant closer to opp than myself
        .reject { shortest_path(opp_camp.node, _1).size < 5 }
        .min_by do |node|
          shortest_path(worker.node, node).size + shortest_path(my_camp.node, node).size -
            (wet_nodes.include?(node) ? 0.5 : 0)
        end

      if plantable_node.nil?
        debug("XX No plantable nodes?")
        go_and_drop(worker, closest_dropoff(worker.node))
      end

      return go_and_plant(worker, plantable_node, fruit_type)
    else
      closest_fruit = trees.select { _1.type?(fruit_type) }
        .sort_by do |tree|
          [
            tree.turns_till_fruit_in_hand(worker, shortest_path(worker.node, tree.node)),
            -shortest_path(opp_camp.node, tree.node).size
          ]
        end
        .first

      unless closest_fruit
        debug("XX Wow, I have no #{fruit_type} at camp and no trees on map")
        return false
      end

      messages << "getting seed #{fruit_type}"
      return go_and_harvest(worker, closest_fruit.node)
    end

    false
  end

  # Used by both helper and inter, helper gets prio
  def gather_initial_fruit(worker, fruit_type, max_wait)
    if worker.full?
      return go_and_drop(worker, closest_dropoff(worker.node))
    end

    if cells[worker.node]&.tree&.type == fruit_type && cells[worker.node]&.tree&.fruit? # at a tree already!
      plans[worker.id] = Plan.new("HARVEST", worker.id)
    else # gotta detect and go to a good candidate tree
      path_to_tree, turns_till = nodes_within_3_of_camp
        .select do |node|
          next false unless (tree = cells[node]&.tree)
          next false unless tree.type?(fruit_type)

          plan = plans[helper.id]
          next true unless plan

          !(plan.name?("HARVEST") && helper.node == node)
        end
        .map do |node|
          path = shortest_path(worker.node, node)
          [path, cells[node].tree.turns_till_fruit_in_hand(worker, path)]
        end.select { _2 <= max_wait }.min_by { |_path, turns_till| turns_till }


      if path_to_tree.nil?
        debug("= No #{fruit_type} trees qualify for early harvesting with a wait time of #{max_wait}")
        return
      end

      messages << "trns till #{fruit_type} #{turns_till}"
      go(worker, path_to_tree.last)
    end
  end

  # Reserved for dire straits like last apples for chopper
  def gather_anywhere_fruit(worker, fruit_type, max_wait)
    if worker.full?
      return go_and_drop(worker, closest_dropoff(worker.node))
    end

    if cells[worker.node]&.tree&.type == fruit_type && cells[worker.node]&.tree&.fruit? # at a tree already!
      return plans[worker.id] = Plan.new("HARVEST", worker.id)
    end

    tree_path, turns_till = trees
      .select { _1.type?(fruit_type) && !(plans[helper.id]&.name?("HARVEST") && helper.node == _1.node) }
      .map do |tree|
        path = shortest_path(worker.node, tree.node)
        [path, tree.turns_till_fruit_in_hand(worker, path)]
      end
      .select { _2 <= max_wait }.min_by { |_path, turns_till| turns_till }

    if tree_path.nil?
      debug("= No #{fruit_type} trees qualify any-dist harvesting with wait of #{max_wait}")
      return
    end

    messages << "trns till #{fruit_type} #{turns_till}"
    go(worker, tree_path.last)
  end

  # assumes free-ish hands
  def chop_wars(worker)
    xms(">> CHOP WARS calc for worker #{worker}") do
      return if !worker.can_chop?
      # WAR, seek to fight over chopping if opp within 2 turns can be cought
      opp_workers_chopping = workers.select { !_1.my? }.select { _1.can_chop? && cells[_1.node]&.tree&.damaged? }
      return if opp_workers_chopping.none?

      # maybe already ON chop node
      worker_tree = cells[worker.node]&.tree
      if worker_tree && cells[worker.node]&.opp_worker && worker_tree.damaged?
        if dropoff_nodes.include?(worker_tree.node) && worker.full?
          return go_and_drop(worker, worker.node)
        end

        # hey, maybe we're next to base and we can wait efficiently with harvesting in the meantime
        if dropoff_nodes.include?(worker_tree.node)
          opp_worker = cells[worker.node].opp_worker
          turns_to_fell = worker_tree.chop_turns(opp_worker.chop_power)

          # in three turns we can do PICK, DROP and then final CHOP
          if turns_to_fell >= 3 && worker_tree.fruit?
            return go_and_harvest(worker, worker_tree.node)
          end
        else # can't harvest in meantime, Need to chop or wait
          opp_worker = cells[worker.node]&.opp_worker

          if worker.chop_power > opp_worker.chop_power
            # we have the better chop, so might as well put and end to this war
            go_and_chop(worker, worker.node)
          else
            messages << "#{worker.id} waiting"
            go(worker, worker.node) # as in stay put without doing anything
          end
        end
      end

      chops = opp_workers_chopping.map do |opp_worker|
        tree = cells[opp_worker.node].tree
        path = shortest_path(worker.node, opp_worker.node)
        turns_to_reach =
          ((path.size - 1) / worker.move_speed.to_f).ceil +
          (turns_to_drop(worker) * 2) # doubling to account for possible going opposite way. Usually will be 0 anyway

        turns_to_fell = tree.chop_turns(opp_worker.chop_power)
        [path, turns_to_reach, turns_to_fell]
      end

      interceptable_chops =
        if trees.size > 2
          chops.select { |p, to_reach, to_fell| to_fell < 5 && to_reach <= 3 && (to_reach + 1) <= to_fell }
        else # as in last 2 trees
          chops.select { |p, to_reach, to_fell| to_fell < 6 && to_reach <= 5 && (to_reach + 1) <= to_fell }
        end

      if interceptable_chops.any?
        path, _, _ = interceptable_chops.quick_max_by { |p, to_reach, to_fell| cells[p.last].tree.size }

        if worker.full?
          messages << "*cracks neck*"
          return go_and_drop(worker, shortest_path_to_drop(worker.node).last)
        end

        messages << "chop warz"
        return go_and_chop(worker, path.last)
      end
    end
  end

  # Nodes are reserved by many things. Moving targeting the node or stationary operations remining on the node
  def node_reserved_by_any_plan?(node)
    plans.values.any? do |plan|
      # as in moving and will take up target node
      return true if plan.node == node

      # otherwise worker will remain stationary and reserves current node for next turn also
      worker = my_workers.find { _1.id == plan.worker_id }
      worker.node == node
    end
  end

  # Major predictive logic
  def turns_to_gather(type, count)
    return 0 unless count.positive?

    if type == "IRON"
      xms(">>> #turns_to_gather #{type} #{count}") do
        yields = []

        # start with quickest worker
        my_workers.select(&:can_chop?)
          .sort_by { [-_1.move_speed, -_1.carry_capacity, -_1.chop_power] }
          .each_with_index do |worker, i|
            mining_cycle =
              ((shortest_path_to_mining.size - 1) / worker.move_speed.to_f).ceil * 2 +
              (_drop = 1) +
              (_mining_turns = worker.mining_turns)

            yields << (worker.carry_capacity / mining_cycle.to_f) * (0.8**i)
          end

        return 300 if yields.sum.zero?
        (count / yields.sum.to_f).ceil
      end
    else # for fruits
      xms(">>> #turns_to_gather #{type} #{count}") do
        penalty_turns = nil
        yields = []

        harvesters = xms(">>>> harvester lookup") do
          my_workers.select(&:can_harvest?).sort_by { [-_1.move_speed, -_1.carry_capacity, -_1.chop_power] }
        end

        harvesters.each_with_index do |worker, i|
          best_tree, average_yield = xms(">>>> best_tree, average_yield lookup") do
            trees.select { _1.type?(type) }.map do |tree|
              distance_to_camp = shortest_path(my_camp.node, tree.node).size - 1
              [tree, tree.average_fruit_yield(distance_to_camp, worker)]
            end
            .sort_by { |t, average_yield| -average_yield }[i..-1]&.first
          end

          if best_tree
            yields << average_yield.to_f * (0.8**i)
          else # no tree, maybe we can plant
            next if !my_inventory.has?(type) # since no way to get more fruit
            next if use_shortscale?

            if wet_nodes_within_3_of_camp.any?
              penalty_turns ||= 15
              yields << (1/5.0) * (0.8**i)
            else
              penalty_turns ||= 26
              yields << (1/9.0) * (0.8**i)
            end
          end
        end

        return 300 if yields.sum.zero?
        (count / yields.sum.to_f).ceil + penalty_turns.to_i
      end
    end
  end

  # BE CAREFUL, this is too greedy when applied to home trees, it comes out as chopping ungrown trees is best
  def tree_points_per_turn(tree, worker)
    turns_to_reach = ((shortest_path(worker.node, tree.node).size - 1) / worker.move_speed.to_f).ceil

    copy = tree.dup
    turns_to_reach.times { copy.apply_turn }

    # TODO, this will slightly undervalue the tree if it's still growing and would grow during chop
    turns_to_chop = copy.chop_turns(worker.chop_power)
    turns_to_drop = turns_to_drop(tree.node, worker)

    (tree.size * 4) / (turns_to_reach + turns_to_chop + turns_to_drop).to_f
  end

  def turns_to_drop(worker)
    return 0 unless worker.full?

    ((shortest_path_to_drop(worker.node).size - 1) / worker.move_speed.to_f).ceil + 1
  end

  # @return Node
  def closest_dropoff(from_node)
    dropoff_nodes.min_by { shortest_path(from_node, _1).size }
  end

  # @return Array<Node>
  def shortest_path_to_drop(from_node)
    shortest_path(from_node, closest_dropoff(from_node))
  end

  # @return Hash {move: 1, ..}
  def worker_cost(move, carry, harvest, chop)
    existing_workers = my_workers.size

    {
      "PLUM" => existing_workers + (move**2),
      "LEMON" => existing_workers + (carry**2),
      "APPLE" => existing_workers + (harvest**2),
      "IRON" => existing_workers + (chop**2)
    }
  end

  # @return String, nil
  def self_harvest_seed
    # %w[BANANA PLUM LEMON APPLE].each do |type|
    # apples not worth it
    %w[BANANA PLUM LEMON].each do |type|
      return type if my_inventory.has?(type)
    end

    nil
  end

  # 65 turns are known to be too many, 50 likely ok, but may go lower
  def no_way_to_scale_to_chopper
    chopper.nil? && my_inventory.lemon < 4 && (turns_till_own_lemon_tree + turn) > 50
  end

  def turns_till_chopper
    -[my_inventory.plum - 5, 0].min * 5 +
      -[my_inventory.lemon - 17, 0].min * 5 +
      -[my_inventory.apple - 1, 0].min * 5 +
      -[my_inventory.iron - 10, 0].min * shortest_path_to_mining.size * 2
  end

  # Not just tree, but 1st fruit from it
  def turns_till_own_lemon_tree
    @turns_till_own_lemon_tree ||= {}
    return @turns_till_own_lemon_tree[turn] if @turns_till_own_lemon_tree.key?(turn)

    nearby_lemon = trees_within_3_of_camp.select { _1.type?("LEMON") }
      .min_by { _1.turns_till_fruit_in_hand(helper, shortest_path(helper.node, _1.node)) }

    if nearby_lemon
      return @turns_till_own_lemon_tree[turn] =
        nearby_lemon.turns_till_fruit_in_hand(helper, shortest_path(helper.node, nearby_lemon.node))
    end

    # ok, maybe I can plant
    if my_inventory.lemon.positive?
      if wet_nodes_within_3_of_camp.any?
        example_node = wet_nodes_within_3_of_camp.first
        cd_and_period = tree_period_mapping.dig(:wet, "LEMON")
        return @turns_till_own_lemon_tree[turn] = Tree.new("LEMON", example_node.x, example_node.y, 1, 8, 0, cd_and_period, cd_and_period)
          .turns_till_fruit_in_hand(helper, shortest_path(helper.node, example_node))
        # :type, :x, :y, :size, :health, :fruits, :cooldown, :period
      else
        example_node = dropoff_nodes.first
        cd_and_period = tree_period_mapping.dig(:dry, "LEMON")
        return @turns_till_own_lemon_tree[turn] = Tree.new("LEMON", example_node.x, example_node.y, 1, 8, 0, cd_and_period, cd_and_period)
          .turns_till_fruit_in_hand(helper, shortest_path(helper.node, example_node))
        # :type, :x, :y, :size, :health, :fruits, :cooldown, :period
      end
    end

    # uff, no nearby trees and can't plant due to missing seeds. Only option is to
    # get a seed from further trees, get back, and plant it.
    possibilities = trees.select { _1.type?("LEMON") }
      .map do |tree|
        [
          tree,
          tree.turns_till_fruit_in_hand(helper, shortest_path(helper.node, tree.node)),
          _get_back_turns = shortest_path(tree.node, my_camp.node).size - 2,
          _new_growth =
            if wet_nodes_within_3_of_camp.any?
              example_node = wet_nodes_within_3_of_camp.first
              cd_and_period = tree_period_mapping.dig(:wet, "LEMON")
              Tree.new("LEMON", example_node.x, example_node.y, 1, 8, 0, cd_and_period, cd_and_period)
                .turns_till_fruit_in_hand(helper, shortest_path(helper.node, example_node))
              # :type, :x, :y, :size, :health, :fruits, :cooldown, :period
            else
              example_node = dropoff_nodes.first
              cd_and_period = tree_period_mapping.dig(:dry, "LEMON")
              Tree.new("LEMON", example_node.x, example_node.y, 1, 8, 0, cd_and_period, cd_and_period)
                .turns_till_fruit_in_hand(helper, shortest_path(helper.node, example_node))
              # :type, :x, :y, :size, :health, :fruits, :cooldown, :period
            end
        ]
      end

    best = possibilities.map do |tree, turns_till_fruit_in_hand, get_back_turns, new_growth|
      turns_till_fruit_in_hand + get_back_turns + new_growth
    end.min

    return @turns_till_own_lemon_tree[turn] = best if best

    return @turns_till_own_lemon_tree[turn] = 300
  end

  def my_workers
    @my_workers ||= {}
    return @my_workers[turn] if @my_workers.key?(turn)
    @my_workers[turn] = workers.select(&:my?)
  end

  def opp_workers
    @opp_workers ||= {}
    return @opp_workers[turn] if @opp_workers.key?(turn)
    @opp_workers[turn] = workers.select { !_1.my? }
  end

  def trees_within_3_of_camp
    @trees_within_3_of_camp ||= {}
    return @trees_within_3_of_camp[turn] if @trees_within_3_of_camp.key?(turn)
    @trees_within_3_of_camp[turn] = trees.select { nodes_within_3_of_camp.include?(_1.node) }
  end

  #===================
  #  TURN INIT BELOW
  #===================

  def use_shortscale?
    return false if chopper

    (wet_nodes_within_3_of_camp.size == 0)

    # || (turn > 10 && wet_nodes_within_3_of_opp_camp.none? { cells[_1]&.tree&.type?("LEMON") } )

    # TODO, gotta see how neightbor limit affects score
    # || (grid.neighbors(my_camp.node).size == 1)
  end

  # Predictions for which chopper to aim for.
  def init_predictions
    @predictions = []
    return if chopper

    variants =
      if use_shortscale?
        existing = my_workers.size

        move = my_inventory.best_affordable_train_tier("PLUM", 3, existing)
        carry = my_inventory.best_affordable_train_tier("LEMON", 3, existing)
        # chop needs to be at least as strong as opp's
        chop = workers.select { !_1.my? }.map(&:chop_power).max

        # from current situation all combos of scaling up a bit
        [
          [move, carry, 0, chop],
          [move.next, carry, 0, chop],
          [move, carry.next, 0, chop],
          [move, carry, 0, chop.next],
          [move.next, carry.next, 0, chop],
          [move.next, carry, 0, chop.next],
          [move, carry.next, 0, chop.next],
          [move.next, carry.next, 0, chop.next]
        ]
        # not going for 4 carry, its unlikely to pan out
        .reject { |d| d[1] > 3 }.reject { |d| d[3] > 3 }
      else # regular full-power variants
        [
          [2, 4, 0, 3], # best
          [2, 4, 0, 2], # -1chop
          [2, 3, 0, 3], # (-1carry)
          [2, 3, 0, 2], # (-1carry,-1chop)
        ]
      end

    variants.each do |variant|
      p = predict(*variant)
      @predictions << p

      # no need to calc all four variants if the cheapest will take 100 turns
      # break if p.turns > 100
    end

    @best_prediction = @predictions.sort_by { [-_1.grand_total, _1.turns] }.first

    nil
  end

  # a sort of postprocessing that uses time left at the end of a turn to precrunch shortest paths regarding trees
  def prefill_tree_paths
    trees.each do |tree|
      break if turn_time_remaining < 1

      shortest_path(my_camp.node, tree.node)
    end
  end

  def init_turn_variables!
    lines = input.split("\n")

    @my_inventory = Inventory.new(*lines.shift.split.map(&:to_i))
    @opp_inventory = Inventory.new(*lines.shift.split.map(&:to_i))

    @cells = {}

    @trees = []
    lines.shift.to_i.times do
      type, x, y, size, health, fruits, cooldown = lines.shift.split.map { _1[0].match?(%r'\d') ? _1.to_i : _1 }

      period = wet_nodes.include?("#{x} #{y}") ? tree_period_mapping.dig(:wet, type) : tree_period_mapping.dig(:dry, type)
      tree = Tree.new(type, x, y, size, health, fruits, cooldown, period)
      @trees << tree
      @cells["#{x} #{y}"] ||= Cell.new(x, y)
      @cells["#{x} #{y}"].tree = tree
    end

    # clearing before each move
    @helper = nil
    @inter = nil
    @chopper = nil

    @workers = []
    lines.shift.to_i.times do
      id, player, x, y, move_speed, carry_capacity, harvest_power, chop_power, carry_plum, carry_lemon, carry_apple, carry_banana, carry_iron, carry_wood = lines.shift.split.map(&:to_i)

      worker = Worker.new(
        id, player, x, y,
        move_speed, carry_capacity, harvest_power, chop_power,
        carry_plum, carry_lemon, carry_apple, carry_banana, carry_iron, carry_wood
      )
      @workers << worker

      @cells["#{x} #{y}"] ||= Cell.new(x, y)

      if worker.my?
        @cells["#{x} #{y}"].worker = worker
      else
        @cells["#{x} #{y}"].opp_worker = worker
      end
    end

    sorted = my_workers.sort_by(&:id)
    if sorted.size == 3
      @helper = sorted.first
      @inter = sorted[1]
      @chopper = sorted[2]
    else
      sorted.each_with_index do |worker, i|
        next @helper = worker if i == 0

        # chopper will never have harvest power, but intern will
        if i == 1 && worker.harvest_power > 0
          @inter = worker
        else
          @chopper = worker
        end
      end
    end

    init_predictions
  end

  # Grid init is a simple fill, bet we make caps leave-only (and maybe rocks in future leagues)
  def init_grid
    @init_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    lines = field.split("\n")
    @grid = Grid.new(lines.first.size, lines.size, fill: true)

    lines.each_with_index do |line, y|
      line.split("").each_with_index do |cell, x|
        node = "#{x} #{y}"
        # . for GRASS, ~ for WATER, # for ROCK, + for IRON, 0 for your own SHACK, 1 for your opponent's SHACK.
        if %w[~ # +].include?(cell)
          grid.remove_cell(node)
        end

        grass_nodes << node if cell == "."
        water_nodes << node if cell == "~"
        iron_nodes << node if cell == "+"

        @my_camp = Camp.new(true, x, y) if cell == "0"
        @opp_camp = Camp.new(false, x, y) if cell == "1"
      end
    end

    # == camp distances and areas
    @distance_between_camps = [grid.shortest_path(my_camp.node, opp_camp.node).size - 2, 0].max

    grid.n4(my_camp.node).each do |next_to_camp|
      grid.remove_connection(next_to_camp, my_camp.node)
    end
    !opp_camp.nil? && grid.n4(opp_camp.node).each do |next_to_camp|
      grid.remove_connection(next_to_camp, opp_camp.node)
    end
    # ==

    ms(">> wet/mining hybrid node init") do
      grass_nodes.each do |grass_node|
        wet_nodes << grass_node if @grid.n4(grass_node).any? { water_nodes.include?(_1) }
        mining_nodes << grass_node if @grid.n4(grass_node).any? { iron_nodes.include?(_1) }
      end
    end

    ms(">> wet node init") { wet_nodes_within_3_of_camp }
    ms(">> INIT opp node") { nodes_within_3_of_opp_camp }
    ms(">> seed note init") { seed_node }

    ms(">> INIT #my_nodes") do
      grass_nodes.each do |grass_node|
        my_path = shortest_path(my_camp.node, grass_node).size - 1
        opp_path = shortest_path(opp_camp.node, grass_node).size - 1

        if my_path < opp_path && opp_path > distance_between_camps
          my_nodes << grass_node
        end
      end
    end

    return if init_time_remaining < 2

    ms(">> seed note init") { seed_node }

    #===
    # return if defined?(LOCAL)
    #===

    ms(">> grass -> seed node init") do
      grass_nodes.each do |grass_node|
        return if init_time_remaining < 2

        shortest_path(grass_node, seed_node)
      end
    end

    ms(">> w3 of camp except seed") { nodes_within_3_of_camp_except_seed }

    ms(">> dropoffs -> mining init") do
      mining_nodes.each do |mining_node|
        return if init_time_remaining < 2

        grid.neighbors(my_camp.node).each do |grass_node|
          shortest_path(grass_node, mining_node)
        end
      end
    end

    ms(">> all near-camp node connections") do
      nodes_within_3_of_camp.each do |node|
        return if init_time_remaining < 2

        nodes_within_3_of_camp.each do |other_node|
          next if node == other_node

          shortest_path(node, other_node)
        end
      end
    end

    ms(">> dropoff points -> all grass init") do
      grid.neighbors(my_camp.node).each do |node|
        break if init_time_remaining < 2

        grass_nodes.each do |grass_node|
          shortest_path(node, grass_node)
        end
      end
    end

    ms(">> opp camp -> all grass init") do
      grass_nodes.each do |grass_node|
        break if init_time_remaining < 2

        shortest_path(opp_camp.node, grass_node)
      end
    end

    nil
  end

  # @return [Array<Node>, nil]
  def shortest_path(from, to, excluding: nil)
    raise(":from is nil, debug!") unless from.respond_to?(:x)
    raise(":to is nil, debug!") unless to.respond_to?(:y)

    key = [from, to, excluding]

    path =
      if shortest_paths.key?(key)
        shortest_paths[key]
      else
        shortest_paths[key] = grid.shortest_path(from, to, excluding: excluding)
      end

    r_key = [to, from, excluding]
    shortest_paths[r_key] ||=
      if path
        path.reverse
      else
        nil
      end
    return if shortest_paths[r_key].nil?

    # also producing n-1 longth subpaths for ease of further navigation
    if excluding.nil? && (subpaths_exist = path.first(3).size == 3)
      key = [path[0], path[-2], nil]
      shortest_paths[key] ||= path[0..-2]
      shortest_paths[key.reverse] ||= path[0..-2].reverse

      key = [path[1], path[-1], nil]
      shortest_paths[key] ||= path[1..-1]
      shortest_paths[key.reverse] ||= path[1..-1].reverse
    end

    path
  rescue => e
    debug("XX Could not get path from #{from} to #{to}")
    raise
  end

  # @return Hash # keys are array of start-end node pairs
  def shortest_paths
    @shortest_paths ||= {}
  end

  # Distance up to 3 is special because water is that much more effective
  #
  # @return Set
  def wet_nodes_within_3_of_camp
    @wet_nodes_within_3_of_camp ||= nodes_within_3_of_camp & wet_nodes
  end

  def nodes_within_3_of_camp
    @nodes_within_3_of_camp ||= grass_nodes.select do |grass_node|
      shortest_path(my_camp.node, grass_node).size <= 4
    end.to_set
  end

  def nodes_within_3_of_camp_except_seed
    @nodes_within_3_of_camp_except_seed ||= nodes_within_3_of_camp - [seed_node]
  end

  # == OPP nodes ==

  def wet_nodes_within_3_of_opp_camp
    @wet_nodes_within_3_of_opp_camp ||= nodes_within_3_of_opp_camp & wet_nodes
  end

  def nodes_within_3_of_opp_camp
    @nodes_within_3_of_opp_camp ||= grass_nodes.select do |grass_node|
      shortest_path(opp_camp.node, grass_node).size <= 4
    end.to_set
  end

  # ==

  def node_secluded?(node)
    distance_between_camps + 10 < (shortest_path(opp_camp.node, node).size - 1)
  end

  # A special node either next to water with 2+ neighboring cells close to camp or a next-to-camp cell
  # where a banana for continuous replanting will be planted and never chopped
  def seed_node
    return @seed_node if defined?(@seed_node)

    @seed_node =
      if wet_nodes_within_3_of_camp.any?
        wet_nodes_within_3_of_camp.sort_by do |node|
          [
            # high seclusion (at least 10 extra cells to reach) is worth one neighboring cell, so a 2N would also be fine
            -_seclusion_and_neighbor_score =
              (node_secluded?(node) ? 1 : 0) +
              (grid.neighbors(node) & nodes_within_3_of_camp).size,
            shortest_path(my_camp.node, node).size,
            -shortest_path(opp_camp.node, node).size
          ]
        end.first
      else
        nodes_within_3_of_camp.sort_by do |node|
          [
            -(grid.neighbors(node) & nodes_within_3_of_camp).size,
            shortest_path(my_camp.node, node).size,
            -shortest_path(opp_camp.node, node).size
          ]
        end.first
      end

    debug("= Seed node is #{@seed_node}")

    @seed_node
  end

  def dropoff_nodes
    @dropoff_nodes ||= grid.neighbors(my_camp.node)
  end

  def opp_dropoff_nodes
    opp_dropoff_nodes ||= grid.neighbors(opp_camp.node)
  end

  # @return Set
  def wet_nodes
    @wet_nodes ||= Set.new
  end

  def grass_nodes
    @grass_nodes ||= Set.new
  end

  def water_nodes
    @water_nodes ||= Set.new
  end

  def mining_nodes
    @mining_nodes ||= Set.new
  end

  # @return Array<Node>
  def shortest_path_to_mining
    @shortest_path_to_mining ||= mining_nodes.flat_map do |mining_node|
      grid.neighbors(my_camp.node).map do |n|
        shortest_path(n, mining_node)
      end
    end.min_by { _1.size }
  end

  def iron_nodes
    @iron_nodes ||= Set.new
  end

  # Taken to mean nodes not only closer to my camp but also "behind" my camp from opp's perspective
  def my_nodes
    @my_nodes ||= Set.new
  end

  def tree_period_mapping
    @tree_period_mapping ||= {
      dry: {"PLUM" => 8, "LEMON" => 8, "APPLE" => 9, "BANANA" => 6},
      wet: {"PLUM" => 3, "LEMON" => 3, "APPLE" => 2, "BANANA" => 4}
    }
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
