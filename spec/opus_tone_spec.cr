require "spec"
require "../src/wumble/opus_tone"

describe Wumble::OpusTone do
  it "encodes two 160 ms notes as 20 ms Opus packets" do
    packets = [] of Bytes
    Wumble::OpusTone.each_two_tone(440.0, 880.0) { |packet| packets << packet }

    packets.size.should eq(16)
    packets.all? { |packet| !packet.empty? }.should be_true
    packets[2].should_not eq(packets[10])
  end
end
