require "spec"
require "../src/wumble/datachannel"

private def audio_sections(*mids : String) : Hash(String, UInt8)
  sections = Hash(String, UInt8).new
  mids.each { |mid| sections[mid] = 111_u8 }
  sections
end

describe Wumble::SpeakerTracks do
  it "leaves mid 0 to the microphone and hands out the rest in order" do
    tracks = Wumble::SpeakerTracks.new
    assigned = [] of Tuple(UInt32, String)
    assign = ->(session : UInt32, mid : String) { assigned << {session, mid}; true }

    # Before an offer arrives there is nothing to assign and nothing to ask for:
    # libdatachannel rejects rtcAddTrack until the remote description is set.
    tracks.add(7_u32, &assign).should be_false
    tracks.add(8_u32, &assign).should be_false
    assigned.should be_empty

    # mid 0 carries the browser's microphone. Two offered sections therefore
    # cover one speaker, not two, and the second still needs a section.
    tracks.accept_offer(audio_sections("0", "1"), &assign).should be_true
    assigned.should eq([{7_u32, "1"}])
    tracks.mids.should eq({7_u32 => "1"})

    tracks.accept_offer(audio_sections("0", "1", "2"), &assign).should be_false
    tracks.mids.should eq({7_u32 => "1", 8_u32 => "2"})
  end

  it "keeps asking for another section until every speaker has one" do
    tracks = Wumble::SpeakerTracks.new
    assign = ->(_session : UInt32, _mid : String) { true }

    # The first speaker fits in the section the browser already offered
    # alongside the microphone's.
    tracks.accept_offer(audio_sections("0", "1"), &assign).should be_false
    tracks.add(7_u32, &assign).should be_false
    tracks.mids[7_u32].should eq("1")

    # A speaker the browser has no section for asks for a renegotiation once;
    # a second one arriving before that offer lands is coalesced into it.
    tracks.add(8_u32, &assign).should be_true
    tracks.add(9_u32, &assign).should be_false
    tracks.renegotiation_pending?.should be_true

    # Each offer adds exactly one section, so accepting one must re-arm the
    # request for whoever is still uncovered. Dropping this result is what
    # previously deadlocked the handshake and starved every later speaker.
    tracks.accept_offer(audio_sections("0", "1", "2"), &assign).should be_true
    tracks.mids[8_u32].should eq("2")
    tracks.add(10_u32, &assign).should be_false

    tracks.accept_offer(audio_sections("0", "1", "2", "3"), &assign).should be_true
    tracks.mids[9_u32].should eq("3")

    tracks.accept_offer(audio_sections("0", "1", "2", "3", "4"), &assign).should be_false
    tracks.mids[10_u32].should eq("4")
    tracks.renegotiation_pending?.should be_false
  end

  it "leaves a section free when the track could not be created" do
    tracks = Wumble::SpeakerTracks.new
    tracks.add(7_u32) { true }
    tracks.add(8_u32) { true }

    # rtcAddTrack failed for the first speaker, so mid 1 must stay available.
    tracks.accept_offer(audio_sections("0", "1")) { |session, _mid| session != 7_u32 }.should be_true
    tracks.mids.should eq({8_u32 => "1"})
    tracks.renegotiation_pending?.should be_true
  end
end
