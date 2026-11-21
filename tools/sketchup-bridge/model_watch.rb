# Keeps track of which model is active in SketchUp, so that every reply from the
# bridge can say which one it is, and whether it is still the one the previous
# request left. Loaded by server.rb.
#
# The SketchUp that the bridge runs in is one the user can work in too. When
# they create or open a model there, whoever is sending code has no other way
# of knowing that it now runs in that model, which may hold the user's work.

module SketchUpBridge
  module ModelWatch

    # Counts the models created and opened. On Windows, up to SketchUp 2026,
    # only one model is open at a time, and `Sketchup.active_model` stays the
    # same Ruby object when another model replaces it, so comparing objects
    # doesn't show it.
    class Observer < Sketchup::AppObserver

      def onNewModel(_model)
        ModelWatch.replaced
      end

      def onOpenModel(_model)
        ModelWatch.replaced
      end

    end

    @replacements = 0
    @unexpected = false

    def self.start
      Sketchup.add_observer(Observer.new)
    end

    def self.replaced
      @replacements += 1
    end

    # How many models have been created or opened since the bridge started.
    #
    # @return [Integer]
    def self.replacements
      @replacements
    end

    # Call before running a request's code.
    def self.begin_request
      @at_start = current
      # Nothing to compare with on the first request. The model SketchUp
      # started with is often replaced before that, by picking a template.
      @changed = !@seen.nil? && @at_start != @seen
      @unexpected = true if @changed
    end

    # Call after running a request's code.
    #
    # @return [Hash] what to add to the reply
    def self.end_request
      @seen = current
      # The model the code itself created or opened is the bridge's own.
      @unexpected = false if @seen != @at_start
      { model: describe(Sketchup.active_model), model_changed: @changed }
    end

    # Whether the active model became the active one between two requests, so
    # not by code sent through the bridge, and nobody has accepted it since.
    def self.unexpected?
      @unexpected
    end

    # Call when the user has agreed to the unexpected model being worked in.
    def self.accept
      @unexpected = false
    end

    # Identifies the active model. The object id covers macOS, and Windows from
    # SketchUp 2027, where several models can be open, each with its own
    # object, and the user can switch between them.
    def self.current
      [Sketchup.active_model&.object_id, @replacements]
    end

    # @param [Sketchup::Model, nil] model nil when no model is open, on macOS
    def self.describe(model)
      return nil unless model

      { title: model.title, path: model.path, modified: model.modified? }
    end

  end
end
