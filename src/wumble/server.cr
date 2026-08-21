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
      active_channel = nil.as(UInt32?)
      mic_state_events = Channel(Bool).new(8)
      # Signalling is now emitted from the Mumble TCP fiber (on_state), the
      # Mumble UDP voice fiber (a speaker heard before its UserState) and the
      # answer fiber. Serialize the frames so they cannot interleave, and
      # swallow send errors: an exception raised inside a Mumble callback
      # unwinds that connection's read loop and is reported as a Mumble
      # disconnect.
      send_lock = Mutex.new
      send_signal = ->(payload : String) do
        send_lock.synchronize do
          socket.send(payload)
        rescue ex
          STDERR.puts "WebRTC signalling: send failed: #{ex.message || ex.class.name}"
        end
      end
      # Every Peer, including the one rebuilt on a channel switch, needs the
      # same wiring. on_renegotiation_needed is what breaks the deadlock: a
      # speaker first heard on the voice fiber must still get the browser to
      # offer an audio section for it.
      wire_peer = ->(new_peer : Peer) do
        new_peer.on_opus { |opus, frame_number| mumble.not_nil!.send_opus(opus, frame_number) }
        new_peer.on_renegotiation_needed do
          STDERR.puts "WebRTC signalling: requesting renegotiation for new speaker"
          # This can fire from the Mumble UDP voice fiber. Hand the send to a
          # new fiber so a slow or blocked WebSocket cannot stall voice
          # forwarding for every speaker; the request is idempotent, so its
          # ordering against other frames does not matter.
          spawn { send_signal.call({type: "renegotiate"}.to_json) }
        end
      end
      # Serialize cues so quick iOS mute/unmute events cannot overlap. These
      # events do not alter Mumble self-mute state or browser-audio forwarding.
      spawn do
        last_muted = false
        loop do
          muted = mic_state_events.receive
          next if muted == last_muted
          last_muted = muted
          begin
            mumble.try &.play_mic_state_cue(muted)
          rescue ex
            STDERR.puts "Mumble mic state cue failed: #{ex.message || ex.class.name}"
            STDERR.puts ex.backtrace.join('\n') if ENV["WUMBLE_DEBUG"]? == "1"
          end
        end
      rescue Channel::ClosedError
      end
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
            send_signal.call({type: "pong"}.to_json)
          when "microphone_state"
            mic_state_events.send(data["muted"].as_bool)
          when "connect"
            raise "already connected" if peer
            request = ConnectRequest.from_json(data["options"].to_json)
            validate(request)
            peer = Peer.new
            mumble = MumbleConnection.new(request.server, request.port, request.username, request.password)
            mumble.not_nil!.on_disconnect do |reason, reconnect|
              type = reconnect && !reason.starts_with?("Mumble rejected authentication") ? "mumble_disconnected" : "error"
              send_signal.call({type: type, message: reason}.to_json)
            end
            wire_peer.call(peer.not_nil!)
            mumble.not_nil!.on_state do
              connection = mumble.not_nil!
              channel = connection.current_channel
              send_signal.call(channel_state(connection).to_json)
              switched = !!(active_channel && channel && active_channel != channel)
              if switched
                peer.try &.close
                peer = Peer.new
                wire_peer.call(peer.not_nil!)
              end
              # A UserState update can contain only a channel change and no
              # name. Reconcile the complete channel membership here rather
              # than relying on the name-bearing on_user callback, so an
              # already-connected browser is offered a track for every
              # newcomer. On a fresh Peer these only populate the roster: no
              # offer has been accepted yet, so restart_webrtc drives that.
              connection.channel_users.each_key { |speaker| peer.not_nil!.request_speaker(speaker) }
              send_signal.call({type: "restart_webrtc", speakers: connection.channel_users.size}.to_json) if switched
              active_channel = channel if channel
            end
            mumble.not_nil!.on_voice { |speaker, opus, frame_number| peer.not_nil!.send_opus(speaker, opus, frame_number) }
            mumble.not_nil!.on_voice_end { |speaker| peer.not_nil!.end_voice(speaker) }
            # Wait for both synchronization and a working native UDP path.
            # TCP UDPTunnel voice is deliberately not a fallback because its
            # head-of-line blocking causes the latency this gateway avoids.
            mumble.not_nil!.on_ready do
              connection = mumble.not_nil!
              connection.channel_users.each_key { |speaker| peer.not_nil!.request_speaker(speaker) }
              if connection.udp_available
                send_signal.call({type: "connected", speakers: connection.channel_users.size}.to_json)
              end
            end
            mumble.not_nil!.on_udp_available do
              connection = mumble.not_nil!
              connection.channel_users.each_key { |speaker| peer.not_nil!.request_speaker(speaker) }
              if connection.synchronized
                send_signal.call({type: "connected", speakers: connection.channel_users.size}.to_json)
              end
            end
            mumble.not_nil!.on_udp_unavailable do
              send_signal.call({type: "udp_unavailable", message: "Native UDP to the Mumble server is unavailable. Check UDP port #{request.port}."}.to_json)
            end
            mumble.not_nil!.connect
          when "switch_channel"
            raise "connect before switching channels" unless mumble
            mumble.not_nil!.switch_channel(data["channel"].as_i.to_u32)
          when "offer"
            raise "connect before sending an offer" unless peer
            current_peer = peer.not_nil!
            needs_renegotiation = current_peer.accept_offer(data["sdp"].as_s)
            STDERR.puts "WebRTC signalling: accepted browser offer; waiting for local answer"
            spawn do
              begin
                # libdatachannel does not expose a Crystal-safe local-candidate
                # callback. Poll only until its host candidate reaches the SDP,
                # instead of imposing a one-second delay on every connection.
                deadline = Time.instant + 250.milliseconds
                answer = nil.as(String?)
                loop do
                  if local_description = current_peer.local_description
                    answer = local_description
                    break if local_description.includes?("a=candidate:")
                  end
                  break if Time.instant >= deadline
                  sleep 10.milliseconds
                end
                answer ||= raise "libdatachannel did not produce an answer"
                STDERR.puts "WebRTC signalling: local ICE candidate was not ready after 250 ms; sending available answer" unless answer.includes?("a=candidate:")
                # A channel switch replaces peer while this fiber may still be
                # waiting for ICE. Never send the old peer's answer after a
                # restart_webrtc: the browser would apply it to its replacement
                # PeerConnection and reject or corrupt the negotiation.
                if peer == current_peer
                  speakers = current_peer.speaker_mids.map do |session, mid|
                    {session: session, mid: mid, name: mumble.not_nil!.users[session]? || "Session #{session}"}
                  end
                  send_signal.call({type: "answer", sdp: answer, description_type: "answer", speakers: speakers}.to_json)
                  send_signal.call({type: "renegotiate"}.to_json) if needs_renegotiation
                  STDERR.puts "WebRTC signalling: sent answer (#{answer.bytesize} bytes)"
                else
                  STDERR.puts "WebRTC signalling: discarding answer from replaced peer"
                end
              rescue ex
                STDERR.puts "WebRTC answer error: #{ex.message || ex.class.name}"
                STDERR.puts ex.backtrace.join('\n') if ENV["WUMBLE_DEBUG"]? == "1"
                send_signal.call({type: "error", message: ex.message || "failed to create WebRTC answer"}.to_json)
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
          send_signal.call({type: "error", message: ex.message || "connection failed"}.to_json)
        end
      end
      socket.on_close do |code, reason|
        STDERR.puts "WebRTC signalling: WebSocket closed (#{code}: #{reason.inspect}); closing Mumble connection"
        mic_state_events.close
        mumble.try &.close
        peer.try &.close
      end
    end

    private def channel_state(mumble : MumbleConnection)
      {
        type: "channel_state",
        current_channel: mumble.current_channel,
        channels: mumble.channels.map { |id, name| {id: id, name: name} },
        users: mumble.channel_users.map { |session, name| {session: session, name: name} },
      }
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
