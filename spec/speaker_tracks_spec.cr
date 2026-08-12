require "spec"
require "../src/wumble/datachannel"

private def audio_sections(*mids : String) : Hash(String, UInt8)
  sections = Hash(String, UInt8).new
  mids.each { |mid| sections[mid] = 111_u8 }
  sections
end

describe Wumble::SpeakerTracks do
  it "claims mid 0 first and hands out the remaining offered sections in order" do
    tracks = Wumble::SpeakerTracks.new
    assigned = [] of Tuple(UInt32, String)

    # Before an offer arrives there is nothing to assign and nothing to ask for:
    # libdatachannel rejects rtcAddTrack until the remote description is set.
    tracks.add(7_u32) { |session, mid| assigned << {session, mid}; true }.should be_false
    tracks.add(8_u32) { |session, mid| assigned << {session, mid}; true }.should be_false
    assigned.should be_empty

    tracks.accept_offer(audio_sections("0", "1")) { |session, mid| assigned << {session, mid}; true }.should be_false
    assigned.should eq([{7_u32, "0"}, {8_u32, "1"}])
    tracks.mids.should eq({7_u32 => "0", 8_u32 => "1"})
  end

  it "keeps asking for another section until every speaker has one" do
    tracks = Wumble::SpeakerTracks.new
    assign = ->(_session : UInt32, _mid : String) { true }

    # The first speaker fits in the section the browser already offered.
    tracks.accept_offer(audio_sections("0"), &assign).should be_false
    tracks.add(7_u32, &assign).should be_false
    tracks.mids[7_u32].should eq("0")

    # A speaker the browser has no section for asks for a renegotiation once;
    # a second one arriving before that offer lands is coalesced into it.
    tracks.add(8_u32, &assign).should be_true
    tracks.add(9_u32, &assign).should be_false
    tracks.renegotiation_pending?.should be_true

    # Each offer adds exactly one section, so accepting one must re-arm the
    # request for whoever is still uncovered. Dropping this result is what
    # previously deadlocked the handshake and starved every later speaker.
    tracks.accept_offer(audio_sections("0", "1"), &assign).should be_true
    tracks.mids[8_u32].should eq("1")
    tracks.add(10_u32, &assign).should be_false

    tracks.accept_offer(audio_sections("0", "1", "2"), &assign).should be_true
    tracks.mids[9_u32].should eq("2")

    tracks.accept_offer(audio_sections("0", "1", "2", "3"), &assign).should be_false
    tracks.mids[10_u32].should eq("3")
    tracks.renegotiation_pending?.should be_false
  end

  it "leaves a section free when the track could not be created" do
    tracks = Wumble::SpeakerTracks.new
    tracks.add(7_u32) { true }
    tracks.add(8_u32) { true }

    # rtcAddTrack failed for the first speaker, so mid 0 must stay available.
    tracks.accept_offer(audio_sections("0", "1")) { |session, _mid| session != 7_u32 }.should be_true
    tracks.mids.should eq({8_u32 => "0"})
    tracks.renegotiation_pending?.should be_true
  end
end
