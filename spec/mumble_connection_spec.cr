require "spec"
require "../src/wumble/mumble"

class Wumble::MumbleConnection
  def update_user_for_spec(payload : Bytes)
    update_user(payload)
  end
end

describe Wumble::MumbleConnection do
  it "places a new user without channel_id in Root and preserves later channel state" do
    connection = Wumble::MumbleConnection.new("example.test", 64_738, "wumble", "")
    session = 28_u32

    connection.update_user_for_spec(
      Wumble::Protobuf.field(1, session.to_u64) + Wumble::Protobuf.string(3, "tsp")
    )
    connection.users[session].should eq("tsp")
    connection.user_channels[session].should eq(0_u32)

    connection.update_user_for_spec(
      Wumble::Protobuf.field(1, session.to_u64) + Wumble::Protobuf.field(5, 7_u64)
    )
    connection.update_user_for_spec(
      Wumble::Protobuf.field(1, session.to_u64) + Wumble::Protobuf.string(3, "tsp updated")
    )
    connection.user_channels[session].should eq(7_u32)
  end
end
