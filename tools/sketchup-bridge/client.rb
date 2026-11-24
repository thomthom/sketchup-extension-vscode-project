# Sends Ruby code to the bridge running inside SketchUp (server.rb).
#
# From a terminal:
#
#   ruby tools/sketchup-bridge/client.rb "Sketchup.active_model.title"
#   ruby tools/sketchup-bridge/client.rb < script.rb
#   ruby tools/sketchup-bridge/client.rb --description "Counting entities" "..."
#
# Also required by mcp_server.rb. Runs outside SketchUp, with any Ruby 2.7 or
# newer, and needs no gems.

require 'json'
require 'socket'

module SketchUpBridge

  HOST = '127.0.0.1'
  PORT = 7200 # Keep in sync with server.rb.

  # Starts the line that can precede the code, to say what the code is for.
  # Keep in sync with server.rb.
  DESCRIPTION = '# bridge-description:'.freeze

  class NotRunning < StandardError; end

  # Returns the bridge's response: a Hash with "success", "output", and either
  # "result", or "error" and "backtrace". Also "model", which `model_status`
  # turns into text, and "model_changed", which is true when the bridge
  # refused to run the code because the active model was switched.
  #
  # @param [String] code
  # @param [String, nil] description a few words on what the code is for,
  #   which SketchUp shows the user while it runs
  def self.evaluate(code, description = nil)
    code = "#{DESCRIPTION} #{description.to_s.gsub(/\s+/, ' ').strip}\n#{code}" if description
    socket = connect
    begin
      socket.write(code.encode(Encoding::UTF_8))
      socket.close_write
      JSON.parse(socket.read.force_encoding(Encoding::UTF_8))
    ensure
      socket.close
    end
  end

  def self.connect
    TCPSocket.new(HOST, PORT)
  rescue Errno::ECONNREFUSED
    raise NotRunning, "The SketchUp bridge is not running (nothing is listening on #{HOST}:#{PORT}). " \
                      'Start SketchUp with: ruby tools/debug-sketchup.rb <version> --bridge'
  end

  # One line saying which model the code ran in. Nil when the response doesn't
  # say, which is when the request was refused.
  def self.model_status(response)
    return nil unless response.key?('model')

    model = response['model']
    return '[Active model: none]' unless model

    name = model['path'].empty? ? 'untitled, not saved to a file' : model['path']
    "[Active model: #{name}, #{model['modified'] ? 'with' : 'without'} unsaved changes]"
  end

end

if $PROGRAM_NAME == __FILE__
  description = ARGV.shift(2).last if ARGV.first == '--description'
  code = ARGV.empty? ? $stdin.read : ARGV.join(' ')

  begin
    response = SketchUpBridge.evaluate(code, description)
  rescue SketchUpBridge::NotRunning => error
    abort(error.message)
  end

  print(response['output'])
  puts(response['result']) if response['success']

  # On stderr, so that stdout holds only what the code printed and returned.
  $stdout.flush
  unless response['success']
    warn(response['error'])
    response['backtrace'].each { |line| warn("  #{line}") }
  end
  status = SketchUpBridge.model_status(response)
  warn(status) if status
  exit(1) unless response['success']
end
