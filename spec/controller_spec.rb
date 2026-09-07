RSpec.describe Controller, instance_name: :controller do
  let(:controller) { described_class.new(field: field, towns: towns) }

  describe "#initialize(field:, towns:)" do
  end

  describe "#call(turn:, input:)" do
    subject(:call) { controller.call(**options) }

    let(:options) { { turn: turn, scores: scores, cells: cells } }

    let(:turn) { 1 }
    let(:scores) { [0, 0] }

    context "when initialized with fictitious small setup and only one possible connection" do
      let(:field) do
        <<~TEXT
          _0  _0  _0
          _1  _1  _1
          _2  _2  _2
        TEXT
      end

      let(:towns) { "0 0 0 1;1 2 2 x" }

      let(:cells) { {} }

      it "returns a command to connect town 0 to town 1" do
        is_expected.to eq("AUTOPLACE 0 0 2 2")
      end
    end
  end
end
