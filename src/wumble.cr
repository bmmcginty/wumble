require "option_parser"
require "./wumble/server"

bind = "0.0.0.0"
port = 8080
web_root = File.expand_path("../web", __DIR__)

OptionParser.parse do |parser|
  parser.banner = "Usage: wumble [options]"
  parser.on("--bind ADDRESS", "Address to listen on (default: #{bind})") { |value| bind = value }
  parser.on("--port PORT", "HTTP/WebSocket port (default: #{port})") { |value| port = value.to_i }
  parser.on("--web-root PATH", "Directory containing the thin browser client") { |value| web_root = value }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }
end

abort "--port must be between 1 and 65535" unless 1..65_535 === port
abort "web root does not exist: #{web_root}" unless Dir.exists?(web_root)
puts "Wumble listening on http://#{bind}:#{port}"
Wumble::Gateway.new(web_root).run(bind, port)
