require "socket"
require "openssl"
require "./protobuf"
require "./crypt_state"
require "./opus_tone"

def bytes_repr(bytes : Bytes)
  String.build do |io|
    bytes.each do |b|
      case b
      when 0x20..0x7e
        case b
        when '\\'.ord
          io << "\\\\"
        when '"'.ord
          io << "\\\""
        else
          io << b.chr
        end
      when '\n'.ord
        io << "\\n"
      when '\r'.ord
        io << "\\r"
      when '\t'.ord
        io << "\\t"
      else
        io << "\\x%02x" % b
      end
    end
  end
end

module Wumble
  # Mumble's TCP control protocol. Voice is intentionally accepted separately by
  # UdpVoice; TCP packets are not mixed or decoded by this class.
  class MumbleConnection
    VERSION       =  0
    UDPTUNNEL     =  1
    AUTHENTICATE  =  2
    PING          =  3
    REJECT        =  4
    SERVER_SYNC   =  5
    CHANNEL_STATE =  7
    # Mumble.proto numbers UserRemove 8 and UserState 9. UserRemove was 12 --
    # PermissionDenied -- for long enough to be worth naming here: departures
    # were then never processed, so @users kept every stale session and a
    # rejoining user appeared once per session they had ever held.
    USER_REMOVE       =  8
    USER_STATE        =  9
    TEXT_MESSAGE      = 11
    PERMISSION_DENIED = 12
    CRYPT_SETUP       = 15
    CODEC_VERSION     = 21

    # Browser capture stopped for longer than this ends the talkspurt.
    VOICE_GAP_THRESHOLD = 200.milliseconds
    VOICE_GAP_POLL      = 100.milliseconds
    # Slip between the browser clock and the gateway clock, in 10 ms frames,
    # that forces a re-anchor. 20 frames is the same 200 ms as the gap rule.
    VOICE_RESYNC_FRAMES    = 20_i64
    VOICE_TIMELINE_REPORT  = 30.seconds

    getter users = Hash(UInt32, String).new
    getter channels = Hash(UInt32, String).new
    getter user_channels = Hash(UInt32, UInt32).new
    getter on_voice : Proc(UInt32, Bytes, UInt32?, Nil)?
    getter on_voice_end : Proc(UInt32, Nil)?
    getter on_user : Proc(UInt32, String, Nil)?
    getter on_text_message : Proc(UInt32, String, Bool, Nil)?
    getter on_state : Proc(Nil)?
    getter on_ready : Proc(Nil)?
    getter on_udp_available : Proc(Nil)?
    getter on_udp_unavailable : Proc(Nil)?
    getter on_disconnect : Proc(String, Bool, Nil)?
    getter synchronized = false
    getter udp_available = false

    def initialize(@host : String, @port : Int32, @username : String, @password : String)
      @crypt = nil.as(CryptState?)
      @alternate_crypt = nil.as(CryptState?)
      @tcp = nil.as(TCPSocket?)
      @udp = nil.as(UDPSocket?)
      @closed = false
      @udp_unavailable = false
      @session = nil.as(UInt32?)
      @voice_send_lock = Mutex.new
      @next_voice_frame = 0_u32
      # The outgoing Mumble timeline is owned by this connection and anchored to
      # the gateway's monotonic clock. See wall_clock_frame for why the browser's
      # RTP clock cannot be the anchor.
      @voice_epoch = nil.as(Time::Instant?)
      @voice_anchor_frame = 0_u32
      @voice_anchor_browser_frame = 0_u32
      @talkspurt_open = false
      @last_browser_voice_at = nil.as(Time::Instant?)
      @cue_active = false
      @voice_slip_frames = 0_i64
      @voice_slip_peak_frames = 0_i64
      @voice_resyncs = 0_u64
      @voice_terminators = 0_u64
      @voice_cue_dropped_packets = 0_u64
    end

    def on_voice(&block : UInt32, Bytes, UInt32? ->)
      @on_voice = block
    end

    def on_voice_end(&block : UInt32 ->)
      @on_voice_end = block
    end

    def on_user(&block : UInt32, String ->)
      @on_user = block
    end

    # actor session, message body, and whether it was addressed to this user
    # rather than to a channel.
    def on_text_message(&block : UInt32, String, Bool ->)
      @on_text_message = block
    end

    def on_ready(&block : ->)
      @on_ready = block
    end

    def on_state(&block : ->)
      @on_state = block
    end

    def current_channel : UInt32?
      @session.try { |session| @user_channels[session]? }
    end

    def channel_users : Hash(UInt32, String)
      channel = current_channel
      return Hash(UInt32, String).new unless channel
      @users.select { |session, _name| @user_channels[session]? == channel }
    end

    # Everyone in your channel except you: the complete set of speakers the
    # gateway bridges. You belong in the roster channel_state sends the browser,
    # but never in this set -- Mumble does not send your own voice back, so a
    # section for you could only ever be silent. Voice from anyone outside this
    # set, such as a whisper from another channel, is not bridged either; that
    # is what keeps a section's owner decided in one place.
    def speaker_sessions : Array(UInt32)
      self_session = @session
      channel_users.keys.reject { |session| session == self_session }
    end

    def switch_channel(channel : UInt32)
      raise "unknown Mumble channel #{channel}" unless @channels.has_key?(channel)
      send_packet(USER_STATE, Protobuf.field(5, channel.to_u64))
    end

    # Addressed to the channel this user is in, which is the only scope the
    # browser can send to. Mumble treats the body as HTML; the browser strips
    # it back to text on receipt, so send it as plain text here.
    def send_text_message(message : String)
      raise "not in a channel yet" unless channel = current_channel
      raise "message is empty" if message.blank?
      send_packet(TEXT_MESSAGE, Protobuf.field(3, channel.to_u64) + Protobuf.string(5, message))
    end

    def on_udp_available(&block : ->)
      @on_udp_available = block
    end

    def on_udp_unavailable(&block : ->)
      @on_udp_unavailable = block
    end

    def on_disconnect(&block : String, Bool ->)
      @on_disconnect = block
    end

    def connect
      STDERR.puts "Mumble: connecting to #{@host}:#{@port} as #{@username.inspect}"
      tcp = TCPSocket.new(@host, @port)
      @tcp = tcp
      @io = OpenSSL::SSL::Socket::Client.new(tcp, context: insecure_context)
      STDERR.puts "Mumble: TLS connected"
      # Version is itself the packet payload, not an embedded protobuf field.
      version = Protobuf.field(1, 0x010500_u64) + Protobuf.string(2, "Wumble") + Protobuf.string(3, "Crystal")
      send_packet(VERSION, version)
      authenticate
      spawn { read_loop }
      spawn { ping_loop }
      spawn { voice_gap_loop }
      spawn { voice_timeline_loop }
    end

    # Sends one browser-produced Opus packet as a MumbleUDP.Audio message.
    # frame_number is measured in Mumble's 10 ms (480 sample) units and is the
    # browser's own RTP clock, rebased by Peer#browser_frame_number.
    #
    # The browser's RTP clock stops whenever iOS takes the audio session away,
    # and resumes where it stopped rather than where wall clock reached. Sending
    # that clock straight to Mumble made the outgoing timeline lose the whole
    # interruption, and a Mumble receiver absorbs a timeline that runs behind
    # wall clock by delaying playout. Nothing repaid the loss, so every
    # interruption added its own duration to the delay the other side heard.
    # The gateway therefore owns the timeline and the browser only supplies the
    # spacing within a talkspurt.
    def send_opus(opus : Bytes, frame_number : UInt32)
      # The cue replaces browser audio rather than being inserted alongside it.
      # Blocking here instead would queue these packets behind the cue and push
      # every later packet 320 ms further behind wall clock.
      if @cue_active
        @voice_cue_dropped_packets += 1
        return
      end
      @voice_send_lock.synchronize do
        # Re-checked under the lock: the cue releases @voice_send_lock between
        # its frames, so a packet that passed the check above must not slip
        # into the middle of the cue.
        next if @cue_active
        now = Time.instant
        wall_frame = wall_clock_frame(now)
        anchored_frame = @voice_anchor_frame &+ (frame_number &- @voice_anchor_browser_frame)
        @voice_slip_frames = anchored_frame.to_i64 - wall_frame.to_i64
        # Recorded before the re-anchor below, so the peak shows how far the
        # browser clock had actually wandered rather than where it landed.
        @voice_slip_peak_frames = @voice_slip_frames.abs if @voice_slip_frames.abs > @voice_slip_peak_frames
        # Re-anchor when there is no open talkspurt, and when the browser clock
        # has slipped far enough from the gateway clock that continuing to
        # follow the browser clock would build a permanent offset. One rule
        # covers both a stopped capture and slow clock drift.
        if !@talkspurt_open || @voice_slip_frames.abs > VOICE_RESYNC_FRAMES
          close_talkspurt
          @voice_resyncs += 1
          @voice_anchor_frame = wall_frame
          @voice_anchor_browser_frame = frame_number
          @talkspurt_open = true
          outgoing_frame = wall_frame
        else
          outgoing_frame = anchored_frame
        end
        send_voice_packet(opus, outgoing_frame)
        @next_voice_frame = outgoing_frame &+ opus_duration_frames(opus)
        @last_browser_voice_at = now
      end
    end

    # The cue is transmitted as ordinary Opus voice so every Mumble client
    # hears the same state transition. Muting uses high-to-low; unmuting uses
    # low-to-high. It does not alter Mumble self-mute state.
    #
    # Cue frames are numbered from the gateway clock, exactly like browser
    # frames, so the 320 ms the cue occupies in the outgoing stream is the same
    # 320 ms it occupies in wall clock. Browser packets arriving during the cue
    # are dropped by send_opus.
    def play_mic_state_cue(muted : Bool)
      frequencies = muted ? {880.0, 440.0} : {440.0, 880.0}
      @cue_active = true
      begin
        @voice_send_lock.synchronize { close_talkspurt }
        OpusTone.each_two_tone(frequencies[0], frequencies[1]) do |opus|
          @voice_send_lock.synchronize do
            frame = wall_clock_frame(Time.instant)
            send_voice_packet(opus, frame)
            @next_voice_frame = frame &+ 2_u32
          end
          sleep 20.milliseconds
        end
        @voice_send_lock.synchronize do
          send_voice_terminator(wall_clock_frame(Time.instant))
          @voice_terminators += 1
        end
      ensure
        @cue_active = false
      end
    end

    # Frame N of the outgoing stream is the frame that plays N * 10 ms after
    # the first outgoing packet of this Mumble session. Wall clock is the only
    # clock that keeps running while the browser's capture is interrupted, so
    # wall clock is what the timeline is anchored to.
    private def wall_clock_frame(now : Time::Instant) : UInt32
      epoch = @voice_epoch ||= now
      ((now - epoch).total_milliseconds / 10.0).to_i64.to_u32
    end

    # A Mumble receiver resets its jitter buffer when a talkspurt ends, so the
    # terminator is what lets the other side drain any delay it has built up.
    # Must be called with @voice_send_lock held.
    private def close_talkspurt : Nil
      return unless @talkspurt_open
      @talkspurt_open = false
      send_voice_terminator(@next_voice_frame)
      @voice_terminators += 1
    end

    # End the talkspurt as soon as the browser stops sending rather than when it
    # resumes. A Mumble receiver that is told the talkspurt ended stops waiting
    # for the next frame number in sequence.
    private def voice_gap_loop
      until @closed
        sleep VOICE_GAP_POLL
        break if @closed
        @voice_send_lock.synchronize do
          last = @last_browser_voice_at
          close_talkspurt if @talkspurt_open && last && Time.instant - last > VOICE_GAP_THRESHOLD
        end
      end
    end

    # The quantity this reports is the one that used to grow without bound:
    # how far the outgoing frame numbering has slipped from wall clock. It is
    # logged unconditionally rather than under WUMBLE_DEBUG because a slip that
    # only appears during a real conversation is the whole failure mode.
    #
    # slip_ms is the last packet's slip; peak_slip_ms is the worst slip since
    # the previous report. Without peak_slip_ms a drift building between two
    # re-anchors is invisible until the drift trips VOICE_RESYNC_FRAMES and
    # shows up only as another increment of resyncs.
    private def voice_timeline_loop
      until @closed
        sleep VOICE_TIMELINE_REPORT
        break if @closed
        next unless @voice_epoch
        peak = @voice_slip_peak_frames
        @voice_slip_peak_frames = 0_i64
        STDERR.puts "Mumble voice timeline: slip_ms=#{@voice_slip_frames * 10} peak_slip_ms=#{peak * 10} resyncs=#{@voice_resyncs} terminators=#{@voice_terminators} cue_dropped_packets=#{@voice_cue_dropped_packets}"
      end
    end

    private def send_voice_packet(opus : Bytes, frame_number : UInt32)
      return unless crypt = @crypt
      return unless udp = @udp
      payload = Bytes[0_u8] + Protobuf.field(4, frame_number.to_u64) + Protobuf.bytes(5, opus)
      datagram = crypt.encrypt(payload)
      udp.send(datagram)
      # UDPSocket#send returning means the kernel accepted the datagram. This
      # is intentionally per-packet under debug so gateway-to-server timing
      # can be compared directly with a UDP capture on the Mumble server.
      if ENV["WUMBLE_DEBUG"]? == "1"
        STDERR.puts "Mumble UDP voice queued at=#{Time.utc.to_unix_ms} frame=#{frame_number} opus_bytes=#{opus.size} datagram_bytes=#{datagram.size}"
      end
    rescue ex
      STDERR.puts "Mumble UDP voice send failed: #{ex.message || ex.class.name}" unless @closed
    end

    private def send_voice_terminator(frame_number : UInt32)
      return unless crypt = @crypt
      return unless udp = @udp
      payload = Bytes[0_u8] + Protobuf.field(4, frame_number.to_u64) + Protobuf.field(16, 1_u64)
      udp.send(crypt.encrypt(payload))
    rescue ex
      STDERR.puts "Mumble UDP voice terminator send failed: #{ex.message || ex.class.name}" unless @closed
    end

    private def opus_duration_frames(opus : Bytes) : UInt32
      return 2_u32 if opus.empty?
      config = opus[0] >> 3
      samples_per_frame = if config < 12
                            480_u32 << (config & 0x03)
                          elsif config < 16
                            480_u32 << (config & 0x01)
                          else
                            120_u32 << (config & 0x03)
                          end
      frame_count = case opus[0] & 0x03
                    when 0    then 1_u32
                    when 1, 2 then 2_u32
                    else           opus.size > 1 ? (opus[1] & 0x3f).to_u32 : 1_u32
                    end
      (samples_per_frame * frame_count) // 480_u32
    end

    def close
      return if @closed
      @closed = true
      # Closing OpenSSL's SSL object while another Crystal fiber is blocked in
      # SSL_read can crash OpenSSL. Closing the underlying TCP socket wakes the
      # reader without concurrent SSL_shutdown calls.
      @tcp.try &.close
      @udp.try &.close
    end

    private def insecure_context
      context = OpenSSL::SSL::Context::Client.new
      # Mumble deployments commonly use an internal CA. The administrator can
      # terminate this connection through a trusted local proxy when pinning is required.
      context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      context
    end

    private def authenticate
      packet = Protobuf.string(1, @username) + Protobuf.string(2, @password)
      packet += Protobuf.field(5, 1_u64) # Opus
      send_packet(AUTHENTICATE, packet)
    end

    private def ping_loop
      until @closed
        sleep 5.seconds
        break if @closed
        # Murmur drops idle TCP control connections. Its Ping message uses a
        # millisecond timestamp in protobuf field 1.
        send_packet(PING, Protobuf.field(1, Time.utc.to_unix_ms.to_u64))
      end
    rescue ex
      STDERR.puts "Mumble ping failed: #{ex.message || ex.class.name}" unless @closed
    end

    private def send_packet(type : Int32, payload : Bytes)
      io = @io.not_nil!
      header = Bytes.new(6)
      IO::ByteFormat::BigEndian.encode(type.to_u16, header[0, 2])
      IO::ByteFormat::BigEndian.encode(payload.size.to_u32, header[2, 4])
      STDERR.puts "Mumble: sent #{packet_name(type)} (#{payload.size} bytes)"
      io.write(header)
      io.write(payload)
      io.flush
    end

    private def read_loop
      io = @io.not_nil!
      loop do
        header = Bytes.new(6)
        io.read_fully(header)
        type = IO::ByteFormat::BigEndian.decode(UInt16, header[0, 2]).to_i
        wire_size = IO::ByteFormat::BigEndian.decode(UInt32, header[2, 4])
        raise "Mumble control packet exceeds 8 MiB" if wire_size > 8_388_608_u32
        payload = Bytes.new(wire_size.to_i)
        io.read_fully(payload)
        STDERR.puts "Mumble: received #{packet_name(type)} (#{payload.size} bytes)" unless type == UDPTUNNEL
        if ENV["WUMBLE_DEBUG"]? == "1"
          STDERR.puts "#{bytes_repr(payload)}"
        end
        case type
        when REJECT        then reject(payload)
        when SERVER_SYNC   then synchronize(payload)
        when CHANNEL_STATE then update_channel(payload)
        when USER_STATE    then update_user(payload)
        when USER_REMOVE   then user_removed(payload)
        when TEXT_MESSAGE  then text_message(payload)
        when CRYPT_SETUP   then configure_crypt(payload)
          # Native encrypted UDP is required for voice. Do not feed the TCP
          # fallback into WebRTC, where its head-of-line blocking adds latency.
        when UDPTUNNEL
          # Native UDP voice is used instead of the TCP fallback.
        end
      end
    rescue ex
      was_closed = @closed
      @closed = true
      reason = ex.message || ex.class.name
      STDERR.puts "Mumble connection closed: #{reason}"
      STDERR.puts ex.backtrace.join('\n') if ENV["WUMBLE_DEBUG"]? == "1"
      @on_disconnect.try &.call(reason, true) unless was_closed
    end

    private def synchronize(payload : Bytes)
      Protobuf.fields(payload) do |number, wire, value|
        next unless number == 1 && wire == 0
        session, _offset = Protobuf.read_varint(value, 0)
        @session = session.to_u32 if session <= UInt32::MAX
      end
      STDERR.puts "Mumble: authenticated and synchronized"
      log_server_sync_snapshot
      @synchronized = true
      @on_ready.try &.call
      @on_state.try &.call
    end

    # ServerSync is the one small, non-batched diagnostic: it records exactly
    # which same-channel speakers are eligible to be bridged after reconnect.
    # Per-voice diagnostics are batched by Peer instead.
    private def log_server_sync_snapshot
      channel = current_channel
      channel_label = if channel
                        "#{channel}(#{@channels[channel]? || "unknown"})"
                      else
                        "none"
                      end
      members = channel_users.map { |member_session, name| "#{member_session}:#{name}" }.join(", ")
      STDERR.puts "Mumble: ServerSync snapshot self_session=#{@session || "unknown"} channel=#{channel_label} members=[#{members}]"
    end

    # TextMessage carries repeated session/channel_id/tree_id destinations. A
    # message with no channel and no tree destination was addressed to this
    # user directly, which is the only distinction the browser draws.
    private def text_message(payload : Bytes)
      actor = nil.as(UInt32?)
      body = nil.as(String?)
      addressed_to_channel = false
      Protobuf.fields(payload) do |number, wire, value|
        case number
        when 1       then actor = Protobuf.read_varint(value, 0)[0].to_u32 if wire == 0
        when 3, 4    then addressed_to_channel = true if wire == 0
        when 5       then body = String.new(value) if wire == 2
        end
      end
      return unless message = body
      @on_text_message.try &.call(actor || 0_u32, message, !addressed_to_channel)
    end

    private def user_removed(payload : Bytes)
      removed_session = nil.as(UInt32?)
      reason = nil.as(String?)
      Protobuf.fields(payload) do |number, wire, value|
        case number
        when 1 then removed_session = Protobuf.read_varint(value, 0)[0].to_u32 if wire == 0
        when 3 then reason = String.new(value) if wire == 2
        end
      end
      if removed_session
        @users.delete(removed_session.not_nil!)
        @user_channels.delete(removed_session.not_nil!)
        @on_state.try &.call
      end
      return unless removed_session && removed_session == @session
      close
      message = "Mumble session removed#{reason ? ": #{reason}" : ""}"
      @on_disconnect.try &.call(message, false)
    end

    private def reject(payload : Bytes)
      reason = nil
      Protobuf.fields(payload) do |number, wire, value|
        reason = String.new(value) if number == 2 && wire == 2
      end
      raise "Mumble rejected authentication#{reason ? ": #{reason}" : ""}"
    end

    private def configure_crypt(payload : Bytes)
      key = nil.as(Bytes?)
      client_nonce = nil.as(Bytes?)
      server_nonce = nil.as(Bytes?)
      Protobuf.fields(payload) do |number, wire, value|
        next unless wire == 2
        case number
        when 1 then key = value
        when 2 then client_nonce = value
        when 3 then server_nonce = value
        end
      end
      return STDERR.puts "Mumble: incomplete CryptSetup; waiting for full key material" unless key && client_nonce && server_nonce
      @crypt = CryptState.new(key.not_nil!, client_nonce.not_nil!, server_nonce.not_nil!)
      # Some Murmur versions label nonce directions from the server's point of
      # view. Keep a tag-authenticated alternate state for that wire variant.
      @alternate_crypt = CryptState.new(key.not_nil!, server_nonce.not_nil!, client_nonce.not_nil!)
      STDERR.puts "Mumble: CryptSetup complete; starting native UDP voice"
      start_udp
    end

    private def start_udp
      return if @udp || @closed
      udp = UDPSocket.new
      udp.connect(@host, @port)
      @udp = udp
      # The call form, not `spawn { ... }`: a block closes over the caller's
      # locals and reads them when the fiber runs.
      spawn udp_read_loop(udp)
      spawn udp_ping_loop(udp)
      spawn do
        sleep 3.seconds
        unless @closed || @udp_available
          @udp_unavailable = true
          STDERR.puts "Mumble: native UDP is unavailable; TCP UDPTunnel voice will not be used"
          @on_udp_unavailable.try &.call
        end
      end
    rescue ex
      @udp_unavailable = true
      STDERR.puts "Mumble: could not start native UDP: #{ex.message || ex.class.name}"
      @on_udp_unavailable.try &.call
    end

    private def udp_ping_loop(udp : UDPSocket)
      until @closed
        # Mumble 1.5 native UDP envelopes start with the Ping message type.
        # A ping proves that the server can route encrypted UDP back to us.
        plaintext = Bytes[1_u8] + Protobuf.field(1, Time.utc.to_unix_ms.to_u64)
        # CryptState advances its nonce on every packet. Serialize pings with
        # browser and generated voice so two fibers cannot reuse/corrupt it.
        @voice_send_lock.synchronize { udp.send(@crypt.not_nil!.encrypt(plaintext)) }
        sleep 1.second
      end
    rescue ex
      STDERR.puts "Mumble UDP send failed: #{ex.message || ex.class.name}" unless @closed
    end

    private def udp_read_loop(udp : UDPSocket)
      buffer = Bytes.new(65_535)
      until @closed
        size, _source = udp.receive(buffer)
        # Decode and forwarding failures are per-packet. Letting one escape the
        # loop would end this fiber and silence every speaker at once, so only
        # a socket error (raised by receive above) may break out.
        begin
          plaintext = @crypt.try &.decrypt(buffer[0, size])
          next unless plaintext
          native_udp_received
          receive_native_udp(plaintext)
        rescue ex
          STDERR.puts "Mumble UDP voice packet dropped: #{ex.message || ex.class.name}" unless @closed
          STDERR.puts ex.backtrace.join('\n') if ENV["WUMBLE_DEBUG"]? == "1"
        end
      end
    rescue ex
      STDERR.puts "Mumble UDP receive failed: #{ex.message || ex.class.name}" unless @closed
    end

    private def native_udp_received
      return if @udp_available
      @udp_available = true
      STDERR.puts "Mumble: native UDP is available"
      @on_udp_available.try &.call
    end

    private def receive_native_udp(packet : Bytes)
      return if packet.empty?
      # Mumble 1.5 uses a one-byte UDP message type followed by a protobuf
      # MumbleUDP.Audio payload. Ping responses require no further handling.
      receive_protobuf_audio(packet[1..]) if packet[0] == 0_u8
    end

    private def update_channel(payload : Bytes)
      channel = nil.as(UInt32?)
      name = nil.as(String?)
      Protobuf.fields(payload) do |number, wire, value|
        case number
        when 1 then channel = Protobuf.read_varint(value, 0)[0].to_u32 if wire == 0
        when 3 then name = String.new(value) if wire == 2
        end
      end
      @channels[channel.not_nil!] = name.not_nil! if channel && name
      @on_state.try &.call
    end

    private def update_user(payload : Bytes)
      session = nil.as(UInt32?)
      name = nil.as(String?)
      channel = nil.as(UInt32?)
      Protobuf.fields(payload) do |number, wire, value|
        case number
        when 1 then session = Protobuf.read_varint(value, 0)[0].to_u32 if wire == 0
        when 3 then name = String.new(value) if wire == 2
        when 5 then channel = Protobuf.read_varint(value, 0)[0].to_u32 if wire == 0
        end
      end
      if session
        @users[session.not_nil!] = name.not_nil! if name
        if channel
          @user_channels[session.not_nil!] = channel.not_nil!
        elsif !@user_channels.has_key?(session.not_nil!)
          # Murmur omits channel_id for Root (channel 0) users in its
          # initial UserState snapshot. Later partial updates likewise omit
          # it, but must retain the channel already recorded for that user.
          @user_channels[session.not_nil!] = 0_u32
        end
        @on_user.try &.call(session.not_nil!, name.not_nil!) if name
        @on_state.try &.call
      end
    end

    private def packet_name(type : Int32)
      case type
      when VERSION       then "Version"
      when UDPTUNNEL     then "UDPTunnel"
      when AUTHENTICATE  then "Authenticate"
      when PING          then "Ping"
      when REJECT        then "Reject"
      when SERVER_SYNC   then "ServerSync"
      when CHANNEL_STATE then "ChannelState"
      when USER_STATE    then "UserState"
      when USER_REMOVE   then "UserRemove"
      when TEXT_MESSAGE  then "TextMessage"
      when PERMISSION_DENIED then "PermissionDenied"
      when CRYPT_SETUP   then "CryptSetup"
      when CODEC_VERSION then "CodecVersion"
      when 24            then "ServerConfig"
      else                    "control type #{type}"
      end
    end

    private def receive_tunnel(packet : Bytes)
      # Mumble 1.5 uses a one-byte UDP message type followed by a protobuf
      # MumbleUDP.Audio message. It is plaintext inside the TCP tunnel.
      return receive_protobuf_audio(packet[1..]) if !packet.empty? && packet[0] == 0_u8

      # Older servers use the legacy UDPVoice packet. Some deployments tunnel
      # an encrypted datagram instead, so only decrypt when it is not legacy Opus.
      unless !packet.empty? && (packet[0] >> 5) == 4
        plaintext = @crypt.try &.decrypt(packet)
        if !plaintext && (alternate = @alternate_crypt.try &.decrypt(packet))
          STDERR.puts "Mumble: decrypted UDPTunnel using alternate nonce direction"
          plaintext = alternate
        end
        unless plaintext
          STDERR.puts "Mumble: discarded UDPTunnel packet (not plaintext Opus and crypt authentication failed)"
          return
        end
        packet = plaintext
      end
      return if packet.empty? || (packet[0] >> 5) != 4 # UDPVoiceOpus
      offset = 1
      session, offset = Protobuf.read_varint(packet, offset)
      return if session > UInt32::MAX
      _sequence, offset = Protobuf.read_varint(packet, offset)
      size, offset = Protobuf.read_varint(packet, offset)
      terminator = size & 0x2000_u64 != 0
      size &= 0x1fff_u64 # Mumble's high bit is the end-of-transmission marker.
      return if offset > packet.size || size > (packet.size - offset).to_u64
      finish = offset + size.to_i
      opus = packet[offset...finish]
      forward_opus(session.to_u32, opus, terminator, nil)
    end

    private def receive_protobuf_audio(payload : Bytes)
      session = nil.as(UInt32?)
      frame_number = nil.as(UInt32?)
      opus = nil.as(Bytes?)
      terminator = false
      Protobuf.fields(payload) do |number, wire, value|
        case number
        when 3
          sender, _offset = Protobuf.read_varint(value, 0)
          session = sender.to_u32 if wire == 0 && sender <= UInt32::MAX
        when 4
          frame, _offset = Protobuf.read_varint(value, 0)
          frame_number = frame.to_u32 if wire == 0 && frame <= UInt32::MAX
        when 5
          opus = value if wire == 2
        when 16
          terminator = Protobuf.read_varint(value, 0)[0] != 0 if wire == 0
        end
      end
      return unless session
      forward_opus(session.not_nil!, opus.not_nil!, terminator, frame_number) if opus
      @on_voice_end.try &.call(session.not_nil!) if terminator && !opus
    end

    private def forward_opus(session : UInt32, opus : Bytes, terminator : Bool, frame_number : UInt32?)
      @on_voice.try &.call(session, opus, frame_number)
      @on_voice_end.try &.call(session) if terminator
    end
  end
end
