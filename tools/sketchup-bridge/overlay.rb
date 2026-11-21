# Marks the SketchUp that the bridge runs in: a frame around the viewport, with
# a line of text. It tells whoever sits at that SketchUp that code sent through
# the bridge may change or clear the model, so that they don't open their own
# work in it by mistake.
#
# Loaded by server.rb once the bridge is listening, on SketchUp 2023 and newer,
# which is when overlays were added.

module SketchUpBridge
  class Frame < Sketchup::Overlay

    TEXT = 'Claude bridge active: this model may be changed or cleared'.freeze

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
      return if @switched_on

      frame.enabled = true
      @switched_on = true
    end

    def initialize
      super('sketchup_bridge.frame', 'SketchUp Bridge',
            description: 'Marks a SketchUp that Claude Code can run code in, through the SketchUp bridge.')
    end

    # Called very often, so it does as little as it can.
    def draw(view)
      scale = self.class.scale
      width = view.vpwidth
      height = view.vpheight
      thickness = THICKNESS * scale

      label = Geom::Point3d.new(width / 2.0, 0, 0)
      @text_size ||= view.text_bounds(label, TEXT, TEXT_OPTIONS)
      half = (@text_size.width / 2.0) + (PADDING * scale)
      label_height = @text_size.height + (PADDING * scale)
      label.y = label_height / 2.0

      view.drawing_color = COLOR
      view.draw2d(GL_QUADS,
                  *quad(0, 0, width, thickness),
                  *quad(0, height - thickness, width, height),
                  *quad(0, thickness, thickness, height - thickness),
                  *quad(width - thickness, thickness, width, height - thickness),
                  *quad(label.x - half, 0, label.x + half, label_height))
      view.draw_text(label, TEXT, TEXT_OPTIONS)
    end

    # From SketchUp 2025 the view is measured and drawn to in logical pixels.
    # Older versions use physical pixels, so sizes have to be scaled up for
    # high DPI screens.
    def self.scale
      @scale ||= Sketchup.version.to_i >= 25 ? 1.0 : UI.scale_factor
    end

    private

    def quad(left, top, right, bottom)
      [
        Geom::Point3d.new(left, top, 0), Geom::Point3d.new(right, top, 0),
        Geom::Point3d.new(right, bottom, 0), Geom::Point3d.new(left, bottom, 0)
      ]
    end

  end
end
