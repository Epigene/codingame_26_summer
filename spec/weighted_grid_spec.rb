RSpec.describe WeightedGrid, instance_name: :grid do
  let(:grid) do
    described_class.new(width, height)
  end

  let(:width) { 2 }
  let(:height) { 2 }

  describe "#cheapest_path(from, to)" do
    subject(:cheapest_path) { grid.cheapest_path(*args) }

    context "when both diagonal paths are equivalent" do
      let(:args) { ["0 1", "1 0"] }

      it "returns an the path that goes North first" do
        is_expected.to eq(["0 1", "0 0", "1 0"])
      end
    end

    context "when diagonal paths are not equivalent due to N path being costlier" do
      let(:args) { ["0 1", "1 0"] }

      before { grid.update_cost("0 0", 3) }

      it "returns the one best path via E->N" do
        is_expected.to eq(["0 1", "1 1", "1 0"])
      end
    end
  end

  describe "#shortest_path(from, to)" do
    subject(:shortest_path) { grid.shortest_path(*args) }

    context "when going NE" do
      let(:args) { ["0 1", "1 0"] }

      it { is_expected.to eq(["0 1", "0 0", "1 0"]) }
    end

    context "when going SW" do
      let(:args) { ["1 0", "0 1"] }

      it { is_expected.to eq(["1 0", "1 1", "0 1"]) }
    end
  end
end
