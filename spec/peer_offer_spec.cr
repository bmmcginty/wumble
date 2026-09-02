require "spec"
require "../src/wumble/datachannel"

# A stand-in browser: a bare libdatachannel peer connection that answers the
# gateway's offers by mirroring every section it is offered. The gateway parses
# nothing out of an answer, so this only has to be well formed enough for
# libdatachannel to accept.
private class BrowserPeer
  def initialize
    config = LibDataChannel::Configuration.new
    config.disable_auto_negotiation = true
    @pc = LibDataChannel.rtc_create_peer_connection(pointerof(config))
    raise "rtcCreatePeerConnection failed" if @pc < 0
    @answered = Set(String).new
  end

  def answer(offer : String) : String
    # Strip the candidates in both directions. Two real peer connections on one
    # machine would otherwise try to reach each other and log a failed DTLS
    # handshake; none of this is about the media path.
    offer = without_candidates(offer)
    result = LibDataChannel.rtc_set_remote_description(@pc, offer.to_unsafe, "offer".to_unsafe)
    raise "browser setRemoteDescription failed (#{result})" if result < 0
    mids(offer).each do |mid|
      next unless @answered.add?(mid)
      # The gateway offers the microphone recvonly and every speaker sendonly,
      # so this side sends on mid 0 and receives on the rest.
      sending = mid == Wumble::Peer::MICROPHONE_MID
      sdp = String.build do |media|
        media << "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:" << mid << "\r\n"
        media << "a=" << (sending ? "sendonly" : "recvonly") << "\r\n"
        media << "a=rtpmap:111 opus/48000/2\r\n"
        media << "a=ssrc:5000 cname:browser\r\n" if sending
      end
      raise "browser rtcAddTrack failed for mid #{mid}" if LibDataChannel.rtc_add_track(@pc, sdp.to_unsafe) < 0
    end
    result = LibDataChannel.rtc_set_local_description(@pc, "answer".to_unsafe)
    raise "browser setLocalDescription failed (#{result})" if result < 0
    buffer = Bytes.new(65_536, 0_u8)
    size = LibDataChannel.rtc_get_local_description(@pc, buffer.to_unsafe, buffer.size)
    raise "browser answer unavailable (#{size})" if size < 0
    without_candidates(String.new(buffer.to_unsafe))
  end

  private def without_candidates(sdp : String) : String
    sdp.lines(chomp: false).reject { |line| line.starts_with?("a=candidate:") || line.starts_with?("a=end-of-candidates") }.join
  end

  def close
    LibDataChannel.rtc_delete_peer_connection(@pc)
  end

  private def mids(sdp : String) : Array(String)
    sdp.scan(/^a=mid:(\S+)/m).map(&.[1])
  end
end

private def mids(sdp : String) : Array(String)
  sdp.scan(/^a=mid:(\S+)/m).map(&.[1])
end

private def section(sdp : String, mid : String) : String
  sdp.split(/^m=/m).find(&.includes?("a=mid:#{mid}\r\n")) || ""
end

describe Wumble::Peer do
  # The browser has to be audible before anybody else is in the channel, and
  # the microphone section is the one section that never changes hands.
  it "offers the microphone and nothing else until there are speakers" do
    peer = Wumble::Peer.new
    begin
      offer = peer.offer.not_nil!
      mids(offer).should eq(["0"])
      section(offer, "0").should contain("a=recvonly")
      # It only receives, so it names no stream of its own.
      section(offer, "0").should_not contain("a=ssrc:")
      peer.assignments.should be_empty
    ensure
      peer.close
    end
  end

  it "creates one section per speaker and names each in the offer" do
    peer = Wumble::Peer.new
    browser = BrowserPeer.new
    begin
      peer.accept_answer(browser.answer(peer.offer.not_nil!)).should be_false

      peer.set_speakers([41_u32, 42_u32]).should eq(:offer)
      offer = peer.offer.not_nil!
      mids(offer).should eq(["0", "1", "2"])
      section(offer, "1").should contain("a=sendonly")
      section(offer, "2").should contain("a=sendonly")

      # SSRCs belong to the sections, so they are distinct and predictable.
      first = Wumble::Peer::SPEAKER_SSRC_BASE &+ 1
      second = Wumble::Peer::SPEAKER_SSRC_BASE &+ 2
      section(offer, "1").should contain("a=ssrc:#{first} ")
      section(offer, "2").should contain("a=ssrc:#{second} ")
      peer.assignments.should eq([
        {mid: "1", ssrc: first, session: 41_u32},
        {mid: "2", ssrc: second, session: 42_u32},
      ])
    ensure
      browser.close
      peer.close
    end
  end

  # The whole point of fixing the SSRC to the section: a friend whose client
  # reconnects arrives under a new Mumble session and costs a signalling
  # message rather than a renegotiation.
  it "hands a departed speaker's section to the next arrival without renegotiating" do
    peer = Wumble::Peer.new
    browser = BrowserPeer.new
    begin
      peer.accept_answer(browser.answer(peer.offer.not_nil!))
      peer.set_speakers([41_u32]).should eq(:offer)
      peer.accept_answer(browser.answer(peer.offer.not_nil!))
      ssrc = peer.assignments.first[:ssrc]

      peer.set_speakers([] of UInt32).should eq(:sections)
      peer.assignments.should be_empty

      peer.set_speakers([42_u32]).should eq(:sections)
      peer.assignments.should eq([{mid: "1", ssrc: ssrc, session: 42_u32}])
      # Same section, same SSRC, and no second speaker section was built.
      mids(peer.local_description.not_nil!).should eq(["0", "1"])
    ensure
      browser.close
      peer.close
    end
  end

  # libdatachannel will not build a new offer while the answer to the last one
  # is outstanding, so a speaker who arrives in that window has to be picked up
  # when the cycle completes rather than dropped.
  it "coalesces a speaker who arrives while an offer is in flight" do
    peer = Wumble::Peer.new
    browser = BrowserPeer.new
    begin
      peer.accept_answer(browser.answer(peer.offer.not_nil!))
      peer.set_speakers([41_u32])
      outstanding = peer.offer.not_nil!

      peer.set_speakers([41_u32, 42_u32]).should eq(:offer)
      peer.offer.should be_nil

      peer.accept_answer(browser.answer(outstanding)).should be_true
      offer = peer.offer.not_nil!
      mids(offer).should eq(["0", "1", "2"])
      peer.assignments.map(&.[:session]).should eq([41_u32, 42_u32])
    ensure
      browser.close
      peer.close
    end
  end
end
