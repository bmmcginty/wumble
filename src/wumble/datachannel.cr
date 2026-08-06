require "set"

@[Link("datachannel")]
@[Link(ldflags: "#{__DIR__}/receiver_bridge.c")]
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
  fun wumble_receiver_start = wumble_receiver_start(pc : Handle) : Int32
  fun wumble_receiver_received = wumble_receiver_received(pc : Handle) : UInt64
  fun wumble_receiver_queued = wumble_receiver_queued(pc : Handle) : UInt64
  fun wumble_receiver_stop = wumble_receiver_stop(pc : Handle)
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

    getter speaker_mids = Hash(UInt32, String).new
    @sequence = Hash(UInt32, UInt16).new(0_u16)
    @timestamp = Hash(UInt32, UInt32).new(0_u32)
    @first_packet = Hash(UInt32, Bool).new(true)
    @next_mumble_frame = Hash(UInt32, UInt32).new
    @mumble_packet_frames = Hash(UInt32, UInt32).new
    @last_debug_at = Time.instant
    @remote_description_set = false
    @renegotiation_pending = false

    def initialize
      # Ask libdatachannel to print native error diagnostics to stderr/stdout;
      # callbacks from its C++ threads are unsafe in Crystal.
      LibDataChannel.rtc_init_logger(3, Pointer(Void).null)
      # libdatachannel requires a real (zero-initialized) configuration to use
      # its defaults; passing NULL segfaults in libdatachannel 0.24.
      config = LibDataChannel::Configuration.new
      @browser_fallback_frame_number = 0_u32
      @browser_first_rtp_timestamp = nil.as(UInt32?)
      @browser_packets = 0_u64
      @closed = false
      @pc = LibDataChannel.rtc_create_peer_connection(pointerof(config))
      raise "rtcCreatePeerConnection failed" if @pc < 0
      receiver_fd = LibDataChannel.wumble_receiver_start(@pc)
      raise "could not start WebRTC audio receiver" if receiver_fd < 0
      @receiver = IO::FileDescriptor.new(receiver_fd)
      spawn { receive_browser_audio }
      spawn { log_browser_receiver_debug }
    end

    def on_opus(&block : Bytes, UInt32 ->)
      @on_opus = block
    end

    # Returns true when additional known speakers still need another offered
    # audio section.
    def accept_offer(sdp : String) : Bool
      @opus_payload_types = opus_payload_types(sdp)
      @mid_extension_ids = mid_extension_ids(sdp)
      result = LibDataChannel.rtc_set_remote_description(@pc, sdp.to_unsafe, "offer".to_unsafe)
      raise "rtcSetRemoteDescription failed (#{result})" if result < 0
      @remote_description_set = true
      assign_speaker_tracks
      @renegotiation_pending = @speakers.any? { |session| !@tracks.has_key?(session) }
    end

    def add_candidate(candidate : String, mid : String)
      check LibDataChannel.rtc_add_remote_candidate(@pc, candidate.to_unsafe, mid.to_unsafe)
    end

    # Remember known Mumble sessions until the browser offer has installed the
    # remote media description. libdatachannel rejects rtcAddTrack before that
    # point when it is acting as the answerer.
    # Returns true when the browser must offer another audio section before
    # this speaker can be assigned a WebRTC track.
    def prepare_speaker(session : UInt32) : Bool
      @speakers << session
      assign_speaker_tracks if @remote_description_set
      return false if !@remote_description_set || @tracks.has_key?(session) || @renegotiation_pending
      @renegotiation_pending = true
      true
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
    # Mumble's protobuf Audio.frame_number counts 10 ms (480 sample) frames.
    # Use it when available rather than inferring the duration from the Opus
    # TOC: a mismatched inferred duration makes the browser conceal samples and
    # steadily expand its jitter buffer.
    def send_opus(session : UInt32, opus : Bytes, frame_number : UInt32? = nil)
      prepare_speaker(session)
      if track = @tracks[session]?
        if LibDataChannel.rtc_is_open(track)
          forward_opus(session, track, opus, frame_number)
        else
          @dropped_packets[session] += 1
        end
      else
        @dropped_packets[session] += 1
      end
    end

    # A Mumble terminator starts a new talkspurt, so mark its first RTP packet
    # and do not mistake the following silence for lost media.
    def end_voice(session : UInt32)
      @first_packet[session] = true
      @next_mumble_frame.delete(session)
      @mumble_packet_frames.delete(session)
    end

    def close
      return if @closed
      @closed = true
      if @pc >= 0
        LibDataChannel.wumble_receiver_stop(@pc)
        LibDataChannel.rtc_delete_peer_connection(@pc)
      end
      @pc = -1
    end

    # Packets cross the C bridge through a pipe so all parsing and Mumble I/O
    # runs on a Crystal-managed fiber rather than libdatachannel's threads.
    private def log_browser_receiver_debug
      until @closed
        sleep 5.seconds
        break if @closed
        next unless debug?
        STDERR.puts "WebRTC browser receiver: received=#{LibDataChannel.wumble_receiver_received(@pc)} queued=#{LibDataChannel.wumble_receiver_queued(@pc)} forwarded=#{@browser_packets}"
      end
    end

    private def receive_browser_audio
      loop do
        header = Bytes.new(2)
        @receiver.read_fully(header)
        size = IO::ByteFormat::BigEndian.decode(UInt16, header).to_i
        raise "invalid browser audio packet size" if size == 0 || size > 4093
        packet = Bytes.new(size)
        @receiver.read_fully(packet)
        if audio = opus_payload(packet)
          opus, rtp_timestamp = audio
          forward_browser_opus(opus, rtp_timestamp) unless opus.empty?
        end
      end
    rescue ex
      STDERR.puts "WebRTC browser audio receiver closed: #{ex.message || ex.class.name}" unless @closed
    end

    private def forward_browser_opus(opus : Bytes, rtp_timestamp : UInt32?)
      @browser_packets += 1
      frame_number = browser_frame_number(rtp_timestamp, opus)
      @on_opus.try &.call(opus, frame_number)
    end

    # Preserve gaps in the browser RTP clock when encoding Mumble's 10 ms
    # frame number. Advancing a synthetic counter only for packets that reach
    # this bridge hides WebRTC loss from Mumble and makes its decoder join the
    # samples on either side of the loss, causing an audible click.
    private def browser_frame_number(rtp_timestamp : UInt32?, opus : Bytes) : UInt32
      if timestamp = rtp_timestamp
        first = @browser_first_rtp_timestamp ||= timestamp
        return (timestamp &- first) // 480_u32
      end
      frame_number = @browser_fallback_frame_number
      @browser_fallback_frame_number &+= opus_duration_samples(opus) // 480_u32
      frame_number
    end

    private def opus_payload(packet : Bytes) : Tuple(Bytes, UInt32?)?
      # A track message is normally an RTP packet. Keep the raw-payload path
      # for libdatachannel versions configured with an Opus depacketizer.
      return {packet, nil} unless packet.size >= 12 && (packet[0] >> 6) == 2
      timestamp = IO::ByteFormat::BigEndian.decode(UInt32, packet[4, 4])
      offset = 12 + (packet[0] & 0x0f) * 4
      return nil if offset > packet.size
      if packet[0] & 0x10 != 0
        return nil if offset + 4 > packet.size
        extension_words = IO::ByteFormat::BigEndian.decode(UInt16, packet[offset + 2, 2])
        offset += 4 + extension_words * 4
      end
      padding = packet[0] & 0x20 != 0 ? packet[-1].to_i : 0
      return nil if padding > packet.size - offset
      {packet[offset, packet.size - offset - padding], timestamp}
    end

    private def forward_opus(session : UInt32, track : LibDataChannel::Handle, opus : Bytes, frame_number : UInt32?)
      duration = opus_duration_samples(opus)
      preserve_mumble_sequence_gap(session, frame_number, duration)
      @timestamp[session] = frame_number.not_nil! &* 480_u32 if frame_number
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

    # RTP timestamps identify the duration of a loss, while RTP sequence gaps
    # tell the browser's jitter buffer that it should apply Opus PLC. Mumble's
    # frame number provides both signals when native UDP drops a packet.
    private def preserve_mumble_sequence_gap(session : UInt32, frame_number : UInt32?, duration : UInt32)
      return unless frame_number
      packet_frames = duration // 480_u32
      return if packet_frames == 0
      if expected = @next_mumble_frame[session]?
        gap = frame_number.not_nil! &- expected
        # A large jump is normal after silence when a terminator was lost; do
        # not turn it into an unbounded run of synthetic missing RTP packets.
        if gap > 0_u32 && gap <= 100_u32
          previous_packet_frames = @mumble_packet_frames[session]? || packet_frames
          missing_packets = (gap + previous_packet_frames - 1_u32) // previous_packet_frames
          @sequence[session] &+= missing_packets.to_u16
        end
      end
      @next_mumble_frame[session] = frame_number.not_nil! &+ packet_frames
      @mumble_packet_frames[session] = packet_frames
    end

    private def assign_speaker_tracks
      @speakers.each do |session|
        next if @tracks.has_key?(session)
        mid = available_speaker_mid
        break unless mid
        add_speaker_track(session, mid)
      end
    end

    private def available_speaker_mid : String?
      return "0" if @opus_payload_types.has_key?("0") && !@track_mids.values.includes?("0")
      @opus_payload_types.keys.find { |candidate| !@track_mids.values.includes?(candidate) }
    end

    private def add_speaker_track(session : UInt32, mid : String)
      # A stable, per-speaker SSRC lets the browser expose each voice as an
      # independent MediaStreamTrack.
      # RTP payload types are scoped to the offer. Chrome generally offers
      # Opus as 111, while Firefox commonly uses 109; answering with a new
      # payload type makes Firefox discard otherwise valid SRTP packets.
      payload_type = @opus_payload_types[mid]? || raise "offer has no Opus payload type for audio mid #{mid}"
      # The browser offers its microphone on m=0. Make that paired track
      # sendrecv so the answer authorizes browser-to-gateway RTP as well as
      # gateway-to-browser speaker audio; the remaining speaker tracks are
      # receive-only in the browser and stay sendonly here.
      direction = mid == "0" ? "sendrecv" : "sendonly"
      sdp = "m=audio 9 UDP/TLS/RTP/SAVPF #{payload_type}\r\na=mid:#{mid}\r\na=#{direction}\r\na=rtpmap:#{payload_type} opus/48000/2\r\na=fmtp:#{payload_type} minptime=10;useinbandfec=1\r\na=ssrc:#{session} cname:wumble-#{session}\r\n"
      track = LibDataChannel.rtc_add_track(@pc, sdp.to_unsafe)
      raise "rtcAddTrack failed (#{track})" if track < 0
      STDERR.puts "WebRTC: added Opus track session=#{session} mid=#{mid} track=#{track} ssrc=#{session} payload_type=#{payload_type} mid_extension=#{@mid_extension_ids[mid]?}" if debug?
      @tracks[session] = track
      @track_mids[session] = mid
      @speaker_mids[session] = mid
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
                          when 0..11  then [480_u32, 960_u32, 1_920_u32, 2_880_u32][config % 4]
                          when 12..15 then [480_u32, 960_u32][config % 2]
                          else             [120_u32, 240_u32, 480_u32, 960_u32][config % 4]
                          end
      frame_count = case opus[0] & 0x03
                    when 0    then 1_u32
                    when 1, 2 then 2_u32
                    else           opus.size > 1 ? (opus[1] & 0x3f).to_u32 : 1_u32
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
      STDERR.puts "WebRTC debug: local=#{local_address} remote=#{remote_address} candidate_pair=#{pair} browser_received=#{LibDataChannel.wumble_receiver_received(@pc)} browser_queued=#{LibDataChannel.wumble_receiver_queued(@pc)} browser_forwarded=#{@browser_packets}; #{tracks.join("; ")}"
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
