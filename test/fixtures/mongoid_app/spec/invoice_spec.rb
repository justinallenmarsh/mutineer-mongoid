# frozen_string_literal: true

RSpec.describe Invoice do
  it "reads the seed and persists the calculated total" do
    expect(Invoice.find_by(reference: "seed").amount).to eq(7)
    invoice = Invoice.create!(reference: "written", amount: 5)
    expect(Invoice.find(invoice.id).total).to eq(10)
    invoice.display_total # Deliberately unasserted: parity checks expect survivors here.
    expect(Mongoid.default_client.database.name).to start_with("mutineer_")
    expect { Invoice.create!(reference: "written", amount: 1) }.to raise_error(Mongo::Error::OperationFailure)
  end
end
