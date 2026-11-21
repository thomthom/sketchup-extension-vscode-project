# Sends Ruby code to the bridge running inside SketchUp (server.rb).
#
# From a terminal:
#
#   ruby tools/sketchup-bridge/client.rb "Sketchup.active_model.title"
#   ruby tools/sketchup-bridge/client.rb < script.rb
#
# Also required by mcp_server.rb. Runs outside SketchUp, with any Ruby 2.7 or
# newer, and needs no gems.

require 'json'
require 'socket'

module SketchUpBridge

  HOST = '127.0.0.1'
  PORT = 7200 # Keep in sync with server.rb.

  class NotRunning < StandardError; end

  MODEL_CHANGED = 'WARNING: The active model in SketchUp is not the one the previous call left. It was ' \
                  'created, opened or switched to outside the bridge, most likely by the user, so it ' \
                  'may hold their work. Ask before changing it or running tests in it.'

  # Returns the bridge's response: a Hash with "success", "output", and either
  # "result", or "error" and "backtrace". Also "model" and "model_changed",
  # which `model_status` and `model_warning` turn into text.
  def self.evaluate(code)
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

  # A warning when the user seems to have switched to another model since the
  # previous call, otherwise nil.
  def self.model_warning(response)
    response['model_changed'] ? MODEL_CHANGED : nil
  end

end

if $PROGRAM_NAME == __FILE__
  code = ARGV.empty? ? $stdin.read : ARGV.join(' ')

  begin
    response = SketchUpBridge.evaluate(code)
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
  [SketchUpBridge.model_status(response), SketchUpBridge.model_warning(response)].compact.each { |line| warn(line) }
  exit(1) unless response['success']
end
