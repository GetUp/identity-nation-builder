require 'rails_helper'

describe IdentityNationBuilder do
  context '#sync_type_item' do
    context 'with valid parameters' do
      context 'with rsvp' do
        it 'returns correct sync item type' do
          external_system_params = {'sync_type' => 'rsvp', 'event_id' => 1, 'mark_as_attended' => true, 'recruiter_id' => 2}

          expect(IdentityNationBuilder.sync_type_item(external_system_params)).to eq([1, true, 2])
        end
      end
      context 'with tag' do
        it 'returns correct sync item type' do
          external_system_params = {'sync_type' => 'tag', 'tag' => 'test_tag'}
          expect(IdentityNationBuilder.sync_type_item(external_system_params)).to eq(['test_tag'])
        end
      end

      context 'with mark_as_attended_to_all_events_on_date' do
        it 'returns correct sync item type' do
          external_system_params = {'sync_type' => 'mark_as_attended_to_all_events_on_date', 'site_slug' => 'action'}
          expect(IdentityNationBuilder.sync_type_item(external_system_params)).to eq([])
        end
      end
    end
    context 'with invalid parameters' do
      it 'returns no sync item type' do
        external_system_params = {'sync_type' => 'yada'}
        expect(IdentityNationBuilder.sync_type_item(external_system_params)).to be nil
      end
    end
  end

  context '#push' do
    before(:each) do
      @sync_id = 1
      Member.all.destroy_all
      2.times { FactoryBot.create(:member) }
      FactoryBot.create(:member_without_email)
      @members = Member.all
    end
    context 'event rsvp' do
      context 'with valid parameters' do
        it 'yeilds members_with_emails' do
          external_system_params = JSON.generate({'sync_type' => 'rsvp', 'event_id' => 1, 'mark_as_attended' => true})
          IdentityNationBuilder.push(@sync_id, @members, external_system_params) do |members_with_emails, campaign_name|
            expect(members_with_emails.count).to eq(3)
          end
        end
      end
    end
    context 'list tag' do
      context 'with valid parameters' do
        it 'yeilds members_with_emails' do
          external_system_params = JSON.generate({'sync_type' => 'tag', 'tag' => 'test_tag'})
          IdentityNationBuilder.push(@sync_id, @members, external_system_params) do |members_with_emails, campaign_name|
            expect(members_with_emails.count).to eq(3)
          end
        end
      end
    end
  end

  context '#push_in_batches' do
    before(:each) do
      @sync_id = 1
      Member.all.destroy_all
      2.times { FactoryBot.create(:member) }
      @members = Member.all
    end
    context 'event rsvp' do
      context 'with valid parameters' do
        it 'yeilds write_result_count' do
          external_system_params = JSON.generate({'sync_type' => 'rsvp', 'event_id' => 1, 'mark_as_attended' => true})
          expect(IdentityNationBuilder::API).to receive(:rsvp).exactly(1).times.with(anything, anything, 1, true, nil).and_yield(
            @members.length, [
              {identity_id: @members[0].id, nationbuilder_id: @members[0].id },
              {identity_id: @members[1].id, nationbuilder_id: @members[1].id },
            ])
          IdentityNationBuilder.push_in_batches(1, @members, external_system_params) do |batch_index, write_result_count|
            expect(write_result_count).to eq(@members.length)
          end
        end
      end
    end
    context 'list tag' do
      context 'with valid parameters' do
        it 'yeilds write_result_count' do
          external_system_params = JSON.generate({'sync_type' => 'tag', 'tag' => 'test_tag'})
          expect(IdentityNationBuilder::API).to receive(:tag).exactly(1).times.with(anything, anything, anything).and_yield(
            @members.length, [
              {identity_id: @members[0].id, nationbuilder_id: @members[0].id },
              {identity_id: @members[1].id, nationbuilder_id: @members[1].id },
            ])
          IdentityNationBuilder.push_in_batches(1, @members, external_system_params) do |batch_index, write_result_count|
            expect(write_result_count).to eq(@members.length)
          end
        end
      end
    end

    context 'mark_as_attended_to_all_events_on_date' do
      context 'with valid parameters' do
        it 'yeilds write_result_count' do
          external_system_params = JSON.generate({'sync_type' => 'mark_as_attended_to_all_events_on_date'})
          expect(IdentityNationBuilder::API).to receive(:mark_as_attended_to_all_events_on_date).exactly(1).times.with(nil, instance_of(@members.class))
.and_yield(
            3, [
              {identity_id: @members[0].id, nationbuilder_id: @members[0].id },
              {identity_id: @members[1].id, nationbuilder_id: @members[1].id },
            ])          
          IdentityNationBuilder.push_in_batches(1, @members, external_system_params) do |batch_index, write_result_count|
            expect(write_result_count).to eq(3)
          end
        end
      end
    end
  end

  describe '#attempt_to_rsvp_person_twice' do
    it 'will not raise error on rsvp_create with signup_id taken' do
      expect(IdentityNationBuilder::API.attempt_to_rsvp_person_twice(:rsvp_create, "signup_id has already been taken")).to eq(true)
    end
    it 'will raise error on rsvp create with different error' do
      expect(IdentityNationBuilder::API.attempt_to_rsvp_person_twice(:rsvp_create, "another error")).to eq(false)
    end
    it 'will raise error on different api call' do
      expect(IdentityNationBuilder::API.attempt_to_rsvp_person_twice(:someotherapicall, "signup_id has already been taken")).to eq(false)
    end
  end
end
