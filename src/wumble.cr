require "option_parser"
require "./wumble/server"

socket_path = "/tmp/wumble.sock"
socket_group = "http"
web_root = File.expand_path("../web", __DIR__)

OptionParser.parse do |parser|
  parser.banner = "Usage: wumble [options]"
  parser.on("--socket PATH", "Unix socket path (default: #{socket_path})") { |value| socket_path = value }
  parser.on("--group GROUP", "Unix socket group (default: #{socket_group})") { |value| socket_group = value }
  parser.on("--web-root PATH", "Directory containing the thin browser client") { |value| web_root = value }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }
end

abort "--socket must not be empty" if socket_path.empty?
abort "--group must not be empty" if socket_group.empty?
abort "web root does not exist: #{web_root}" unless Dir.exists?(web_root)
puts "Wumble listening on unix://#{socket_path} (group #{socket_group})"
Wumble::Gateway.new(web_root).run(socket_path, socket_group)
