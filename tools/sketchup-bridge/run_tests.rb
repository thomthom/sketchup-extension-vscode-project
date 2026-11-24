# The part of the `run_tests` tool (mcp_server.rb) that runs inside SketchUp.
# It runs the tests with TestUp's API, and returns the results.
#
# mcp_server.rb `load`s this file through the bridge before every run, so
# changes to it take effect without restarting SketchUp. The result is written
# to $stdout as JSON, and everything else the run prints is captured, so that
# the JSON is the only output the bridge returns.

require 'json'
require 'stringio'

module SketchUpBridge
  module RunTests

    # The first version with the `quiet` option, which returns results from
    # `TestUp::API.run_tests` outside of TestUp's window, and which raises an
    # error for test names that match nothing.
    TESTUP_VERSION = '2.6.0'

    # What to tell whoever runs the tests when something the tests need is not
    # loaded in SketchUp. The setup that lasts comes first; loading for this
    # instance only is a stopgap, and is presented as one.
    module Setup

      TESTUP = 'https://github.com/SketchUp/testup-2'.freeze
      EXTENSION_SOURCES = 'https://github.com/thomthom/extension-sources'.freeze
      README = 'tools/sketchup-bridge/README.md'.freeze

      AGENT = <<~TEXT.strip.freeze
        If you are an AI agent: guide the user through the setup, and ask before each step you do yourself. You may offer to clone a repository, and do it only when the user says yes. Don't edit the user's Extension Sources list or other SketchUp settings; the user adds folders in its dialog.
      TEXT

      # @param [String] problem what is wrong with TestUp in this instance
      def self.testup(problem)
        <<~TEXT.strip
          #{problem}

          Setup, done once:
          1. Get TestUp #{TESTUP_VERSION} or newer from #{TESTUP}. Install the RBZ from its Releases page if that version is there. Otherwise clone the repository and set it up from source, as its README describes. "Prerequisites" in #{README} says which branch to use.
          2. A clone has to be loaded when SketchUp starts. Recommended: install Extension Sources (#{EXTENSION_SOURCES}) and add the clone's `src` folder in its dialog.
          3. Restart SketchUp with the bridge.

          #{AGENT}

          #{workaround("$LOAD_PATH << '<the clone>/src'; require 'testup'")}
        TEXT
      end

      # @param [String] folder the extension's folder, as given in "reload"
      def self.extension(folder)
        source = File.dirname(folder)
        name = File.basename(folder)
        registered = File.exist?("#{folder}.rb")
        code = registered ? "$LOAD_PATH << '#{source}'; require '#{name}'" : nil
        code ||= "$LOAD_PATH << '<the folder with the registration file>'; require '<the registration file>'"
        <<~TEXT.strip
          The extension in #{folder} is not loaded in this SketchUp instance. `reload` loads changed code again; it doesn't load an extension for the first time.

          Setup, done once:
          1. Make SketchUp load the extension from its source folder when it starts. Recommended: install Extension Sources (#{EXTENSION_SOURCES}) and add #{registered ? source : "the folder with the extension's registration file"} in its dialog.
          2. Restart SketchUp with the bridge.

          #{AGENT}

          #{workaround(code)}
        TEXT
      end

      def self.workaround(code)
        'Quick workaround, for this SketchUp instance only, when the user wants to try things before setting up: ' \
          "run `#{code}` with evaluate_ruby. It is gone when SketchUp closes. Offer it as a stopgap, not as the setup."
      end

      # How it shows when the extension under test isn't loaded and "reload"
      # wasn't given, so that there is no telling which extension that is.
      NOT_FOUND = /uninitialized constant|cannot load such file/.freeze

      HINT = 'A constant or a file was not found. If it belongs to the extension under test, that extension ' \
             "is not loaded in this SketchUp instance. Pass the extension's folder in `reload` to check: " \
             'the reply then says how to set it up.'.freeze

    end

    # Notices changes to the model made after a test run: by the user, or by
    # code sent through the bridge. Changes the tests made themselves are fine
    # to throw away; anything else might be the user's work.
    class ChangeTracker < Sketchup::ModelObserver

      attr_accessor :changed

      def onTransactionCommit(_model)
        @changed = true
      end

      def onTransactionUndo(_model)
        @changed = true
      end

      def onTransactionRedo(_model)
        @changed = true
      end

    end

    # @param [Hash] options
    #   "suite" - absolute path of the test suite folder.
    #   "tests" - test cases or tests to run: `TC_Foo`, `TC_Foo#test_bar`, with
    #             or without their namespace. All tests when empty.
    #   "reload" - absolute paths of files or folders to `load` first.
    #   "seed" - Minitest seed. Random when not given.
    #   "discard_model_changes" - run even if the model has unsaved changes.
    #   "accept_switched_model" - run even if the model became the active one
    #                             outside the bridge.
    def self.run(options)
      output = StringIO.new
      stdout = $stdout
      stderr = $stderr
      $stdout = output
      $stderr = output
      begin
        result = run_suite(options)
      rescue StandardError, ScriptError => error
        result = { error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(10) }
      ensure
        $stdout = stdout
        $stderr = stderr
      end
      result[:output] = output.string
      # A test file that requires the extension's code fails to load, and
      # TestUp prints why.
      result[:hint] ||= Setup::HINT if result[:error] && output.string.match?(Setup::NOT_FOUND)
      $stdout.write(JSON.generate(result))
      nil
    end

    def self.run_suite(options)
      error = check_testup
      return { error: error } if error

      suite_path = options['suite']
      return { error: "No such test suite folder: #{suite_path}" } unless File.directory?(suite_path)

      error = check_extension(options['reload'] || [])
      return { error: error } if error

      refusal = refusal(Sketchup.active_model, options)
      return { refused: refusal } if refusal

      reloaded = reload(options['reload'] || [])

      suite = TestUp::API.discover_tests([suite_path]).first
      return { error: "No test cases found in #{suite_path}" } if suite.nil? || suite.test_cases.empty?

      tests = options['tests'] || []
      tests = tests.empty? ? suite.test_cases.map { |test_case| "#{test_case.title}#" } : full_names(suite, tests)

      seed = (options['seed'] || rand(1..0xFFFF)).to_i
      results = nil
      started = Time.now
      begin
        TestUp::API.run_tests(tests, title: suite.title, path: suite_path,
                                     options: { quiet: true, seed: seed }) { |test_suite| results = test_suite }
      rescue ArgumentError => error
        # Names that match no test. The message lists the suite's test cases.
        return { error: error.message }
      end
      seconds = Time.now - started

      track(Sketchup.active_model)
      result = summarize(results, seed, seconds, reloaded)
      result[:hint] = Setup::HINT if not_found?(result[:problems])
      result
    end

    def self.check_testup
      unless defined?(TestUp::API)
        return Setup.testup('TestUp is not loaded in this SketchUp instance, and run_tests needs it.')
      end

      version = TestUp::PLUGIN_VERSION
      return nil if Gem::Version.new(version) >= Gem::Version.new(TESTUP_VERSION)

      Setup.testup("This SketchUp instance has TestUp #{version}, and run_tests needs #{TESTUP_VERSION} or newer.")
    end

    def self.not_found?(problems)
      problems.any? do |problem|
        problem[:failures].any? { |failure| failure[:message].to_s.match?(Setup::NOT_FOUND) }
      end
    end

    # The code to reload has to be loaded already. It doesn't matter how it got
    # loaded, so this looks at what Ruby has loaded and not at any particular
    # way of loading extensions.
    def self.check_extension(paths)
      missing = paths.find { |path| !File.exist?(path) }
      return "No such file or folder to reload: #{missing}" if missing

      loaded = $LOADED_FEATURES.map { |file| comparable(file) }
      folders = paths.map { |path| File.directory?(path) ? path : File.dirname(path) }
      unloaded = folders.find do |folder|
        prefix = "#{comparable(folder)}/"
        loaded.none? { |file| file.start_with?(prefix) }
      end
      unloaded && Setup.extension(unloaded)
    end

    # File systems on Windows and macOS don't tell upper case from lower case.
    def self.comparable(path)
      File.expand_path(path).downcase
    end

    # Loads extension code again, so the tests run against the latest source.
    # Folders are searched recursively for .rb files.
    def self.reload(paths)
      files = paths.flat_map do |path|
        File.directory?(path) ? Dir.glob(File.join(path, '**', '*.rb')).sort : [path]
      end
      verbose = $VERBOSE
      $VERBOSE = nil # Silence warnings about redefined methods and constants.
      files.each { |file| load(file) }
      files.size
    ensure
      $VERBOSE = verbose
    end

    # TestUp needs the full name of a test case, including its namespace. This
    # adds the namespace to a name given without one, when exactly one test
    # case in the suite has that name. Anything else is passed on as it is, and
    # TestUp reports names that match nothing.
    def self.full_names(suite, tests)
      tests.map do |name|
        case_name, test_name = name.split('#', 2)
        matches = suite.test_cases.map(&:title).select { |title| title.end_with?("::#{case_name}") }
        case_name = matches.first if matches.size == 1
        "#{case_name}##{test_name}"
      end
    end

    # Why the tests can't run in this model, or nil when they can.
    def self.refusal(model, options)
      if switched_model?
        unless options['accept_switched_model']
          return 'The active model was created, opened or switched to outside the bridge, most likely ' \
                 'by the user, so it may hold their work. Tests can clear the model, so they were not ' \
                 'run. Ask the user, then pass accept_switched_model if the tests may run in this model.'
        end
        ModelWatch.accept
      end
      return nil if options['discard_model_changes'] || safe_to_change?(model)

      'The model has unsaved changes that were not made by a previous test run. ' \
        'Tests can clear the model, so they were not run. Save the model, or pass ' \
        'discard_model_changes if the changes can be lost.'
    end

    # server.rb keeps track of this. An instance that was started before the
    # bridge did so runs the older server.rb until it is restarted.
    def self.switched_model?
      defined?(ModelWatch) && ModelWatch.unexpected?
    end

    def self.safe_to_change?(model)
      return true unless model.modified?

      @model.equal?(model) && @replacements == replacements && !@tracker.changed
    end

    def self.track(model)
      @model.remove_observer(@tracker) if @tracker && @model.valid?
      @tracker = ChangeTracker.new
      model.add_observer(@tracker)
      @model = model
      @replacements = replacements
    end

    # How many models have been created or opened. On Windows, up to SketchUp
    # 2026, a new model is the same Ruby object as the one it replaced, but
    # without its observers, so the object and the tracker alone can't tell
    # that the model is another.
    def self.replacements
      defined?(ModelWatch) ? ModelWatch.replacements : 0
    end

    # @param [TestUp::Report::TestSuite] results
    def self.summarize(results, seed, seconds, reloaded)
      counts = Hash.new(0)
      problems = []
      results.test_cases.each do |test_case|
        test_case.tests.each do |test|
          result = test.result
          state = if result.passed then 'passed'
                  elsif result.skipped then 'skipped'
                  elsif result.error then 'error'
                  else 'failed'
                  end
          counts[state] += 1
          next if state == 'passed'

          problems << {
            test: "#{test_case.title}##{test.title}",
            status: state,
            failures: result.failures.map { |failure| { message: failure.message, location: failure.location } }
          }
        end
      end
      {
        tests: counts.values.sum, counts: counts, seed: seed, seconds: seconds.round(3),
        reloaded_files: reloaded, problems: problems
      }
    end

  end
end
