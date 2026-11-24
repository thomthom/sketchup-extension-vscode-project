# Marks the SketchUp instance that the bridge runs in: a frame around the
# viewport, with a line of text. It tells whoever sits at it that code sent
# through the bridge may change or clear the model, so that they don't open
# their own work in it by mistake. A second line, at the bottom, says what the
# agent is doing or did last.
#
# Loaded by server.rb once the bridge is listening, on SketchUp 2023 and newer,
# which is when overlays were added.

module SketchUpBridge
  class Frame < Sketchup::Overlay

    TEXT = 'AI agent may change this model'.freeze

    COLOR = Sketchup::Color.new(235, 95, 0)
    TEXT_COLOR = Sketchup::Color.new(255, 255, 255)

    # In logical pixels.
    THICKNESS = 3
    PADDING = 8

    # The font size is in points on Windows and in pixels on macOS. SketchUp
    # scales it for high DPI screens itself.
    TEXT_OPTIONS = {
      size: Sketchup.platform == :platform_win ? 10 : 13,
      bold: true,
      color: TEXT_COLOR,
      align: TextAlignCenter,
      vertical_align: TextVerticalAlignCenter
    }.freeze

    # Overlays belong to a model, so each new model needs one added.
    class Observer < Sketchup::AppObserver

      def onNewModel(model)
        Frame.add_to(model)
      end

      def onOpenModel(model)
        Frame.add_to(model)
      end

    end

    def self.start
      Sketchup.add_observer(Observer.new)
      add_to(Sketchup.active_model)
    end

    # Only the first frame is switched on. SketchUp gives an overlay added
    # later the state the previous one with the same id was left in. So when
    # the user switches the frame off in the Overlays panel, it stays off in
    # the models they create or open after that, until SketchUp is restarted.
    #
    # @param [Sketchup::Model, nil] model nil when no model is open, on macOS
    def self.add_to(model)
      return unless model

      frame = new
      return unless model.overlays.add(frame) # False if it has one already.

      @frames.delete_if { |_, other| !other.valid? } # Their models are gone.
      @frames[model] = frame
      return if @switched_on

      frame.enabled = true
      @switched_on = true
    end

    # Several models can be open, each with a frame of its own.
    @frames = {}.compare_by_identity

    # @return [Frame, nil] the frame of a model that is still open
    def self.of(model)
      frame = @frames[model]
      frame if frame&.valid?
    end

    # What the agent is doing in this model, shown at the bottom of the frame.
    # See status.rb.
    #
    # @return [String, nil]
    attr_reader :status

    def status=(text)
      @status = text
      @status_size = nil
    end

    def initialize
      super('sketchup_bridge.frame', 'SketchUp Bridge',
            description: 'Warns that an AI agent can run code in this SketchUp instance.')
    end

    # Called very often, so it does as little as it can.
    def draw(view)
      scale = self.class.scale
      width = view.vpwidth
      height = view.vpheight
      thickness = THICKNESS * scale

      @text_size ||= view.text_bounds(ORIGIN, TEXT, TEXT_OPTIONS)
      @status_size ||= view.text_bounds(ORIGIN, @status, TEXT_OPTIONS) if @status
      label = tab(@text_size, width, 0, scale)
      status = tab(@status_size, width, height, scale) if @status

      view.drawing_color = COLOR
      view.draw2d(GL_QUADS,
                  *quad(0, 0, width, thickness),
                  *quad(0, height - thickness, width, height),
                  *quad(0, thickness, thickness, height - thickness),
                  *quad(width - thickness, thickness, width, height - thickness),
                  *quad(*label), *(status ? quad(*status) : []))
      view.draw_text(centre(label), TEXT, TEXT_OPTIONS)
      view.draw_text(centre(status), @status, TEXT_OPTIONS) if status
    end

    # From SketchUp 2025 the view is measured and drawn to in logical pixels.
    # Older versions use physical pixels, so sizes have to be scaled up for
    # high DPI screens.
    def self.scale
      @scale ||= Sketchup.version.to_i >= 25 ? 1.0 : UI.scale_factor
    end

    private

    # The rectangle behind a line of text, in the middle of the top edge of
    # the frame, or of the bottom edge when `edge` is the height of the view.
    #
    # @return [Array(Float, Float, Float, Float)] left, top, right, bottom
    def tab(text_size, width, edge, scale)
      half = (text_size.width / 2.0) + (PADDING * scale)
      tall = text_size.height + (PADDING * scale)
      top = edge.zero? ? 0 : edge - tall
      [(width / 2.0) - half, top, (width / 2.0) + half, top + tall]
    end

    def centre(rectangle)
      left, top, right, bottom = rectangle
      Geom::Point3d.new((left + right) / 2.0, (top + bottom) / 2.0, 0)
    end

    def quad(left, top, right, bottom)
      [
        Geom::Point3d.new(left, top, 0), Geom::Point3d.new(right, top, 0),
        Geom::Point3d.new(right, bottom, 0), Geom::Point3d.new(left, bottom, 0)
      ]
    end

  end
end
