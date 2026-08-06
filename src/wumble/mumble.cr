require "socket"
require "openssl"
require "./protobuf"
require "./crypt_state"

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
    USER_STATE    =  9
    CRYPT_SETUP   = 15
    CODEC_VERSION = 21

    getter users = Hash(UInt32, String).new
    getter on_voice : Proc(UInt32, Bytes, UInt32?, Nil)?
    getter on_voice_end : Proc(UInt32, Nil)?
    getter on_user : Proc(UInt32, String, Nil)?
    getter on_ready : Proc(Nil)?
    getter on_udp_available : Proc(Nil)?
    getter on_udp_unavailable : Proc(Nil)?
    getter on_disconnect : Proc(String, Nil)?
    getter synchronized = false
    getter udp_available = false

    def initialize(@host : String, @port : Int32, @username : String, @password : String)
      @crypt = nil.as(CryptState?)
      @alternate_crypt = nil.as(CryptState?)
      @tcp = nil.as(TCPSocket?)
      @udp = nil.as(UDPSocket?)
      @closed = false
      @udp_unavailable = false
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

    def on_ready(&block : ->)
      @on_ready = block
    end

    def on_udp_available(&block : ->)
      @on_udp_available = block
    end

    def on_udp_unavailable(&block : ->)
      @on_udp_unavailable = block
    end

    def on_disconnect(&block : String ->)
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
    end

    # Sends one browser-produced Opus packet as a MumbleUDP.Audio message.
    # frame_number is measured in Mumble's 10 ms (480 sample) units.
    def send_opus(opus : Bytes, frame_number : UInt32)
      return unless crypt = @crypt
      return unless udp = @udp
      payload = Bytes[0_u8] + Protobuf.field(4, frame_number.to_u64) + Protobuf.bytes(5, opus)
      udp.send(crypt.encrypt(payload))
    rescue ex
      STDERR.puts "Mumble UDP voice send failed: #{ex.message || ex.class.name}" unless @closed
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
        case type
        when REJECT then reject(payload)
        when SERVER_SYNC
          STDERR.puts "Mumble: authenticated and synchronized"
          @synchronized = true
          @on_ready.try &.call
        when USER_STATE  then update_user(payload)
        when CRYPT_SETUP then configure_crypt(payload)
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
      @on_disconnect.try &.call(reason) unless was_closed
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
      spawn { udp_read_loop(udp) }
      spawn { udp_ping_loop(udp) }
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
        udp.send(@crypt.not_nil!.encrypt(plaintext))
        sleep 1.second
      end
    rescue ex
      STDERR.puts "Mumble UDP send failed: #{ex.message || ex.class.name}" unless @closed
    end

    private def udp_read_loop(udp : UDPSocket)
      buffer = Bytes.new(65_535)
      until @closed
        size, _source = udp.receive(buffer)
        plaintext = @crypt.try &.decrypt(buffer[0, size])
        next unless plaintext
        native_udp_received
        receive_native_udp(plaintext)
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

    private def update_user(payload : Bytes)
      session = nil
      name = nil
      Protobuf.fields(payload) do |number, wire, value|
        case number
        when 1 then session = Protobuf.read_varint(value, 0)[0].to_u32 if wire == 0
        when 3 then name = String.new(value) if wire == 2
        end
      end
      if session && name
        @users[session.not_nil!] = name.not_nil!
        @on_user.try &.call(session.not_nil!, name.not_nil!)
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
      when USER_STATE    then "UserState"
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
