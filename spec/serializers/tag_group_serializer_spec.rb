require "rails_helper"

describe TagGroupSerializer do

  it "doesn't translate automatic group names in permissions" do
    staff_group = Group.find(Group::AUTO_GROUPS[:staff])
    staff_group.update_columns(name: "custom")

    tag_group = Fabricate(:tag_group)
    tag_group.permissions = [[
      Group::AUTO_GROUPS[:staff],
      TagGroupPermission.permission_types[:full]
    ]]
    tag_group.save!

    serialized = TagGroupSerializer.new(tag_group, root: false).as_json

    expect(serialized[:permissions].keys).to contain_exactly("staff")
  end

end
