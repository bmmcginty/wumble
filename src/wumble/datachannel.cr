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

  fun rtc_init_logger = rtcInitLogger(level : Int32, callback : Void*)
  fun rtc_create_peer_connection = rtcCreatePeerConnection(config : Configuration*) : Handle
  fun rtc_delete_peer_connection = rtcDeletePeerConnection(pc : Handle)
  fun rtc_set_remote_description = rtcSetRemoteDescription(pc : Handle, sdp : UInt8*, type : UInt8*) : Int32
  fun rtc_add_remote_candidate = rtcAddRemoteCandidate(pc : Handle, candidate : UInt8*, mid : UInt8*) : Int32
  fun rtc_get_local_description = rtcGetLocalDescription(pc : Handle, buffer : UInt8*, size : Int32) : Int32
  fun rtc_get_local_address = rtcGetLocalAddress(pc : Handle, buffer : UInt8*, size : Int32) : Int32
  fun rtc_get_remote_address = rtcGetRemoteAddress(pc : Handle, buffer : UInt8*, size : Int32) : Int32
  fun rtc_get_selected_candidate_pair = rtcGetSelectedCandidatePair(pc : Handle, local : UInt8*, local_size : Int32, remote : UInt8*, remote_size : Int32) : Int32
  struct PacketizerInit
    ssrc : UInt32
    cname : UInt8*
    payload_type : UInt8
    clock_rate : UInt32
    sequence_number : UInt16
    timestamp : UInt32
    max_fragment_size : UInt16
    nal_separator : Int32
    obu_packetization : Int32
    playout_delay_id : UInt8
    playout_delay_min : UInt16
    playout_delay_max : UInt16
    color_space_id : UInt8
    color_chroma_siting_horz : UInt8
    color_chroma_siting_vert : UInt8
    color_range : UInt8
    color_primaries : UInt8
    color_transfer : UInt8
    color_matrix : UInt8
  end

  fun rtc_add_track = rtcAddTrack(pc : Handle, sdp : UInt8*) : Handle
  fun rtc_set_opus_packetizer = rtcSetOpusPacketizer(track : Handle, init : PacketizerInit*) : Int32
  fun rtc_send_message = rtcSendMessage(track : Handle, data : UInt8*, size : Int32) : Int32
  fun rtc_get_buffered_amount = rtcGetBufferedAmount(id : Handle) : Int32
  fun rtc_is_open = rtcIsOpen(id : Handle) : Bool
end

module Wumble
  class Peer
    getter pc : LibDataChannel::Handle
    @tracks = Hash(UInt32, LibDataChannel::Handle).new
    @speakers = Set(UInt32).new
    @pending_audio = Hash(UInt32, Array(Bytes)).new { |sessions, session| sessions[session] = [] of Bytes }
    @sent_packets = Hash(UInt32, UInt64).new(0_u64)
    @sent_bytes = Hash(UInt32, UInt64).new(0_u64)
    @last_debug_at = Time.instant
    @remote_description_set = false

    def initialize
      # Ask libdatachannel to print native error diagnostics to stderr/stdout;
      # callbacks from its C++ threads are unsafe in Crystal.
      LibDataChannel.rtc_init_logger(3, Pointer(Void).null)
      # libdatachannel requires a real (zero-initialized) configuration to use
      # its defaults; passing NULL segfaults in libdatachannel 0.24.
      config = LibDataChannel::Configuration.new
      @pc = LibDataChannel.rtc_create_peer_connection(pointerof(config))
      raise "rtcCreatePeerConnection failed" if @pc < 0
    end

    def accept_offer(sdp : String)
      result = LibDataChannel.rtc_set_remote_description(@pc, sdp.to_unsafe, "offer".to_unsafe)
      raise "rtcSetRemoteDescription failed (#{result})" if result < 0
      @remote_description_set = true
      @speakers.each_with_index do |session, index|
        add_speaker_track(session, index.to_s) unless @tracks.has_key?(session)
      end
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
        if LibDataChannel.rtc_is_open(track)
          flush_pending(session, track)
          forward_opus(session, track, opus)
        else
          queue_opus(session, opus)
        end
      else
        queue_opus(session, opus)
      end
    end

    def close
      LibDataChannel.rtc_delete_peer_connection(@pc) if @pc >= 0
      @pc = -1
    end

    private def queue_opus(session : UInt32, opus : Bytes)
      packets = @pending_audio[session]
      packets.shift if packets.size >= 50
      packets << opus.dup
      STDERR.puts "WebRTC: queued Opus packet for session #{session} until its track is open"
    end

    private def flush_pending(session : UInt32, track : LibDataChannel::Handle)
      if packets = @pending_audio.delete(session)
        STDERR.puts "WebRTC: forwarding #{packets.size} queued Opus packets for session #{session}"
        packets.each { |opus| forward_opus(session, track, opus) }
      end
    end

    private def forward_opus(_session : UInt32, track : LibDataChannel::Handle, opus : Bytes)
      # The Opus packetizer constructs RTP headers and derives each packet's
      # duration from its TOC. Mumble packets are not necessarily 20 ms, so
      # incrementing a hand-built RTP timestamp by a fixed 960 samples makes
      # the browser discard or misplay streams with another frame duration.
      check LibDataChannel.rtc_send_message(track, opus.to_unsafe, opus.size)
      @sent_packets[_session] += 1
      @sent_bytes[_session] += opus.size.to_u64
      log_media_debug if debug?
    end

    private def add_speaker_track(session : UInt32, mid : String)
      # A stable, per-speaker SSRC lets the browser expose each voice as an
      # independent MediaStreamTrack.
      sdp = "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:#{mid}\r\na=sendonly\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\na=ssrc:#{session} cname:wumble-#{session}\r\n"
      track = LibDataChannel.rtc_add_track(@pc, sdp.to_unsafe)
      raise "rtcAddTrack failed (#{track})" if track < 0
      # rtcSendMessage sends encoded Opus samples through this packetizer. It
      # must own the RTP sequence and timestamp so the generated stream agrees
      # with its negotiated SSRC and correctly represents variable durations.
      cname = "wumble-#{session}"
      packetizer = LibDataChannel::PacketizerInit.new
      packetizer.ssrc = session
      packetizer.cname = cname.to_unsafe
      packetizer.payload_type = 111_u8
      packetizer.clock_rate = 48_000_u32
      check LibDataChannel.rtc_set_opus_packetizer(track, pointerof(packetizer))
      STDERR.puts "WebRTC: added Opus track session=#{session} mid=#{mid} track=#{track} ssrc=#{session} payload_type=111" if debug?
      @tracks[session] = track
    end

    # libdatachannel has no C API for outbound RTP counters. These values show
    # whether it accepted encoded Opus samples and whether they are stuck in a
    # track's send buffer; the selected ICE addresses identify the packet path
    # to inspect with tcpdump.
    private def log_media_debug
      now = Time.instant
      return if now - @last_debug_at < 5.seconds
      @last_debug_at = now
      local_address = rtc_address { |buffer, size| LibDataChannel.rtc_get_local_address(@pc, buffer, size) }
      remote_address = rtc_address { |buffer, size| LibDataChannel.rtc_get_remote_address(@pc, buffer, size) }
      candidate_local = Bytes.new(256, 0_u8)
      candidate_remote = Bytes.new(256, 0_u8)
      pair_result = LibDataChannel.rtc_get_selected_candidate_pair(@pc, candidate_local.to_unsafe, candidate_local.size, candidate_remote.to_unsafe, candidate_remote.size)
      pair = pair_result >= 0 ? "#{String.new(candidate_local.to_unsafe)} -> #{String.new(candidate_remote.to_unsafe)}" : "unavailable (#{pair_result})"
      tracks = @tracks.map do |session, track|
        "session=#{session} track=#{track} open=#{LibDataChannel.rtc_is_open(track)} samples=#{@sent_packets[session]} bytes=#{@sent_bytes[session]} buffered=#{LibDataChannel.rtc_get_buffered_amount(track)}"
      end
      STDERR.puts "WebRTC debug: local=#{local_address} remote=#{remote_address} candidate_pair=#{pair}; #{tracks.join("; ")}"
    end

    private def rtc_address(&)
      buffer = Bytes.new(256, 0_u8)
      result = yield buffer.to_unsafe, buffer.size
      result >= 0 ? String.new(buffer.to_unsafe) : "unavailable (#{result})"
    end

    private def debug? : Bool
      ENV["WUMBLE_DEBUG"]? == "1"
    end

    private def check(result : Int32)
      raise "libdatachannel error #{result}" if result < 0
    end
  end
end
