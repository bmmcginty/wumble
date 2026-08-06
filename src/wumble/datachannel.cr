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
  fun rtc_add_track = rtcAddTrack(pc : Handle, sdp : UInt8*) : Handle
  fun rtc_send_message = rtcSendMessage(track : Handle, data : UInt8*, size : Int32) : Int32
  fun rtc_get_buffered_amount = rtcGetBufferedAmount(id : Handle) : Int32
  fun rtc_is_open = rtcIsOpen(id : Handle) : Bool
end

module Wumble
  class Peer
    getter pc : LibDataChannel::Handle
    @tracks = Hash(UInt32, LibDataChannel::Handle).new
    @speakers = Set(UInt32).new
    @dropped_packets = Hash(UInt32, UInt64).new(0_u64)
    @sent_packets = Hash(UInt32, UInt64).new(0_u64)
    @sent_bytes = Hash(UInt32, UInt64).new(0_u64)
    @opus_payload_types = Hash(String, UInt8).new
    @mid_extension_ids = Hash(String, UInt8).new
    @track_mids = Hash(UInt32, String).new
    @sequence = Hash(UInt32, UInt16).new(0_u16)
    @timestamp = Hash(UInt32, UInt32).new(0_u32)
    @first_packet = Hash(UInt32, Bool).new(true)
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
      @opus_payload_types = opus_payload_types(sdp)
      @mid_extension_ids = mid_extension_ids(sdp)
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
    # Live voice takes priority over continuity, so packets produced before a
    # track is open are discarded rather than creating a stale playout backlog.
    def send_opus(session : UInt32, opus : Bytes)
      prepare_speaker(session)
      if track = @tracks[session]?
        if LibDataChannel.rtc_is_open(track)
          forward_opus(session, track, opus)
        else
          @dropped_packets[session] += 1
        end
      else
        @dropped_packets[session] += 1
      end
    end

    # A Mumble terminator starts a new talkspurt, so mark its first RTP packet.
    def end_voice(session : UInt32)
      @first_packet[session] = true
    end

    def close
      LibDataChannel.rtc_delete_peer_connection(@pc) if @pc >= 0
      @pc = -1
    end

    private def forward_opus(session : UInt32, track : LibDataChannel::Handle, opus : Bytes)
      duration = opus_duration_samples(opus)
      mid = @track_mids[session]
      payload_type = @opus_payload_types[mid]
      # BUNDLE requires the MID extension to associate an RTP SSRC with its
      # m= section. libdatachannel's C Opus packetizer omits it, so construct
      # the small RTP header here and send it directly to the track.
      mid_extension_id = @mid_extension_ids[mid]?
      extension_size = mid_extension_id ? 4 + ((1 + mid.bytesize + 3) // 4) * 4 : 0
      rtp = Bytes.new(12 + extension_size + opus.size)
      rtp[0] = mid_extension_id ? 0x90_u8 : 0x80_u8
      rtp[1] = payload_type | (@first_packet[session] ? 0x80_u8 : 0_u8)
      IO::ByteFormat::BigEndian.encode(@sequence[session], rtp[2, 2])
      IO::ByteFormat::BigEndian.encode(@timestamp[session], rtp[4, 4])
      IO::ByteFormat::BigEndian.encode(session, rtp[8, 4])
      payload_offset = 12
      if extension_id = mid_extension_id
        IO::ByteFormat::BigEndian.encode(0xbede_u16, rtp[payload_offset, 2])
        IO::ByteFormat::BigEndian.encode((extension_size - 4).to_u16 // 4, rtp[payload_offset + 2, 2])
        rtp[payload_offset + 4] = (extension_id << 4) | (mid.bytesize - 1).to_u8
        rtp[payload_offset + 5, mid.bytesize].copy_from(mid.to_slice)
        payload_offset += extension_size
      end
      rtp[payload_offset, opus.size].copy_from(opus)
      check LibDataChannel.rtc_send_message(track, rtp.to_unsafe, rtp.size)
      @sequence[session] &+= 1_u16
      @timestamp[session] &+= duration
      @first_packet[session] = false
      @sent_packets[session] += 1
      @sent_bytes[session] += opus.size.to_u64
      log_media_debug if debug?
    end

    private def add_speaker_track(session : UInt32, mid : String)
      # A stable, per-speaker SSRC lets the browser expose each voice as an
      # independent MediaStreamTrack.
      # RTP payload types are scoped to the offer. Chrome generally offers
      # Opus as 111, while Firefox commonly uses 109; answering with a new
      # payload type makes Firefox discard otherwise valid SRTP packets.
      payload_type = @opus_payload_types[mid]? || raise "offer has no Opus payload type for audio mid #{mid}"
      sdp = "m=audio 9 UDP/TLS/RTP/SAVPF #{payload_type}\r\na=mid:#{mid}\r\na=sendonly\r\na=rtpmap:#{payload_type} opus/48000/2\r\na=fmtp:#{payload_type} minptime=10;useinbandfec=1\r\na=ssrc:#{session} cname:wumble-#{session}\r\n"
      track = LibDataChannel.rtc_add_track(@pc, sdp.to_unsafe)
      raise "rtcAddTrack failed (#{track})" if track < 0
      STDERR.puts "WebRTC: added Opus track session=#{session} mid=#{mid} track=#{track} ssrc=#{session} payload_type=#{payload_type} mid_extension=#{@mid_extension_ids[mid]?}" if debug?
      @tracks[session] = track
      @track_mids[session] = mid
    end

    private def mid_extension_ids(sdp : String) : Hash(String, UInt8)
      extension_ids = Hash(String, UInt8).new
      sdp.split("\nm=").each do |section|
        next unless section.starts_with?("audio ")
        mid = section.match(/(?:\A|\n)a=mid:([^\r\n]+)/).try(&.[1])
        extension = section.match(/(?:\A|\n)a=extmap:(\d+)(?:\/[^\s]+)?\s+urn:ietf:params:rtp-hdrext:sdes:mid/i).try(&.[1])
        next unless mid && extension
        extension_id = extension.to_u8?
        extension_ids[mid] = extension_id if extension_id && extension_id > 0 && extension_id < 15
      end
      extension_ids
    end

    private def opus_duration_samples(opus : Bytes) : UInt32
      return 960_u32 if opus.empty?
      config = opus[0] >> 3
      samples_per_frame = case config
                          when 0..11 then [480_u32, 960_u32, 1_920_u32, 2_880_u32][config % 4]
                          when 12..15 then [480_u32, 960_u32][config % 2]
                          else              [120_u32, 240_u32, 480_u32, 960_u32][config % 4]
                          end
      frame_count = case opus[0] & 0x03
                    when 0 then 1_u32
                    when 1, 2 then 2_u32
                    else opus.size > 1 ? (opus[1] & 0x3f).to_u32 : 1_u32
                    end
      samples_per_frame * frame_count
    end

    private def opus_payload_types(sdp : String) : Hash(String, UInt8)
      payload_types = Hash(String, UInt8).new
      # Each m= section has its own dynamic payload-type namespace.
      sdp.split("\nm=").each do |section|
        next unless section.starts_with?("audio ")
        mid = section.match(/(?:\A|\n)a=mid:([^\r\n]+)/).try(&.[1])
        opus = section.match(/(?:\A|\n)a=rtpmap:(\d+)\s+opus\/48000(?:\/\d+)?/i).try(&.[1])
        next unless mid && opus
        payload_type = opus.to_u16?
        payload_types[mid] = payload_type.to_u8 if payload_type && payload_type <= UInt8::MAX
      end
      payload_types
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
        "session=#{session} track=#{track} open=#{LibDataChannel.rtc_is_open(track)} samples=#{@sent_packets[session]} bytes=#{@sent_bytes[session]} dropped=#{@dropped_packets[session]} buffered=#{LibDataChannel.rtc_get_buffered_amount(track)}"
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
