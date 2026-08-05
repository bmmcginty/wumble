require "socket"
require "openssl"
require "./protobuf"

module Wumble
  # Mumble's TCP control protocol. Voice is intentionally accepted separately by
  # UdpVoice; TCP packets are not mixed or decoded by this class.
  class MumbleConnection
    VERSION       =  0
    UDPTUNNEL     =  1
    AUTHENTICATE  =  2
    PING          =  3
    SERVER_SYNC   =  5
    USER_STATE    =  9
    CODEC_VERSION = 21

    getter users = Hash(UInt32, String).new
    getter on_voice : Proc(UInt32, Bytes, Nil)?

    def initialize(@host : String, @port : Int32, @username : String, @password : String)
    end

    def on_voice(&block : UInt32, Bytes ->)
      @on_voice = block
    end

    def connect
      tcp = TCPSocket.new(@host, @port)
      @io = OpenSSL::SSL::Socket::Client.new(tcp, context: insecure_context)
      version = Protobuf.field(1, 0x010500_u64) + Protobuf.string(2, "Wumble") + Protobuf.string(3, "Crystal")
      send_packet(VERSION, Protobuf.bytes(1, version))
      authenticate
      spawn { read_loop }
    end

    def close
      @io.try &.close
    end

    private def insecure_context
      context = OpenSSL::SSL::Context::Client.new
      # Mumble deployments commonly use an internal CA. The administrator can
      # terminate this connection through a trusted local proxy when pinning is required.
      context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      context
    end

    private def authenticate
      packet = Protobuf.string(1, @username) + Protobuf.string(6, @password)
      packet += Protobuf.field(5, 1_u64) # Opus
      send_packet(AUTHENTICATE, packet)
    end

    private def send_packet(type : Int32, payload : Bytes)
      io = @io.not_nil!
      header = Bytes.new(6)
      IO::ByteFormat::BigEndian.encode(type.to_u16, header[0, 2])
      IO::ByteFormat::BigEndian.encode(payload.size.to_u32, header[2, 4])
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
        case type
        when USER_STATE then update_user(payload)
        when UDPTUNNEL  then receive_tunnel(payload)
        end
      end
    rescue ex
      STDERR.puts "Mumble connection closed: #{ex.message}"
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
      @users[session.not_nil!] = name.not_nil! if session && name
    end

    private def receive_tunnel(packet : Bytes)
      # UDP tunnel payloads have the normal Mumble voice packet layout. The
      # packet contains one Opus payload; preserve it rather than decoding/mixing.
      return if packet.empty? || (packet[0] >> 5) != 4 # UDPVoiceOpus
      offset = 1
      session, offset = Protobuf.read_varint(packet, offset)
      return if session > UInt32::MAX
      _sequence, offset = Protobuf.read_varint(packet, offset)
      size, offset = Protobuf.read_varint(packet, offset)
      size &= 0x1fff_u64 # Mumble's high bit is the end-of-transmission marker.
      return if offset > packet.size || size > (packet.size - offset).to_u64
      finish = offset + size.to_i
      @on_voice.try &.call(session.to_u32, packet[offset...finish])
    end
  end
end
