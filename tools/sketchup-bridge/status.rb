# What the frame in the viewport (overlay.rb) says the agent is doing: a line of
# text while code from the bridge runs, and what ran last, with the time it
# finished, afterwards. It is for whoever sits at SketchUp, which is frozen
# while the code runs.
#
# The text comes with the request. See "Protocol" in README.md.

module SketchUpBridge
  module Status

    # Shown for a request that doesn't say what it is for.
    DEFAULT = 'Running code'.freeze

    # Longest description shown, in characters. The rest is cut off.
    MAX_LENGTH = 80

    ELLIPSIS = "…".freeze

    # Punctuation that a description ends with, or is cut off at. An ellipsis
    # is added while the code runs.
    ENDING = /[.,;:#{ELLIPSIS} ]+\z/.freeze

    # Shows what the code is for, before it runs.
    #
    # @param [String, nil] description
    def self.start(description)
      @description = line(description) || DEFAULT
      @outcome = nil
      @model = Sketchup.active_model
      running = @description.end_with?(ELLIPSIS) ? @description : "#{@description}#{ELLIPSIS}"
      show(@model, running, now: true)
    end

    # Code that knows by its end how it went can say so, in place of the
    # description it was sent with. run_tests.rb does.
    #
    # @param [String] text
    def self.outcome=(text)
      @outcome = line(text)
    end

    # The code might have closed the model it started in, or opened another.
    def self.finish
      text = "Finished #{Time.now.strftime('%H:%M')}: #{@outcome || @description}"
      active = Sketchup.active_model
      show(@model, text)
      show(active, text) unless active.equal?(@model)
    ensure
      @model = nil
    end

    # `view.invalidate` isn't enough before the code runs: SketchUp doesn't
    # draw until the request is done with, and it would show the previous
    # text for as long as the code takes. `view.refresh` draws at once, at the
    # cost of drawing the model once more for every request.
    def self.show(model, text, now: false)
      frame = model && defined?(Frame) && Frame.of(model)
      return unless frame

      frame.status = text
      return unless frame.enabled? # Switched off by the user.

      now ? model.active_view.refresh : model.active_view.invalidate
    rescue StandardError => error
      # The status is a courtesy. It must not stop the code from running.
      warn("SketchUp bridge: could not show the status: #{error.class}: #{error.message}")
    end

    # The text comes from outside, and is shown to the user: one line of it,
    # and not too long.
    def self.line(text)
      text = text.to_s.scrub.gsub(/[[:space:][:cntrl:]]+/, ' ').sub(ENDING, '').strip
      return nil if text.empty?

      text.length > MAX_LENGTH ? "#{text[0, MAX_LENGTH - 1].sub(ENDING, '')}#{ELLIPSIS}" : text
    end

  end
end
