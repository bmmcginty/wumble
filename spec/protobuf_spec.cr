require "spec"
require "../src/wumble/protobuf"

describe Wumble::Protobuf do
  it "round trips multi-byte varints" do
    encoded = Wumble::Protobuf.varint(300_u64)
    value, offset = Wumble::Protobuf.read_varint(encoded, 0)
    value.should eq(300)
    offset.should eq(encoded.size)
  end

  it "iterates length-delimited fields" do
    message = Wumble::Protobuf.string(3, "alice")
    fields = [] of {Int32, String}
    Wumble::Protobuf.fields(message) { |number, _wire, value| fields << {number, String.new(value)} }
    fields.should eq([{3, "alice"}])
  end
end
