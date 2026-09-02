require "spec"
require "../src/wumble/datachannel"

private def section(index : Int32) : Wumble::AudioSection
  Wumble::AudioSection.new(index.to_s, (1000 + index).to_u32, index)
end

describe Wumble::SpeakerSections do
  it "creates a section only when there is no free one to reuse" do
    sections = Wumble::SpeakerSections.new
    built = [] of Int32
    build = ->(index : Int32) { built << index; section(index) }

    sections.assign(41_u32, &build).should eq(:created)
    sections.assign(42_u32, &build).should eq(:created)
    sections.assign(41_u32, &build).should eq(:unchanged)
    built.should eq([1, 2])

    # mid 0 carries the microphone, so the first speaker section is mid 1.
    sections[41_u32]?.not_nil!.mid.should eq("1")
    sections[42_u32]?.not_nil!.mid.should eq("2")

    # A section a speaker leaves behind is handed to the next arrival rather
    # than a third being built: sections cannot be removed from a WebRTC
    # session, so reusing them is what bounds how many there are.
    sections.release(41_u32).not_nil!.mid.should eq("1")
    sections.assign(43_u32, &build).should eq(:reused)
    built.should eq([1, 2])
    sections[43_u32]?.not_nil!.mid.should eq("1")
  end

  it "keeps a reused section's SSRC and RTP stream running" do
    sections = Wumble::SpeakerSections.new
    sections.assign(41_u32) { |index| section(index) }
    reused = sections[41_u32]?.not_nil!
    reused.sequence = 900_u16
    reused.timestamp = 480_000_u32
    reused.next_mumble_frame = 77_u32

    sections.release(41_u32)
    sections.assign(42_u32) { |index| section(index) }
    handed_over = sections[42_u32]?.not_nil!
    handed_over.should be(reused)

    # The browser is watching one continuous stream on this SSRC and must not
    # see it restart, so sequence and timestamp carry on...
    handed_over.ssrc.should eq(1001_u32)
    handed_over.sequence.should eq(900_u16)
    handed_over.timestamp.should eq(480_000_u32)
    # ...while Mumble's frame numbering, which is per speaker and unrelated
    # between speakers, is rebased onto where the clock had got to.
    handed_over.timestamp_origin.should eq(480_000_u32)
    handed_over.frame_origin.should be_nil
    handed_over.next_mumble_frame.should be_nil
    handed_over.first_packet.should be_true
  end

  it "reports free and assigned sections" do
    sections = Wumble::SpeakerSections.new
    sections.assign(41_u32) { |index| section(index) }
    sections.assign(42_u32) { |index| section(index) }
    sections.assigned.map(&.mid).should eq(["1", "2"])
    sections.release(41_u32)
    sections.assigned.map(&.mid).should eq(["2"])
    sections.sections.size.should eq(2)
  end

  it "leaves the speaker unassigned when the section cannot be built" do
    sections = Wumble::SpeakerSections.new
    sections.assign(41_u32) { nil }.should eq(:failed)
    sections.sections.should be_empty
    sections[41_u32]?.should be_nil
  end
end
