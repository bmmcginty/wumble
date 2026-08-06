require "set"

@[Link("datachannel")]
lib LibDataChannel
  alias Handle = Int32

  # Matches rtcConfiguration in libdatachannel's C API. libdatachannel 0.24
  # dereferences this argument, so a null pointer is not a valid "defaults"
  # configuration.
  struct Configuration
    ice_servers : UInt8**
    ice_servers_count : Int32
    proxy_server : UInt8*
    bind_address : UInt8*
    certificate_type : Int32
    ice_transport_policy : Int32
    enable_ice_tcp : Bool
    enable_ice_udp_mux : Bool
    disable_auto_negotiation : Bool
    force_media_transport : Bool
    port_range_begin : UInt16
    port_range_end : UInt16
    mtu : Int32
    max_message_size : Int32
  end

  fun rtc_create_peer_connection = rtcCreatePeerConnection(config : Configuration*) : Handle
  fun rtc_delete_peer_connection = rtcDeletePeerConnection(pc : Handle)
  fun rtc_set_remote_description = rtcSetRemoteDescription(pc : Handle, sdp : UInt8*, type : UInt8*) : Int32
  fun rtc_add_remote_candidate = rtcAddRemoteCandidate(pc : Handle, candidate : UInt8*, mid : UInt8*) : Int32
  fun rtc_get_local_description = rtcGetLocalDescription(pc : Handle, buffer : UInt8*, size : Int32) : Int32
  fun rtc_add_track = rtcAddTrack(pc : Handle, sdp : UInt8*) : Handle
  fun rtc_send_message = rtcSendMessage(track : Handle, data : UInt8*, size : Int32) : Int32
end

module Wumble
  class Peer
    getter pc : LibDataChannel::Handle
    @tracks = Hash(UInt32, LibDataChannel::Handle).new
    @speakers = Set(UInt32).new
    @pending_audio = Hash(UInt32, Array(Bytes)).new { |sessions, session| sessions[session] = [] of Bytes }
    @remote_description_set = false
    @sequence = Hash(UInt32, UInt16).new(0_u16)
    @timestamp = Hash(UInt32, UInt32).new(0_u32)

    def initialize
      # libdatachannel requires a real (zero-initialized) configuration to use
      # its defaults; passing NULL segfaults in libdatachannel 0.24.
      config = LibDataChannel::Configuration.new
      @pc = LibDataChannel.rtc_create_peer_connection(pointerof(config))
      raise "rtcCreatePeerConnection failed" if @pc < 0
    end

    def accept_offer(sdp : String)
      check LibDataChannel.rtc_set_remote_description(@pc, sdp.to_unsafe, "offer".to_unsafe)
      @remote_description_set = true
      @speakers.each_with_index do |session, index|
        add_speaker_track(session, index.to_s) unless @tracks.has_key?(session)
      end
      @pending_audio.each do |session, packets|
        packets.each { |opus| forward_opus(session, @tracks[session], opus) }
      end
      @pending_audio.clear
    end

    def add_candidate(candidate : String, mid : String)
      check LibDataChannel.rtc_add_remote_candidate(@pc, candidate.to_unsafe, mid.to_unsafe)
    end

    # Remember known Mumble sessions until the browser offer has installed the
    # remote media description. libdatachannel rejects rtcAddTrack before that
    # point when it is acting as the answerer.
    def prepare_speaker(session : UInt32)
      @speakers << session
      add_speaker_track(session, @tracks.size.to_s) if @remote_description_set && !@tracks.has_key?(session)
    end

    # Do not use libdatachannel's callbacks here. They run on its native C++
    # thread, which cannot enter Crystal's GC/runtime. Polling from the Crystal
    # signalling fiber keeps all WebSocket and GC work on Crystal-managed threads.
    def local_description : String?
      buffer = Bytes.new(65_536, 0_u8)
      result = LibDataChannel.rtc_get_local_description(@pc, buffer.to_unsafe, buffer.size)
      return nil if result == -3 # RTC_ERR_NOT_AVAIL while the answer is pending
      check result
      String.new(buffer.to_unsafe)
    end

    # One sendonly RTP track is created for every Mumble session. This is the
    # important boundary: no decoder, mixer, or shared browser MediaStream exists.
    def send_opus(session : UInt32, opus : Bytes)
      prepare_speaker(session)
      if track = @tracks[session]?
        forward_opus(session, track, opus)
      else
        packets = @pending_audio[session]
        packets.shift if packets.size >= 50
        packets << opus.dup
        STDERR.puts "WebRTC: queued Opus packet for session #{session} until tracks are negotiated"
      end
    end

    def close
      LibDataChannel.rtc_delete_peer_connection(@pc) if @pc >= 0
      @pc = -1
    end

    private def forward_opus(session : UInt32, track : LibDataChannel::Handle, opus : Bytes)
      sequence = @sequence[session] += 1
      timestamp = @timestamp[session] += 960 # 20 ms at Opus' 48 kHz RTP clock
      rtp = Bytes.new(12 + opus.size)
      rtp[0] = 0x80_u8
      rtp[1] = 111_u8
      IO::ByteFormat::BigEndian.encode(sequence, rtp[2, 2])
      IO::ByteFormat::BigEndian.encode(timestamp, rtp[4, 4])
      IO::ByteFormat::BigEndian.encode(session, rtp[8, 4])
      rtp[12, opus.size].copy_from(opus)
      check LibDataChannel.rtc_send_message(track, rtp.to_unsafe, rtp.size)
    end

    private def add_speaker_track(session : UInt32, mid : String)
      # A stable, per-speaker SSRC lets the browser expose each voice as an
      # independent MediaStreamTrack.
      sdp = "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:#{mid}\r\na=sendonly\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\na=ssrc:#{session} cname:wumble-#{session}\r\n"
      track = LibDataChannel.rtc_add_track(@pc, sdp.to_unsafe)
      raise "rtcAddTrack failed (#{track})" if track < 0
      @tracks[session] = track
    end

    private def check(result : Int32)
      raise "libdatachannel error #{result}" if result < 0
    end
  end
end
