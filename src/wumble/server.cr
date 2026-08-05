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

  module Signalling
    @@sockets = {} of LibDataChannel::Handle => HTTP::WebSocket
    @@lock = Mutex.new

    def self.register(peer : Peer, socket : HTTP::WebSocket)
      @@lock.synchronize { @@sockets[peer.pc] = socket }
      LibDataChannel.rtc_set_local_description_callback(peer.pc, ->local_description(LibDataChannel::Handle, UInt8*, UInt8*, Void*))
      LibDataChannel.rtc_set_local_candidate_callback(peer.pc, ->candidate(LibDataChannel::Handle, UInt8*, UInt8*, Void*))
    end

    def self.remove(peer : Peer)
      @@lock.synchronize { @@sockets.delete(peer.pc) }
      peer.close
    end

    def self.local_description(pc : LibDataChannel::Handle, sdp : UInt8*, type : UInt8*, _user : Void*)
      send(pc, {type: "answer", sdp: String.new(sdp), description_type: String.new(type)}.to_json)
    end

    def self.candidate(pc : LibDataChannel::Handle, candidate : UInt8*, mid : UInt8*, _user : Void*)
      send(pc, {type: "candidate", candidate: String.new(candidate), mid: String.new(mid)}.to_json)
    end

    private def self.send(pc, payload)
      @@lock.synchronize { @@sockets[pc]?.try &.send(payload) }
    end
  end

  class Gateway
    def initialize(@web_root : String)
    end

    def run(bind : String, port : Int32)
      websocket = HTTP::WebSocketHandler.new { |socket, context| context.request.path == "/signal" ? handle_socket(socket) : socket.close }
      HTTP::Server.new([websocket]) { |context| serve(context); nil }.listen(bind, port)
    end

    private def handle_socket(socket : HTTP::WebSocket)
      peer = nil.as(Peer?)
      mumble = nil.as(MumbleConnection?)
      socket.on_message do |message|
        begin
          data = JSON.parse(message)
          case data["type"].as_s
          when "connect"
            raise "already connected" if peer
            request = ConnectRequest.from_json(data["options"].to_json)
            validate(request)
            peer = Peer.new
            Signalling.register(peer.not_nil!, socket)
            mumble = MumbleConnection.new(request.server, request.port, request.username, request.password)
            mumble.not_nil!.on_voice { |speaker, opus| peer.not_nil!.send_opus(speaker, opus) }
            mumble.not_nil!.connect
            socket.send({type: "connected"}.to_json)
          when "offer"
            peer.try &.accept_offer(data["sdp"].as_s)
          when "candidate"
            peer.try &.add_candidate(data["candidate"].as_s, data["mid"]?.try(&.as_s) || "0")
          else
            raise "unknown signalling message"
          end
        rescue ex
          socket.send({type: "error", message: ex.message || "connection failed"}.to_json)
        end
      end
      socket.on_close do
        mumble.try &.close
        peer.try { |value| Signalling.remove(value) }
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
