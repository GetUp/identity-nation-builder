class MemberExternalId < ApplicationRecord
  belongs_to :member

  validates_presence_of :member
  validates_uniqueness_of :external_id, scope: :system

  scope :with_system, ->(system) {
    where(system: system).order('updated_at DESC')
  }

end
