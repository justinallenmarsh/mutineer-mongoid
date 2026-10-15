# frozen_string_literal: true

class Invoice
  include Mongoid::Document

  field :amount, type: Integer
  field :reference, type: String
  index({ reference: 1 }, unique: true)

  def display_total
    total + 1
  end

  def total
    amount * 2
  end
end
