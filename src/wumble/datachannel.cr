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
  fun rtc_set_local_description = rtcSetLocalDescription(pc : Handle, type : UInt8*) : Int32
  fun rtc_add_remote_candidate = rtcAddRemoteCandidate(pc : Handle, candidate : UInt8*, mid : UInt8*) : Int32
  fun rtc_get_local_description = rtcGetLocalDescription(pc : Handle, buffer : UInt8*, size : Int32) : Int32
  fun rtc_get_local_address = rtcGetLocalAddress(pc : Handle, buffer : UInt8*, size : Int32) : Int32
  fun rtc_get_remote_address = rtcGetRemoteAddress(pc : Handle, buffer : UInt8*, size : Int32) : Int32
  fun rtc_get_selected_candidate_pair = rtcGetSelectedCandidatePair(pc : Handle, local : UInt8*, local_size : Int32, remote : UInt8*, remote_size : Int32) : Int32
  fun wumble_receiver_start = wumble_receiver_start(pc : Handle) : Int32
  fun wumble_receiver_attach = wumble_receiver_attach(pc : Handle, track : Handle) : Int32
  fun wumble_receiver_received = wumble_receiver_received(pc : Handle) : UInt64
  fun wumble_receiver_queued = wumble_receiver_queued(pc : Handle) : UInt64
  fun wumble_peer_state = wumble_peer_state(pc : Handle) : Int32
  fun wumble_ice_state = wumble_ice_state(pc : Handle) : Int32
  fun wumble_receiver_stop = wumble_receiver_stop(pc : Handle)
  fun rtc_add_track = rtcAddTrack(pc : Handle, sdp : UInt8*) : Handle
  fun rtc_send_message = rtcSendMessage(track : Handle, data : UInt8*, size : Int32) : Int32
  fun rtc_get_buffered_amount = rtcGetBufferedAmount(id : Handle) : Int32
  fun rtc_is_open = rtcIsOpen(id : Handle) : Bool
end

module Wumble
  # One offered audio m= section, and the RTP stream that runs on it.
  #
  # The SSRC belongs to the section, never to the speaker. That is the whole
  # trick: a section can be handed from one Mumble session to the next without
  # the SDP changing at all, so a friend who reconnects costs a signalling
  # message rather than a renegotiation. It also means the RTP stream has to
  # survive a change of owner, which is why sequence and timestamp live here.
  class AudioSection
    getter mid : String
    getter ssrc : UInt32
    getter track : LibDataChannel::Handle
    getter session : UInt32?

    property sequence = 0_u16
    property timestamp = 0_u32
    property first_packet = true
    # Mumble frame numbers are per speaker and unrelated between speakers, so
    # they are rebased onto this section's running RTP clock at every handover.
    property frame_origin : UInt32?
    property timestamp_origin = 0_u32
    property next_mumble_frame : UInt32?
    property mumble_packet_frames : UInt32?
    property sent_packets = 0_u64
    property sent_bytes = 0_u64
    property dropped_packets = 0_u64

    def initialize(@mid : String, @ssrc : UInt32, @track : LibDataChannel::Handle)
    end

    # Hand this section to a speaker. The RTP sequence and timestamp keep
    # running: the browser is looking at one continuous stream on this SSRC and
    # must not see it restart. Only the mapping from Mumble's frame numbers is
    # reset, because the new speaker's numbering has nothing to do with the
    # previous one's.
    def take(session : UInt32) : Nil
      @session = session
      @frame_origin = nil
      @timestamp_origin = @timestamp
      @next_mumble_frame = nil
      @mumble_packet_frames = nil
      @first_packet = true
    end

    def free : Nil
      @session = nil
    end

    def free? : Bool
      @session.nil?
    end
  end

  # Which Mumble session owns which audio m= section.
  #
  # The gateway offers, so it creates a section exactly when one is needed and
  # never in advance. Sections cannot be given back -- WebRTC has no way to
  # remove an m= line from a session -- so one a speaker leaves behind is kept
  # and handed to the next arrival instead. The number of sections therefore
  # settles at the high-water mark of simultaneous speakers, which is the least
  # this can cost.
  #
  # This class holds no libdatachannel handles beyond the opaque integer, so it
  # can be exercised without opening a peer connection (see
  # spec/speaker_sections_spec.cr).
  class SpeakerSections
    getter sections = [] of AudioSection

    def []?(session : UInt32) : AudioSection?
      @sections.find { |section| section.session == session }
    end

    def assigned : Array(AudioSection)
      @sections.reject(&.free?)
    end

    # Give this speaker a section, reusing a free one when there is one.
    # Returns :created when a new section had to be built and the browser has
    # therefore never seen it, :reused when a free section changed hands,
    # :unchanged when the speaker already had one, and :failed when the section
    # could not be built.
    def assign(session : UInt32, &create : Int32 -> AudioSection?) : Symbol
      return :unchanged if self[session]?
      if free = @sections.find(&.free?)
        free.take(session)
        return :reused
      end
      # mid 0 carries the browser's microphone, so speakers start at 1.
      section = create.call(@sections.size + 1)
      return :failed unless section
      @sections << section
      section.take(session)
      :created
    end

    def release(session : UInt32) : AudioSection?
      section = self[session]?
      section.try &.free
      section
    end
  end

  class Peer
    # rtcState / rtcIceState values from libdatachannel's rtc.h.
    PEER_DISCONNECTED =  3
    PEER_FAILED       =  4
    ICE_FAILED        =  4
    ICE_DISCONNECTED  =  5

    # The gateway offers, so it chooses these rather than reading them out of a
    # browser offer. One Opus payload type and one header-extension ID for
    # every section: an answerer has to echo both, so nothing has to be parsed
    # back out of the answer.
    OPUS_PAYLOAD_TYPE = 111_u8
    MID_EXTENSION_ID  =   1_u8
    MICROPHONE_MID    = "0"
    # Fixed to the section, not to the speaker. Kept clear of Murmur's session
    # IDs, which start at 1, so a log line naming an SSRC is never ambiguous.
    SPEAKER_SSRC_BASE = 0xC0FF_0000_u32
    # The gateway is the only side that offers, so a lost answer would leave it
    # unable to ever build another one and every later speaker without a
    # section. Treat that as a broken media path, which is already recoverable.
    ANSWER_TIMEOUT = 10.seconds

    getter pc : LibDataChannel::Handle
    getter sections = SpeakerSections.new
    @microphone_track : LibDataChannel::Handle
    # These counters are updated in the Mumble UDP receive fiber but emitted
    # only as five-second summaries. Never log per voice packet: doing so can
    # itself create the scheduling jitter we are trying to find.
    @voice_received_packets = Hash(UInt32, UInt64).new(0_u64)
    @voice_received_bytes = Hash(UInt32, UInt64).new(0_u64)
    @voice_forwarded_packets = Hash(UInt32, UInt64).new(0_u64)
    @voice_dropped_unassigned = Hash(UInt32, UInt64).new(0_u64)
    @voice_dropped_unopened = Hash(UInt32, UInt64).new(0_u64)
    @receiver_fd : Int32
    @media_debug : Bool
    @negotiating = false
    @renegotiation_pending = false
    @offer_sent_at : Time::Instant? = nil
    @last_debug_at = Time.instant

    def initialize
      # Configure libdatachannel debug logging with timestamps so its internal
      # RTP/RTCP processing can be correlated with our bridge diagnostics (see
      # receiver_bridge.c log_callback).
      LibDataChannel.wumble_init_logger
      # libdatachannel requires a real (zero-initialized) configuration to use
      # its defaults; passing NULL segfaults in libdatachannel 0.24.
      config = LibDataChannel::Configuration.new
      # Offers are produced here and nowhere else. With automatic negotiation
      # libdatachannel would build one the moment a track is added, before the
      # section has an owner to name.
      config.disable_auto_negotiation = true
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
      # The microphone is offered before anything else so the browser can be
      # heard from the moment the media path is up, whether or not anybody else
      # is in the channel yet.
      microphone_track = LibDataChannel.rtc_add_track(@pc, audio_section(MICROPHONE_MID, "recvonly").to_unsafe)
      raise "rtcAddTrack failed (#{microphone_track}) for the microphone section" if microphone_track < 0
      @microphone_track = microphone_track
      check LibDataChannel.wumble_receiver_attach(@pc, microphone_track)
      spawn { receive_browser_audio }
      spawn { log_browser_receiver_debug }
      spawn { log_mumble_voice_batches }
      spawn { monitor_connection }
    end

    def on_opus(&block : Bytes, UInt32 ->)
      @on_opus = block
    end

    # Invoked when libdatachannel's ICE agent has given up on the media path.
    # The browser cannot be relied on to notice this itself: its consent checks
    # can keep reporting "connected" long after libjuice has logged "Lost
    # connectivity", which leaves the session up, silent and unrecoverable.
    def on_connection_lost(&block : String ->)
      @on_connection_lost = block
    end

    # The complete set of Mumble sessions whose voice belongs on this
    # connection. Sections are handed out and taken back here and nowhere else,
    # which is what keeps a section's owner and its RTP state in step.
    #
    # Returns :offer when a section had to be created, so the browser needs a
    # new offer before it can receive on it; :sections when only the mapping
    # changed and the browser needs nothing but the mapping; :unchanged when
    # nothing moved.
    def set_speakers(sessions : Array(UInt32)) : Symbol
      created = false
      changed = false
      @sections.assigned.each do |section|
        owner = section.session
        next if owner.nil? || sessions.includes?(owner)
        STDERR.puts "WebRTC: freed audio mid=#{section.mid} from session=#{owner}" if debug?
        section.free
        changed = true
      end
      sessions.each do |session|
        case @sections.assign(session) { |index| build_speaker_section(index) }
        when :created
          created = true
          changed = true
        when :reused
          changed = true
        end
      end
      return :offer if created
      changed ? :sections : :unchanged
    end

    # mid, SSRC and owner for every section currently carrying a speaker. The
    # browser needs this to know which of its audio elements is whom; it is
    # ordinary signalling data, not part of the SDP.
    def assignments : Array(NamedTuple(mid: String, ssrc: UInt32, session: UInt32))
      @sections.assigned.compact_map do |section|
        if session = section.session
          {mid: section.mid, ssrc: section.ssrc, session: session}
        end
      end
    end

    # The gateway is the only side that offers. Returns the SDP to send, or nil
    # when an offer is already in flight: libdatachannel will not build a new
    # one until the answer to the last has landed, so the request is remembered
    # and accept_answer reports that it is due.
    def offer : String?
      if @negotiating
        @renegotiation_pending = true
        return nil
      end
      result = LibDataChannel.rtc_set_local_description(@pc, "offer".to_unsafe)
      raise "rtcSetLocalDescription failed (#{result})" if result < 0
      @negotiating = true
      # libdatachannel gathers host candidates synchronously, but not always
      # before this call returns. Poll only until they reach the SDP instead of
      # imposing a fixed delay on every offer.
      deadline = Time.instant + 250.milliseconds
      sdp = nil.as(String?)
      loop do
        if description = local_description
          sdp = description
          break if description.includes?("a=candidate:")
        end
        break if Time.instant >= deadline
        sleep 10.milliseconds
      end
      raise "libdatachannel did not produce an offer" unless sdp
      STDERR.puts "WebRTC: local ICE candidate was not ready after 250 ms; offering without it" unless sdp.includes?("a=candidate:")
      @offer_sent_at = Time.instant
      sdp
    end

    # Returns true when a section was created while this answer was outstanding
    # and the browser therefore needs another offer.
    def accept_answer(sdp : String) : Bool
      result = LibDataChannel.rtc_set_remote_description(@pc, sdp.to_unsafe, "answer".to_unsafe)
      raise "rtcSetRemoteDescription failed (#{result})" if result < 0
      @negotiating = false
      @offer_sent_at = nil
      pending = @renegotiation_pending
      @renegotiation_pending = false
      pending
    end

    def add_candidate(candidate : String, mid : String)
      check LibDataChannel.rtc_add_remote_candidate(@pc, candidate.to_unsafe, mid.to_unsafe)
    end

    # Do not use libdatachannel's callbacks here. They run on its native C++
    # thread, which cannot enter Crystal's GC/runtime. Polling from the Crystal
    # signalling fiber keeps all WebSocket and GC work on Crystal-managed threads.
    def local_description : String?
      buffer = Bytes.new(65_536, 0_u8)
      result = LibDataChannel.rtc_get_local_description(@pc, buffer.to_unsafe, buffer.size)
      return nil if result == -3 # RTC_ERR_NOT_AVAIL while the description is pending
      check result
      String.new(buffer.to_unsafe)
    end

    # One sendonly RTP stream per section. This is the important boundary: no
    # decoder, mixer, or shared browser MediaStream exists. Voice for a session
    # holding no section is dropped rather than bridged on the spot: the set of
    # speakers is decided by set_speakers, so a whisper from another channel
    # cannot take a section away from somebody in yours.
    # Mumble's protobuf Audio.frame_number counts 10 ms (480 sample) frames.
    # Use it when available rather than inferring the duration from the Opus
    # TOC: a mismatched inferred duration makes the browser conceal samples and
    # steadily expand its jitter buffer.
    def send_opus(session : UInt32, opus : Bytes, frame_number : UInt32? = nil)
      section = @sections[session]?
      unless section
        record_mumble_voice(session, opus.size, :unassigned)
        return
      end
      unless LibDataChannel.rtc_is_open(section.track)
        section.dropped_packets += 1
        record_mumble_voice(session, opus.size, :unopened)
        return
      end
      if forward_opus(section, opus, frame_number)
        record_mumble_voice(session, opus.size, :forwarded)
      else
        section.dropped_packets += 1
        record_mumble_voice(session, opus.size, :unassigned)
      end
    end

    # A Mumble terminator starts a new talkspurt, so mark its first RTP packet
    # and do not mistake the following silence for lost media.
    def end_voice(session : UInt32)
      return unless section = @sections[session]?
      section.first_packet = true
      section.next_mumble_frame = nil
      section.mumble_packet_frames = nil
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

    # libdatachannel reports connection state only through callbacks on its own
    # threads, which cannot enter Crystal's runtime, so receiver_bridge latches
    # the state and this fiber polls the latch. Report the edge into a lost
    # path once; a recovered path re-arms it so a later loss is reported again.
    private def monitor_connection
      lost = false
      until @closed
        sleep 1.second
        break if @closed
        ice = LibDataChannel.wumble_ice_state(@pc)
        peer = LibDataChannel.wumble_peer_state(@pc)
        stalled = @negotiating && @offer_sent_at.try { |sent| Time.instant - sent > ANSWER_TIMEOUT } == true
        down = stalled || ice == ICE_FAILED || ice == ICE_DISCONNECTED || peer == PEER_FAILED || peer == PEER_DISCONNECTED
        if down && !lost
          lost = true
          detail = stalled ? "no answer within #{ANSWER_TIMEOUT}" : "peer_state=#{peer} ice_state=#{ice}"
          STDERR.puts "WebRTC: media path lost (#{detail})"
          @on_connection_lost.try &.call(detail)
        elsif !down && lost
          lost = false
          STDERR.puts "WebRTC: media path recovered (peer_state=#{peer} ice_state=#{ice})"
        end
      end
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

    # Never raise here: this runs on the Mumble UDP voice fiber, where an
    # exception would take down every speaker at once.
    private def forward_opus(section : AudioSection, opus : Bytes, frame_number : UInt32?) : Bool
      duration = opus_duration_samples(opus)
      preserve_mumble_sequence_gap(section, frame_number, duration)
      if number = frame_number
        origin = section.frame_origin
        unless origin
          origin = number
          section.frame_origin = number
        end
        section.timestamp = section.timestamp_origin &+ ((number &- origin) &* 480_u32)
      end
      # BUNDLE requires the MID extension to associate an RTP SSRC with its
      # m= section. libdatachannel's C Opus packetizer omits it, so construct
      # the small RTP header here and send it directly to the track.
      extension_size = 4 + ((1 + section.mid.bytesize + 3) // 4) * 4
      rtp = Bytes.new(12 + extension_size + opus.size)
      rtp[0] = 0x90_u8
      rtp[1] = OPUS_PAYLOAD_TYPE | (section.first_packet ? 0x80_u8 : 0_u8)
      IO::ByteFormat::BigEndian.encode(section.sequence, rtp[2, 2])
      IO::ByteFormat::BigEndian.encode(section.timestamp, rtp[4, 4])
      IO::ByteFormat::BigEndian.encode(section.ssrc, rtp[8, 4])
      offset = 12
      IO::ByteFormat::BigEndian.encode(0xbede_u16, rtp[offset, 2])
      IO::ByteFormat::BigEndian.encode((extension_size - 4).to_u16 // 4, rtp[offset + 2, 2])
      rtp[offset + 4] = (MID_EXTENSION_ID << 4) | (section.mid.bytesize - 1).to_u8
      rtp[offset + 5, section.mid.bytesize].copy_from(section.mid.to_slice)
      offset += extension_size
      rtp[offset, opus.size].copy_from(opus)
      return false if LibDataChannel.rtc_send_message(section.track, rtp.to_unsafe, rtp.size) < 0
      section.sequence &+= 1_u16
      section.timestamp &+= duration
      section.first_packet = false
      section.sent_packets += 1
      section.sent_bytes += opus.size.to_u64
      log_media_debug if debug?
      true
    end

    # RTP timestamps identify the duration of a loss, while RTP sequence gaps
    # tell the browser's jitter buffer that it should apply Opus PLC. Mumble's
    # frame number provides both signals when native UDP drops a packet.
    private def preserve_mumble_sequence_gap(section : AudioSection, frame_number : UInt32?, duration : UInt32)
      return unless frame_number
      packet_frames = duration // 480_u32
      return if packet_frames == 0
      if expected = section.next_mumble_frame
        gap = frame_number.not_nil! &- expected
        # A large jump is normal after silence when a terminator was lost; do
        # not turn it into an unbounded run of synthetic missing RTP packets.
        if gap > 0_u32 && gap <= 100_u32
          previous_packet_frames = section.mumble_packet_frames || packet_frames
          missing_packets = (gap + previous_packet_frames - 1_u32) // previous_packet_frames
          section.sequence &+= missing_packets.to_u16
        end
      end
      section.next_mumble_frame = frame_number.not_nil! &+ packet_frames
      section.mumble_packet_frames = packet_frames
    end

    private def build_speaker_section(index : Int32) : AudioSection?
      mid = index.to_s
      ssrc = SPEAKER_SSRC_BASE &+ index.to_u32
      track = LibDataChannel.rtc_add_track(@pc, audio_section(mid, "sendonly", ssrc).to_unsafe)
      if track < 0
        STDERR.puts "WebRTC: rtcAddTrack failed (#{track}) for audio mid #{mid}"
        return nil
      end
      STDERR.puts "WebRTC: added audio mid=#{mid} ssrc=#{ssrc} track=#{track}" if debug?
      AudioSection.new(mid, ssrc, track)
    end

    # forward_opus stamps the MID header extension onto every packet, so every
    # section negotiates it. Without it the browser has only the SSRC to route
    # BUNDLE'd audio by.
    private def audio_section(mid : String, direction : String, ssrc : UInt32? = nil) : String
      String.build do |sdp|
        sdp << "m=audio 9 UDP/TLS/RTP/SAVPF " << OPUS_PAYLOAD_TYPE << "\r\n"
        sdp << "a=mid:" << mid << "\r\n"
        sdp << "a=" << direction << "\r\n"
        sdp << "a=extmap:" << MID_EXTENSION_ID << " urn:ietf:params:rtp-hdrext:sdes:mid\r\n"
        sdp << "a=rtpmap:" << OPUS_PAYLOAD_TYPE << " opus/48000/2\r\n"
        sdp << "a=fmtp:" << OPUS_PAYLOAD_TYPE << " minptime=10;useinbandfec=1\r\n"
        # The microphone section only receives, so it names no stream.
        sdp << "a=ssrc:" << ssrc << " cname:wumble-" << mid << "\r\n" if ssrc
      end
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
      sections = @sections.sections.map do |section|
        "mid=#{section.mid} ssrc=#{section.ssrc} session=#{section.session || "free"} open=#{LibDataChannel.rtc_is_open(section.track)} samples=#{section.sent_packets} bytes=#{section.sent_bytes} dropped=#{section.dropped_packets} buffered=#{LibDataChannel.rtc_get_buffered_amount(section.track)}"
      end
      STDERR.puts "WebRTC debug: local=#{local_address} remote=#{remote_address} candidate_pair=#{pair} browser_received=#{LibDataChannel.wumble_receiver_received(@pc)} browser_queued=#{LibDataChannel.wumble_receiver_queued(@pc)} browser_forwarded=#{@browser_packets}; #{sections.join("; ")}"
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
      raise "libdatachannel call failed (#{result})" if result < 0
      result
    end
  end
end
