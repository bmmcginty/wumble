require "http/server"
require "http/web_socket"
require "json"
require "uri"
require "system/group"
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

    def run(socket_path : String, socket_group : String)
      remove_stale_socket(socket_path)
      websocket = HTTP::WebSocketHandler.new { |socket, context| puts context.request.path; context.request.path == "/ws" ? handle_socket(socket) : socket.close }
      server = HTTP::Server.new([websocket]) { |context| serve(context); nil }
      server.bind_unix(socket_path)
      group = System::Group.find_by(name: socket_group)
      File.chown(socket_path, gid: group.id.to_i)
      File.chmod(socket_path, 0o660)
      server.listen
    ensure
      File.delete?(socket_path) if File.info?(socket_path).try(&.type.socket?)
    end

    private def remove_stale_socket(socket_path : String)
      return unless info = File.info?(socket_path, follow_symlinks: false)
      raise "refusing to replace non-socket at #{socket_path}" unless info.type.socket?
      File.delete(socket_path)
    end

    private def handle_socket(socket : HTTP::WebSocket)
      STDERR.puts "WebRTC signalling: WebSocket opened"
      peer = nil.as(Peer?)
      mumble = nil.as(MumbleConnection?)
      mic_state_events = Channel(Bool).new(8)
      # Signalling is emitted from the Mumble TCP fiber (on_state), from the
      # media-path monitor and from this socket's own message handler.
      # Serialize the frames so they cannot interleave, and swallow send
      # errors: an exception raised inside a Mumble callback unwinds that
      # connection's read loop and is reported as a Mumble disconnect.
      send_lock = Mutex.new
      send_signal = ->(payload : String) do
        send_lock.synchronize do
          socket.send(payload)
        rescue ex
          STDERR.puts "WebRTC signalling: send failed: #{ex.message || ex.class.name}"
        end
      end
      # Name every assigned section for the browser. This is what tells it
      # which audio element is whom, and it is ordinary signalling data: the
      # SSRCs belong to the sections, so a speaker changing places needs this
      # message and nothing else.
      sections_of = ->(current : Peer, connection : MumbleConnection) do
        current.assignments.map do |assignment|
          {
            mid:     assignment[:mid],
            ssrc:    assignment[:ssrc],
            session: assignment[:session],
            name:    connection.users[assignment[:session]]? || "Session #{assignment[:session]}",
          }
        end
      end
      # Publish whatever set_speakers decided. An offer carries the mapping
      # too, so the browser is never left holding a section it cannot name.
      # Peer#offer returns nil while an answer is outstanding and remembers the
      # request, so calling this more often than necessary is harmless.
      publish = ->(current : Peer, result : Symbol) do
        connection = mumble
        return unless connection && peer == current
        case result
        when :offer
          if sdp = current.offer
            send_signal.call({type: "offer", sdp: sdp, sections: sections_of.call(current, connection)}.to_json)
          end
        when :sections
          send_signal.call({type: "sections", sections: sections_of.call(current, connection)}.to_json)
        end
      end
      # libdatachannel's ICE agent can give up while the browser still believes
      # the connection is fine, which is how a session ends up connected and
      # permanently silent. libdatachannel has no ICE restart, so rebuild the
      # media path instead. The Mumble connection is untouched, so this costs a
      # DTLS handshake and nothing else -- worth it on a path that has already
      # failed, to keep the gateway the only side that ever offers.
      rebuild_media = nil.as(Proc(Peer, String, Nil)?)
      wire_peer = ->(new_peer : Peer) do
        new_peer.on_opus { |opus, frame_number| mumble.not_nil!.send_opus(opus, frame_number) }
        new_peer.on_connection_lost do |detail|
          spawn { rebuild_media.try &.call(new_peer, detail) }
        end
      end
      rebuild_media = ->(lost_peer : Peer, detail : String) do
        return unless peer == lost_peer
        STDERR.puts "WebRTC signalling: rebuilding the media path (#{detail})"
        lost_peer.close
        replacement = Peer.new
        peer = replacement
        wire_peer.call(replacement)
        send_signal.call({type: "media_restart", reason: detail}.to_json)
        connection = mumble
        replacement.set_speakers(connection ? connection.speaker_sessions : [] of UInt32)
        publish.call(replacement, :offer)
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
            new_peer = Peer.new
            peer = new_peer
            mumble = MumbleConnection.new(request.server, request.port, request.username, request.password)
            mumble.not_nil!.on_disconnect do |reason, reconnect|
              type = reconnect && !reason.starts_with?("Mumble rejected authentication") ? "mumble_disconnected" : "error"
              send_signal.call({type: type, message: reason}.to_json)
            end
            wire_peer.call(new_peer)
            # Every roster update goes through one place. A UserState can carry
            # only a channel change and no name, and a UserRemove carries only a
            # session, so reconciling the whole membership here is what keeps a
            # join, a departure, a channel switch and a rejoin from each needing
            # their own path. A channel switch is now just a different answer
            # from speaker_sessions: no peer connection is rebuilt for it.
            mumble.not_nil!.on_state do
              connection = mumble.not_nil!
              send_signal.call(channel_state(connection).to_json)
              if current = peer
                # set_speakers has to run here, in order, on the fiber that read
                # the update. Publishing waits on ICE gathering, so hand that to
                # a new fiber rather than stalling the Mumble read loop.
                result = current.set_speakers(connection.speaker_sessions)
                spawn { publish.call(current, result) }
              end
            end
            mumble.not_nil!.on_voice { |speaker, opus, frame_number| peer.try &.send_opus(speaker, opus, frame_number) }
            mumble.not_nil!.on_voice_end { |speaker| peer.try &.end_voice(speaker) }
            # Wait for both synchronization and a working native UDP path.
            # TCP UDPTunnel voice is deliberately not a fallback because its
            # head-of-line blocking causes the latency this gateway avoids.
            mumble.not_nil!.on_ready do
              connection = mumble.not_nil!
              send_signal.call({type: "connected"}.to_json) if connection.udp_available
            end
            mumble.not_nil!.on_udp_available do
              connection = mumble.not_nil!
              send_signal.call({type: "connected"}.to_json) if connection.synchronized
            end
            mumble.not_nil!.on_udp_unavailable do
              send_signal.call({type: "udp_unavailable", message: "Native UDP to the Mumble server is unavailable. Check UDP port #{request.port}."}.to_json)
            end
            # Offer the microphone straight away. The browser can be heard as
            # soon as the media path is up, whether or not Mumble has finished
            # synchronizing or anybody else is in the channel yet.
            spawn do
              if sdp = new_peer.offer
                send_signal.call({type: "offer", sdp: sdp, sections: [] of String}.to_json)
              end
            end
            mumble.not_nil!.connect
          when "switch_channel"
            raise "connect before switching channels" unless mumble
            mumble.not_nil!.switch_channel(data["channel"].as_i.to_u32)
          when "answer"
            raise "connect before sending an answer" unless peer
            current = peer.not_nil!
            # A section created while this answer was in flight could not be
            # offered then. Now that the cycle is complete, offer again -- on a
            # new fiber, because it waits on ICE gathering and this one is
            # reading the signalling socket.
            spawn { publish.call(current, :offer) } if current.accept_answer(data["sdp"].as_s)
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
