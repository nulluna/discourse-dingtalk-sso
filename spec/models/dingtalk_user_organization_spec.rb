# frozen_string_literal: true

require "rails_helper"

RSpec.describe DingtalkUserOrganization do
  fab!(:user) { Fabricate(:user) }

  describe "validations" do
    it "requires user_id" do
      org = DingtalkUserOrganization.new(corp_id: "corp123", union_id: "union123")
      expect(org.valid?).to be false
      expect(org.errors[:user_id]).to be_present
    end

    it "requires corp_id" do
      org = DingtalkUserOrganization.new(user_id: user.id, union_id: "union123")
      expect(org.valid?).to be false
      expect(org.errors[:corp_id]).to be_present
    end

    it "requires union_id" do
      org = DingtalkUserOrganization.new(user_id: user.id, corp_id: "corp123")
      expect(org.valid?).to be false
      expect(org.errors[:union_id]).to be_present
    end

    it "validates corp_id length" do
      long_corp_id = "a" * 101
      org = DingtalkUserOrganization.new(
        user_id: user.id,
        corp_id: long_corp_id,
        union_id: "union123"
      )
      expect(org.valid?).to be false
      expect(org.errors[:corp_id]).to be_present
    end

    it "enforces unique corp_id per user" do
      DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )

      duplicate = DingtalkUserOrganization.new(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )

      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:corp_id]).to be_present
    end

    it "allows same corp_id for different users" do
      user2 = Fabricate(:user)

      org1 = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )

      org2 = DingtalkUserOrganization.create!(
        user: user2,
        corp_id: "corp_A",
        union_id: "union456"
      )

      expect(org1).to be_valid
      expect(org2).to be_valid
    end
  end

  describe "associations" do
    it "belongs to user" do
      org = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp123",
        union_id: "union123"
      )

      expect(org.user).to eq(user)
    end
  end

  describe ".organizations_for_user" do
    it "returns all organizations for a user ordered by last login" do
      org1 = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123",
        last_login_at: 2.days.ago
      )

      org2 = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_B",
        union_id: "union123",
        last_login_at: 1.day.ago
      )

      orgs = DingtalkUserOrganization.organizations_for_user(user.id)

      expect(orgs.count).to eq(2)
      expect(orgs.first).to eq(org2) # Most recent first
      expect(orgs.last).to eq(org1)
    end

    it "returns empty for user with no organizations" do
      orgs = DingtalkUserOrganization.organizations_for_user(user.id)
      expect(orgs).to be_empty
    end
  end

  describe ".users_for_organization" do
    it "returns all users for an organization" do
      user2 = Fabricate(:user)

      org1 = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123",
        last_login_at: 1.day.ago
      )

      org2 = DingtalkUserOrganization.create!(
        user: user2,
        corp_id: "corp_A",
        union_id: "union456",
        last_login_at: 2.days.ago
      )

      orgs = DingtalkUserOrganization.users_for_organization("corp_A")

      expect(orgs.count).to eq(2)
      expect(orgs.map(&:user)).to contain_exactly(user, user2)
      expect(orgs.first).to eq(org1) # Most recent first
    end

    it "returns empty for organization with no users" do
      orgs = DingtalkUserOrganization.users_for_organization("nonexistent_corp")
      expect(orgs).to be_empty
    end
  end

  describe ".find_by_user_and_corp" do
    it "finds association by user_id and corp_id" do
      org = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )

      found = DingtalkUserOrganization.find_by_user_and_corp(user.id, "corp_A")
      expect(found).to eq(org)
    end

    it "returns nil if not found" do
      found = DingtalkUserOrganization.find_by_user_and_corp(user.id, "nonexistent")
      expect(found).to be_nil
    end
  end

  describe "#touch_last_login!" do
    it "updates last_login_at timestamp" do
      org = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123",
        last_login_at: 1.day.ago
      )

      freeze_time do
        org.touch_last_login!
        expect(org.reload.last_login_at).to be_within(1.second).of(Time.zone.now)
      end
    end
  end

  describe ".all_corp_ids" do
    it "returns distinct list of corp_ids" do
      user2 = Fabricate(:user)

      DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )

      DingtalkUserOrganization.create!(
        user: user2,
        corp_id: "corp_A",
        union_id: "union456"
      )

      DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_B",
        union_id: "union123"
      )

      corp_ids = DingtalkUserOrganization.all_corp_ids
      expect(corp_ids).to contain_exactly("corp_A", "corp_B")
    end
  end

  describe ".organization_user_counts" do
    it "returns user count per organization" do
      user2 = Fabricate(:user)
      user3 = Fabricate(:user)

      DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )

      DingtalkUserOrganization.create!(
        user: user2,
        corp_id: "corp_A",
        union_id: "union456"
      )

      DingtalkUserOrganization.create!(
        user: user3,
        corp_id: "corp_B",
        union_id: "union789"
      )

      counts = DingtalkUserOrganization.organization_user_counts
      expect(counts["corp_A"]).to eq(2)
      expect(counts["corp_B"]).to eq(1)
    end
  end

  describe "multi-organization scenario" do
    it "allows same user to associate with multiple organizations" do
      org1 = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_A",
        union_id: "union123"
      )

      org2 = DingtalkUserOrganization.create!(
        user: user,
        corp_id: "corp_B",
        union_id: "union123"
      )

      orgs = DingtalkUserOrganization.organizations_for_user(user.id)
      expect(orgs.count).to eq(2)
      expect(orgs.map(&:corp_id)).to contain_exactly("corp_A", "corp_B")
      expect(orgs.map(&:union_id).uniq).to eq(["union123"]) # Same unionId
    end
  end
end
