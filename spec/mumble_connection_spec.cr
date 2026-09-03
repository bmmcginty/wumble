require "spec"
require "../src/wumble/mumble"

class Wumble::MumbleConnection
  def update_user_for_spec(payload : Bytes)
    update_user(payload)
  end

  def text_message_for_spec(payload : Bytes)
    text_message(payload)
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

  it "reports a channel TextMessage and distinguishes one addressed to this user" do
    connection = Wumble::MumbleConnection.new("example.test", 64_738, "wumble", "")
    received = [] of {UInt32, String, Bool}
    connection.on_text_message { |actor, body, private_message| received << {actor, body, private_message} }

    connection.text_message_for_spec(
      Wumble::Protobuf.field(1, 4_u64) + Wumble::Protobuf.field(3, 9_u64) + Wumble::Protobuf.string(5, "hello channel")
    )
    connection.text_message_for_spec(
      Wumble::Protobuf.field(1, 4_u64) + Wumble::Protobuf.field(2, 11_u64) + Wumble::Protobuf.string(5, "hello you")
    )

    received.should eq([{4_u32, "hello channel", false}, {4_u32, "hello you", true}])
  end
end
