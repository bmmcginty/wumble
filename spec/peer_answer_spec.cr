require "spec"
require "../src/wumble/datachannel"

# A browser offer, cut down to what the gateway parses: one audio section per
# speaker, each with its Opus payload type and the MID header extension.
private def browser_offer(*mids : Int32) : String
  String.build do |sdp|
    sdp << "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
    sdp << "a=group:BUNDLE " << mids.join(' ') << "\r\na=msid-semantic: WMS *\r\n"
    mids.each do |mid|
      sdp << "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\n"
      sdp << "a=ice-ufrag:abcd\r\na=ice-pwd:0123456789abcdef0123456789ab\r\na=ice-options:trickle\r\n"
      sdp << "a=fingerprint:sha-256 "
      sdp << "8F:1A:2B:3C:4D:5E:6F:70:81:92:A3:B4:C5:D6:E7:F8:09:1A:2B:3C:4D:5E:6F:70:81:92:A3:B4:C5:D6:E7:F8\r\n"
      sdp << "a=setup:actpass\r\na=mid:" << mid << "\r\n"
      sdp << "a=extmap:5 urn:ietf:params:rtp-hdrext:sdes:mid\r\n"
      sdp << (mid == 0 ? "a=sendrecv\r\n" : "a=recvonly\r\n")
      sdp << "a=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n"
      sdp << "a=ssrc:" << (9000 + mid) << " cname:browser\r\n"
    end
  end
end

describe Wumble::Peer do
  # A speaker whose section is answered without "a=ssrc:" leaves the browser no
  # way to route that speaker's RTP: it receives the packets and discards them
  # until a later negotiation republishes the section, which is why a Mumble
  # user who joined could only be heard once somebody else joined too.
  it "names every bridged speaker's SSRC in the answer that introduces it" do
    peer = Wumble::Peer.new
    begin
      peer.request_speaker(41_u32)
      peer.accept_offer(browser_offer(0)).should be_false
      first_answer = peer.local_description.not_nil!
      first_answer.should contain("a=ssrc:41 cname:wumble-41")

      # A second speaker needs a section the browser has not offered yet.
      requested = false
      peer.on_renegotiation_needed { requested = true }
      peer.request_speaker(42_u32)
      requested.should be_true

      peer.accept_offer(browser_offer(0, 1)).should be_false
      answer = peer.local_description.not_nil!
      peer.speaker_mids.should eq({41_u32 => "0", 42_u32 => "1"})
      answer.should contain("a=ssrc:41 cname:wumble-41")
      answer.should contain("a=ssrc:42 cname:wumble-42")
    ensure
      peer.close
    end
  end

  # forward_opus stamps the MID extension onto every packet, so the answer has
  # to negotiate it; otherwise the browser cannot demultiplex the BUNDLE by mid.
  it "answers with the MID header extension the offer assigned" do
    peer = Wumble::Peer.new
    begin
      peer.request_speaker(41_u32)
      peer.accept_offer(browser_offer(0))
      peer.local_description.not_nil!.should contain("a=extmap:5 urn:ietf:params:rtp-hdrext:sdes:mid")
    ensure
      peer.close
    end
  end
end
