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
  fun wumble_init_logger = wumble_init_logger()
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
  # Which Mumble session owns which offered audio m= section.
  #
  # The gateway is always the WebRTC answerer, so it can never add an m= section
  # on its own: a speaker can only be bridged once the browser has offered a
  # section for it. This class owns that handshake's bookkeeping and is kept
  # free of libdatachannel handles so it can be exercised without opening a peer
  # connection (see spec/speaker_tracks_spec.cr).
  class SpeakerTracks
    getter speakers = Set(UInt32).new
    # session -> mid of the audio section carrying that speaker
    getter mids = Hash(UInt32, String).new
    # mid -> Opus payload type, reparsed from every offer
    getter payload_types = Hash(String, UInt8).new
    getter? offered = false
    getter? renegotiation_pending = false

    # Installs the payload types of a newly accepted offer and assigns any
    # sections it made available. Returns true when known speakers still need
    # another offered section.
    def accept_offer(payload_types : Hash(String, UInt8), &assign : UInt32, String -> Bool) : Bool
      @payload_types = payload_types
      @offered = true
      assign_speakers(&assign)
      @renegotiation_pending = @speakers.any? { |session| !@mids.has_key?(session) }
    end

    # Remembers a Mumble session until an offered section is available for it.
    # Returns true when the browser must offer another audio section before this
    # speaker can be bridged; the caller MUST act on that by asking the browser
    # to renegotiate. A dropped `true` latches @renegotiation_pending with no
    # offer ever arriving to clear it, which starves every later speaker of a
    # track for the life of the peer connection.
    def add(session : UInt32, &assign : UInt32, String -> Bool) : Bool
      @speakers << session
      assign_speakers(&assign) if @offered
      return false if !@offered || @mids.has_key?(session) || @renegotiation_pending
      @renegotiation_pending = true
      true
    end

    private def assign_speakers(&assign : UInt32, String -> Bool)
      @speakers.each do |session|
        next if @mids.has_key?(session)
        mid = available_mid
        break unless mid
        # Record the mid only once the track really exists, so a failed
        # rtcAddTrack leaves the section free for the next attempt.
        @mids[session] = mid if assign.call(session, mid)
      end
    end

    # The browser offers its microphone on mid 0 and libdatachannel only answers
    # sections it can pair with a local track, so mid 0 must always be claimed.
    private def available_mid : String?
      return "0" if @payload_types.has_key?("0") && !@mids.values.includes?("0")
      @payload_types.keys.find { |candidate| !@mids.values.includes?(candidate) }
    end
  end

  class Peer
    getter pc : LibDataChannel::Handle
    @tracks = Hash(UInt32, LibDataChannel::Handle).new
    @speaker_tracks = SpeakerTracks.new
    @dropped_packets = Hash(UInt32, UInt64).new(0_u64)
    @sent_packets = Hash(UInt32, UInt64).new(0_u64)
    # These counters are updated in the Mumble UDP receive fiber but emitted
    # only as five-second summaries. Never write a log line per voice packet:
    # doing so can itself create the scheduling jitter we are trying to find.
    @voice_received_packets = Hash(UInt32, UInt64).new(0_u64)
    @voice_received_bytes = Hash(UInt32, UInt64).new(0_u64)
    @voice_forwarded_packets = Hash(UInt32, UInt64).new(0_u64)
    @voice_dropped_unassigned = Hash(UInt32, UInt64).new(0_u64)
    @voice_dropped_unopened = Hash(UInt32, UInt64).new(0_u64)
    @sent_bytes = Hash(UInt32, UInt64).new(0_u64)
    @mid_extension_ids = Hash(String, UInt8).new
    @sequence = Hash(UInt32, UInt16).new(0_u16)
    @timestamp = Hash(UInt32, UInt32).new(0_u32)
    @first_packet = Hash(UInt32, Bool).new(true)
    @receiver_fd : Int32
    @media_debug : Bool
    @next_mumble_frame = Hash(UInt32, UInt32).new
    @mumble_packet_frames = Hash(UInt32, UInt32).new
    @last_debug_at = Time.instant

    def initialize
      # Configure libdatachannel debug logging with timestamps so its
      # internal RTP/RTCP processing can be correlated with our bridge
      # diagnostics (see receiver_bridge.c log_callback).
      LibDataChannel.wumble_init_logger
      # libdatachannel requires a real (zero-initialized) configuration to use
      # its defaults; passing NULL segfaults in libdatachannel 0.24.
      config = LibDataChannel::Configuration.new
      @browser_fallback_frame_number = 0_u32
      @browser_first_rtp_timestamp = nil.as(UInt32?)
      @browser_packets = 0_u64
      @browser_pipe_delay_packets = 0_u64
      @browser_pipe_delay_total_ms = 0_u64
      @browser_pipe_delay_max_ms = 0_u32
      @closed = false
      @media_debug = ENV["WUMBLE_DEBUG"]? == "1"
      @pc = LibDataChannel.rtc_create_peer_connection(pointerof(config))
      raise "rtcCreatePeerConnection failed" if @pc < 0
      receiver_fd = LibDataChannel.wumble_receiver_start(@pc)
      raise "could not start WebRTC audio receiver" if receiver_fd < 0
      @receiver_fd = receiver_fd
      spawn { receive_browser_audio }
      spawn { log_browser_receiver_debug }
      spawn { log_mumble_voice_batches }
    end

    def on_opus(&block : Bytes, UInt32 ->)
      @on_opus = block
    end

    # Invoked when the browser must offer another audio section before a known
    # speaker can be bridged. Voice packets can reveal a speaker before its
    # Mumble UserState arrives, so this fires from the UDP voice fiber too.
    def on_renegotiation_needed(&block : ->)
      @on_renegotiation_needed = block
    end

    def speaker_mids : Hash(UInt32, String)
      @speaker_tracks.mids
    end

    # Returns true when additional known speakers still need another offered
    # audio section.
    def accept_offer(sdp : String) : Bool
      payload_types = opus_payload_types(sdp)
      @mid_extension_ids = mid_extension_ids(sdp)
      result = LibDataChannel.rtc_set_remote_description(@pc, sdp.to_unsafe, "offer".to_unsafe)
      raise "rtcSetRemoteDescription failed (#{result})" if result < 0
      @speaker_tracks.accept_offer(payload_types) { |session, mid| add_speaker_track(session, mid) }
    end

    def add_candidate(candidate : String, mid : String)
      check LibDataChannel.rtc_add_remote_candidate(@pc, candidate.to_unsafe, mid.to_unsafe)
    end

    # Remember a Mumble session and bridge it as soon as the browser has offered
    # an audio section for it, asking for another section when it has not.
    # libdatachannel rejects rtcAddTrack until the offer has installed the
    # remote media description, so sessions seen before then are only recorded.
    #
    # This is the only entry point on purpose: SpeakerTracks#add coalesces its
    # request into a single pending renegotiation, so a caller that ignored the
    # request would latch that flag with no offer ever arriving to clear it,
    # starving every later speaker of a track for the life of this Peer.
    def request_speaker(session : UInt32) : Nil
      needed = @speaker_tracks.add(session) { |speaker, mid| add_speaker_track(speaker, mid) }
      @on_renegotiation_needed.try &.call if needed
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
      request_speaker(session)
      if track = @tracks[session]?
        if LibDataChannel.rtc_is_open(track)
          if forward_opus(session, track, opus, frame_number)
            record_mumble_voice(session, opus.size, :forwarded)
          else
            @dropped_packets[session] += 1
            record_mumble_voice(session, opus.size, :unassigned)
          end
        else
          @dropped_packets[session] += 1
          record_mumble_voice(session, opus.size, :unopened)
        end
      else
        @dropped_packets[session] += 1
        record_mumble_voice(session, opus.size, :unassigned)
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
        delay_average = @browser_pipe_delay_packets > 0 ? @browser_pipe_delay_total_ms // @browser_pipe_delay_packets : 0_u64
        STDERR.puts "WebRTC browser receiver: received=#{LibDataChannel.wumble_receiver_received(@pc)} queued=#{LibDataChannel.wumble_receiver_queued(@pc)} forwarded=#{@browser_packets} pipe_delay_ms_avg=#{delay_average} max=#{@browser_pipe_delay_max_ms} samples=#{@browser_pipe_delay_packets}"
        @browser_pipe_delay_packets = 0_u64
        @browser_pipe_delay_total_ms = 0_u64
        @browser_pipe_delay_max_ms = 0_u32
      end
    end

    private def record_mumble_voice(session : UInt32, bytes : Int32, result : Symbol)
      return unless debug?
      @voice_received_packets[session] += 1
      @voice_received_bytes[session] += bytes.to_u64
      case result
      when :forwarded  then @voice_forwarded_packets[session] += 1
      when :unassigned then @voice_dropped_unassigned[session] += 1
      when :unopened   then @voice_dropped_unopened[session] += 1
      end
    end

    private def log_mumble_voice_batches
      until @closed
        sleep 5.seconds
        break if @closed
        next unless debug?
        next if @voice_received_packets.empty?
        sessions = @voice_received_packets.keys.sort.map do |session|
          "session=#{session} received=#{@voice_received_packets[session]} bytes=#{@voice_received_bytes[session]} forwarded=#{@voice_forwarded_packets[session]} dropped_unassigned=#{@voice_dropped_unassigned[session]} dropped_unopened=#{@voice_dropped_unopened[session]}"
        end
        @voice_received_packets.clear
        @voice_received_bytes.clear
        @voice_forwarded_packets.clear
        @voice_dropped_unassigned.clear
        @voice_dropped_unopened.clear
        STDERR.puts "Mumble-to-WebRTC voice batch (5s): #{sessions.join("; ")}"
      end
    end

    private def receive_browser_audio
      buffer = Bytes.new(4_096)
      pending = [] of UInt8
      until @closed
        count = LibC.read(@receiver_fd, buffer.to_unsafe, buffer.size)
        if count > 0
          buffer[0, count.to_i].each { |byte| pending << byte }
          offset = 0
          while pending.size - offset >= 6
            size = (pending[offset].to_i << 8) | pending[offset + 1].to_i
            raise "invalid browser audio packet size" if size == 0 || size > 4090
            break if pending.size - offset < size + 6
            enqueued_at = IO::ByteFormat::BigEndian.decode(UInt32, Bytes[pending[offset + 2], pending[offset + 3], pending[offset + 4], pending[offset + 5]])
            packet = Bytes.new(size) { |index| pending[offset + 6 + index] }
            if audio = opus_payload(packet)
              opus, rtp_timestamp = audio
              forward_browser_opus(opus, rtp_timestamp, enqueued_at) unless opus.empty?
            end
            offset += size + 6
          end
          pending = offset < pending.size ? pending[offset..] : [] of UInt8
        elsif count == 0
          break
        elsif Errno.value == Errno::EAGAIN
          sleep 1.millisecond
        elsif Errno.value != Errno::EINTR
          raise IO::Error.from_errno("WebRTC browser audio receiver read failed")
        end
      end
    rescue ex
      STDERR.puts "WebRTC browser audio receiver closed: #{ex.message || ex.class.name}" unless @closed
    end

    private def forward_browser_opus(opus : Bytes, rtp_timestamp : UInt32?, enqueued_at : UInt32)
      @browser_packets += 1
      pipe_delay = (Time.utc.to_unix_ms.to_u64 & 0xffff_ffff_u64).to_u32 &- enqueued_at
      @browser_pipe_delay_packets += 1
      @browser_pipe_delay_total_ms += pipe_delay
      @browser_pipe_delay_max_ms = pipe_delay if pipe_delay > @browser_pipe_delay_max_ms
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
      # RTCP packets share the RTP v=2 prefix but use PT values 192-223
      # (RFC 3550). The browser sends periodic RTCP Sender Reports even
      # while muted; drop them here so they never reach the Mumble path.
      return nil if packet[1] >= 192
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
      # A renegotiated offer can renumber or drop a mid that already has a
      # track. Never raise here: this runs on the Mumble UDP voice fiber, where
      # an exception would take down every speaker at once.
      mid = @speaker_tracks.mids[session]?
      return false unless mid
      payload_type = @speaker_tracks.payload_types[mid]?
      return false unless payload_type
      preserve_mumble_sequence_gap(session, frame_number, duration)
      @timestamp[session] = frame_number.not_nil! &* 480_u32 if frame_number
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
      result = LibDataChannel.rtc_send_message(track, rtp.to_unsafe, rtp.size)
      return false if result < 0
      @sequence[session] &+= 1_u16
      @timestamp[session] &+= duration
      @first_packet[session] = false
      @sent_packets[session] += 1
      @sent_bytes[session] += opus.size.to_u64
      log_media_debug if debug?
      true
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

    # Returns false when the section could not be claimed, leaving it free for
    # the next speaker. This is reachable from the Mumble UDP voice fiber, so it
    # reports failure rather than raising.
    private def add_speaker_track(session : UInt32, mid : String) : Bool
      # A stable, per-speaker SSRC lets the browser expose each voice as an
      # independent MediaStreamTrack.
      # RTP payload types are scoped to the offer. Chrome generally offers
      # Opus as 111, while Firefox commonly uses 109; answering with a new
      # payload type makes Firefox discard otherwise valid SRTP packets.
      payload_type = @speaker_tracks.payload_types[mid]?
      unless payload_type
        STDERR.puts "WebRTC: offer has no Opus payload type for audio mid #{mid}; skipping session=#{session}"
        return false
      end
      # The browser offers its microphone on m=0. Make that paired track
      # sendrecv so the answer authorizes browser-to-gateway RTP as well as
      # gateway-to-browser speaker audio; the remaining speaker tracks are
      # receive-only in the browser and stay sendonly here.
      direction = mid == "0" ? "sendrecv" : "sendonly"
      sdp = "m=audio 9 UDP/TLS/RTP/SAVPF #{payload_type}\r\na=mid:#{mid}\r\na=#{direction}\r\na=rtpmap:#{payload_type} opus/48000/2\r\na=fmtp:#{payload_type} minptime=10;useinbandfec=1\r\na=ssrc:#{session} cname:wumble-#{session}\r\n"
      track = LibDataChannel.rtc_add_track(@pc, sdp.to_unsafe)
      if track < 0
        STDERR.puts "WebRTC: rtcAddTrack failed (#{track}) for session=#{session} mid=#{mid}"
        return false
      end
      STDERR.puts "WebRTC: added Opus track session=#{session} mid=#{mid} track=#{track} ssrc=#{session} payload_type=#{payload_type} mid_extension=#{@mid_extension_ids[mid]?}" if debug?
      @tracks[session] = track
      true
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
      @media_debug
    end

    private def check(result : Int32)
      raise "libdatachannel error #{result}" if result < 0
    end
  end
end
