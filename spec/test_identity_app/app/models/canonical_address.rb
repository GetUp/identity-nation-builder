class CanonicalAddress < ApplicationRecord
  has_many :addresses
  has_and_belongs_to_many :areas

  before_save do
    self.search_text = [line1, line2, suburb, town, state, postcode, country].join(', ')
  end

  alias_attribute :zip, :postcode

  class << self
    def search(address = {})
      return nil if address.blank?

      address_string = [address[:line1], address[:line2], address[:suburb], address[:town], address[:state], address[:postcode], address[:country]].join(', ').upcase

      core_schema = ApplicationRecord.connection.quote_table_name(Settings.databases.extensions_schemas.core)
      query = CanonicalAddress.where('search_text % ?', address_string)
                              .order(Arel.sql("#{core_schema}.similarity(search_text, #{ApplicationRecord.connection.quote(address_string)}) DESC"))
                              .select(Arel.sql("*, #{core_schema}.similarity(search_text, #{ApplicationRecord.connection.quote(address_string)}) as similarity"))

      if address[:postcode]
        query = query.where(postcode: address[:postcode].to_s.upcase.delete(' '))
      end

      return nil unless (ca = query.first)

      ca if ca.similarity > 0.7
    end
  end
end
