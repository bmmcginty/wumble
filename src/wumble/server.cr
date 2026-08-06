require "http/server"
require "http/web_socket"
require "json"
require "uri"
require "./datachannel"
require "./mumble"

module Wumble
  struct ConnectRequest
    include JSON::Serializable
    getter server : String
    getter port : Int32
    getter username : String
    getter password : String
  end

  class Gateway
    def initialize(@web_root : String)
    end

    def run(bind : String, port : Int32)
      websocket = HTTP::WebSocketHandler.new { |socket, context| puts context.request.path; context.request.path == "/ws" ? handle_socket(socket) : socket.close }
      HTTP::Server.new([websocket]) { |context| serve(context); nil }.listen(bind, port)
    end

    private def handle_socket(socket : HTTP::WebSocket)
      STDERR.puts "WebRTC signalling: WebSocket opened"
      peer = nil.as(Peer?)
      mumble = nil.as(MumbleConnection?)
      socket.on_message do |message|
        begin
          data = JSON.parse(message)
          message_type = data["type"].as_s
          STDERR.puts "WebRTC signalling: received #{message_type}"
          case message_type
          when "log"
            event = data["event"]?.try(&.as_s) || "unknown client event"
            details = data["details"]?.try(&.to_json) || "{}"
            STDERR.puts "WebRTC client: #{event} #{details}"
          when "ping"
            socket.send({type: "pong"}.to_json)
          when "connect"
            raise "already connected" if peer
            request = ConnectRequest.from_json(data["options"].to_json)
            validate(request)
            peer = Peer.new
            mumble = MumbleConnection.new(request.server, request.port, request.username, request.password)
            peer.not_nil!.on_opus { |opus, frame_number| mumble.not_nil!.send_opus(opus, frame_number) }
            mumble.not_nil!.on_user do |speaker, _name|
              socket.send({type: "renegotiate"}.to_json) if peer.not_nil!.prepare_speaker(speaker)
            end
            mumble.not_nil!.on_voice { |speaker, opus, frame_number| peer.not_nil!.send_opus(speaker, opus, frame_number) }
            mumble.not_nil!.on_voice_end { |speaker| peer.not_nil!.end_voice(speaker) }
            # Wait for both synchronization and a working native UDP path.
            # TCP UDPTunnel voice is deliberately not a fallback because its
            # head-of-line blocking causes the latency this gateway avoids.
            mumble.not_nil!.on_ready do
              if mumble.not_nil!.udp_available
                socket.send({type: "connected", speakers: mumble.not_nil!.users.size}.to_json)
              end
            end
            mumble.not_nil!.on_udp_available do
              if mumble.not_nil!.synchronized
                socket.send({type: "connected", speakers: mumble.not_nil!.users.size}.to_json)
              end
            end
            mumble.not_nil!.on_udp_unavailable do
              socket.send({type: "udp_unavailable", message: "Native UDP to the Mumble server is unavailable. Check UDP port #{request.port}."}.to_json)
            end
            mumble.not_nil!.connect
          when "offer"
            raise "connect before sending an offer" unless peer
            current_peer = peer.not_nil!
            needs_renegotiation = current_peer.accept_offer(data["sdp"].as_s)
            STDERR.puts "WebRTC signalling: accepted browser offer; waiting for local answer"
            spawn do
              begin
                # Give ICE gathering time to add host candidates to the SDP.
                sleep 1.second
                answer = current_peer.local_description || raise "libdatachannel did not produce an answer"
                speakers = current_peer.speaker_mids.map do |session, mid|
                  {session: session, mid: mid, name: mumble.not_nil!.users[session]? || "Session #{session}"}
                end
                socket.send({type: "answer", sdp: answer, description_type: "answer", speakers: speakers}.to_json)
                socket.send({type: "renegotiate"}.to_json) if needs_renegotiation
                STDERR.puts "WebRTC signalling: sent answer (#{answer.bytesize} bytes)"
              rescue ex
                STDERR.puts "WebRTC answer error: #{ex.message || ex.class.name}"
                STDERR.puts ex.backtrace.join('\n') if ENV["WUMBLE_DEBUG"]? == "1"
                socket.send({type: "error", message: ex.message || "failed to create WebRTC answer"}.to_json)
              end
            end
          when "candidate"
            peer.try &.add_candidate(data["candidate"].as_s, data["mid"]?.try(&.as_s) || "0")
          else
            raise "unknown signalling message"
          end
        rescue ex
          STDERR.puts "WebRTC signalling error: #{ex.message || ex.class.name}"
          STDERR.puts ex.backtrace.join('\n') if ENV["WUMBLE_DEBUG"]? == "1"
          socket.send({type: "error", message: ex.message || "connection failed"}.to_json)
        end
      end
      socket.on_close do |code, reason|
        STDERR.puts "WebRTC signalling: WebSocket closed (#{code}: #{reason.inspect}); closing Mumble connection"
        mumble.try &.close
        peer.try &.close
      end
    end

    private def validate(request : ConnectRequest)
      raise "server is required" if request.server.empty?
      raise "port must be between 1 and 65535" unless 1..65_535 === request.port
      raise "username is required" if request.username.empty?
      raise "server must be a hostname or IP address" unless request.server =~ /\A[a-zA-Z0-9.:-]+\z/
    end

    private def serve(context : HTTP::Server::Context)
      path = context.request.path
      path = "/index.html" if path == "/"
      return not_found(context) if path.includes?("..")
      file = File.join(@web_root, path.lstrip('/'))
      return not_found(context) unless File.file?(file)
      context.response.content_type = content_type(file)
      File.open(file) { |io| IO.copy(io, context.response) }
    end

    private def not_found(context)
      context.response.status_code = 404
      context.response.print "not found\n"
    end

    private def content_type(file)
      case File.extname(file)
      when ".html" then "text/html; charset=utf-8"
      when ".js"   then "application/javascript; charset=utf-8"
      when ".css"  then "text/css; charset=utf-8"
      else              "application/octet-stream"
      end
    end
  end
end
