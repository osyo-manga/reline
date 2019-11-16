require 'io/console'
require 'timeout'
require 'forwardable'
require 'reline/version'
require 'reline/config'
require 'reline/key_actor'
require 'reline/key_stroke'
require 'reline/line_editor'
require 'reline/history'

module Reline
  FILENAME_COMPLETION_PROC = nil
  USERNAME_COMPLETION_PROC = nil

  Key = Struct.new('Key', :char, :combined_char, :with_meta)
  CursorPos = Struct.new(:x, :y)

  class Core
    if RbConfig::CONFIG['host_os'] =~ /mswin|msys|mingw|cygwin|bccwin|wince|emc/
      IS_WINDOWS = true
    else
      IS_WINDOWS = false
    end

    ATTR_READER_NAMES = %i(
      completion_append_character
      basic_word_break_characters
      completer_word_break_characters
      basic_quote_characters
      completer_quote_characters
      filename_quote_characters
      special_prefixes
      completion_proc
      output_modifier_proc
      prompt_proc
      auto_indent_proc
      pre_input_hook
      dig_perfect_match_proc
    ).each(&method(:attr_reader))

    ATTR_ACCESSOR_NAMES = %i(
      completion_case_fold
    ).each(&method(:attr_accessor))

    attr_accessor :config
    attr_accessor :key_stroke
    attr_accessor :line_editor
    attr_accessor :ambiguous_width
    attr_reader :output

    def initialize
      self.output = STDOUT
      yield self
    end

    def completion_append_character=(val)
      @completion_append_character = val.nil?      ? nil
                                   : val.size == 1 ? val.encode(Encoding::default_external)
                                   : val.size > 1  ? val[0].encode(Encoding::default_external)
                                   :                 nil
    end

    %i(
      basic_word_break_characters
      completer_word_break_characters
      basic_quote_characters
      completer_quote_characters
      filename_quote_characters
      special_prefixes
    ).each { |name|
      define_method("#{name}=") { |v|
        instance_variable_set(:"@#{name}", v.encode(Encoding::default_external))
      }
    }

    %i(
      completion_proc
      output_modifier_proc
      prompt_proc
      auto_indent_proc
      dig_perfect_match_proc
    ).each { |name|
      define_method("#{name}=") { |p|
        raise ArgumentError unless p.is_a?(Proc)
        instance_variable_set(:"@#{name}", p)
      }
    }

    def pre_input_hook=(p)
      @pre_input_hook = p
    end

    def input=(val)
      raise TypeError unless val.respond_to?(:getc) or val.nil?
      if val.respond_to?(:getc)
        if asni?
          Reline::ANSI.input = val
        elsif io_gate == Reline::GeneralIO
          Reline::GeneralIO.input = val
        end
      end
    end

    def output=(val)
      raise TypeError unless val.respond_to?(:write) or val.nil?
      @output = val
      if asni?
        Reline::ANSI.output = val
      end
    end

    def vi_editing_mode
      config.editing_mode = :vi_insert
      nil
    end

    def emacs_editing_mode
      config.editing_mode = :emacs
      nil
    end

    def vi_editing_mode?
      config.editing_mode_is?(:vi_insert, :vi_command)
    end

    def emacs_editing_mode?
      config.editing_mode_is?(:emacs)
    end

    def get_screen_size
      io_gate.get_screen_size
    end

    def readmultiline(prompt = '', add_hist = false, &confirm_multiline_termination)
      unless confirm_multiline_termination
        raise ArgumentError.new('#readmultiline needs block to confirm multiline termination')
      end
      inner_readline(prompt, add_hist, true, &confirm_multiline_termination)

      whole_buffer = line_editor.whole_buffer.dup
      whole_buffer.taint if RUBY_VERSION < '2.7'
      if add_hist and whole_buffer and whole_buffer.chomp.size > 0
        Reline::HISTORY << whole_buffer
      end

      line_editor.reset_line if line_editor.whole_buffer.nil?
      whole_buffer
    end

    def readline(prompt = '', add_hist = false)
      inner_readline(prompt, add_hist, false)

      line = line_editor.line.dup
      line.taint if RUBY_VERSION < '2.7'
      if add_hist and line and line.chomp.size > 0
        Reline::HISTORY << line.chomp
      end

      line_editor.reset_line if line_editor.line.nil?
      line
    end

    private def inner_readline(prompt, add_hist, multiline, &confirm_multiline_termination)
      preset_stderr
      otio = io_gate.prep

      may_req_ambiguous_char_width
      preset_line_editor(prompt: prompt, confirm_multiline_termination_proc: confirm_multiline_termination)

      unless config.test_mode
        config.read
        config.reset_default_key_bindings
        io_gate::RAW_KEYSTROKE_CONFIG.each_pair do |key, func|
          config.add_default_key_binding(key, func)
        end
      end

      begin
        loop do
          read_io(config.keyseq_timeout) { |inputs|
            inputs.each { |c|
              line_editor.input_key(c)
              line_editor.rerender
            }
          }
          break if line_editor.finished?
        end
        io_gate.move_cursor_column(0)
      rescue StandardError => e
        line_editor.finalize
        io_gate.deprep(otio)
        raise e
      end

      line_editor.finalize
      io_gate.deprep(otio)
    end

    # Keystrokes of GNU Readline will timeout it with the specification of
    # "keyseq-timeout" when waiting for the 2nd character after the 1st one.
    # If the 2nd character comes after 1st ESC without timeout it has a
    # meta-property of meta-key to discriminate modified key with meta-key
    # from multibyte characters that come with 8th bit on.
    #
    # GNU Readline will wait for the 2nd character with "keyseq-timeout"
    # milli-seconds but wait forever after 3rd characters.
    private def read_io(keyseq_timeout, &block)
      buffer = []
      loop do
        c = getc
        buffer << c
        result = key_stroke.match_status(buffer)
        case result
        when :matched
          expanded = key_stroke.expand(buffer).map{ |expanded_c|
            Reline::Key.new(expanded_c, expanded_c, false)
          }
          block.(expanded)
          break
        when :matching
          if buffer.size == 1
            begin
              succ_c = nil
              Timeout.timeout(keyseq_timeout / 1000.0) {
                succ_c = getc
              }
            rescue Timeout::Error # cancel matching only when first byte
              block.([Reline::Key.new(c, c, false)])
              break
            else
              if key_stroke.match_status(buffer.dup.push(succ_c)) == :unmatched
                if c == "\e".ord
                  block.([Reline::Key.new(succ_c, succ_c | 0b10000000, true)])
                else
                  block.([Reline::Key.new(c, c, false), Reline::Key.new(succ_c, succ_c, false)])
                end
                break
              else
                ungetc(succ_c)
              end
            end
          end
        when :unmatched
          if buffer.size == 1 and c == "\e".ord
            read_escaped_key(keyseq_timeout, c, block)
          else
            expanded = buffer.map{ |expanded_c|
              Reline::Key.new(expanded_c, expanded_c, false)
            }
            block.(expanded)
          end
          break
        end
      end
    end

    private def read_escaped_key(keyseq_timeout, c, block)
      begin
        escaped_c = nil
        Timeout.timeout(keyseq_timeout / 1000.0) {
          escaped_c = io_gate.getc
        }
      rescue Timeout::Error # independent ESC
        block.([Reline::Key.new(c, c, false)])
      else
        if escaped_c.nil?
          block.([Reline::Key.new(c, c, false)])
        elsif escaped_c >= 128 # maybe, first byte of multi byte
          block.([Reline::Key.new(c, c, false), Reline::Key.new(escaped_c, escaped_c, false)])
        elsif escaped_c == "\e".ord # escape twice
          block.([Reline::Key.new(c, c, false), Reline::Key.new(c, c, false)])
        else
          block.([Reline::Key.new(escaped_c, escaped_c | 0b10000000, true)])
        end
      end
    end

    private def may_req_ambiguous_char_width
      @ambiguous_width = 2 if io_gate == Reline::GeneralIO or STDOUT.is_a?(File)
      return if ambiguous_width
      io_gate.move_cursor_column(0)
      print "\u{25bd}"
      @ambiguous_width = io_gate.cursor_pos.x
      io_gate.move_cursor_column(0)
      io_gate.erase_after_cursor
    end

    private

    def ungetc(...)
      io_gate.ungetc(...)
    end

    def getc
      io_gate.getc
    end

    def io_gate
      Reline::IOGate
    end

    def asni?
      defined?(Reline::ANSI) and io_gate == Reline::ANSI
    end

    def preset_stderr
      if ENV['RELINE_STDERR_TTY']
        $stderr.reopen(ENV['RELINE_STDERR_TTY'], 'w')
        $stderr.sync = true
        $stderr.puts "Reline is used by #{Process.pid}"
      end
    end

    def preset_line_editor(prompt:, confirm_multiline_termination_proc:)
      line_editor.reset(prompt)
      if multiline
        line_editor.multiline_on
        if block_given?
          line_editor.confirm_multiline_termination_proc = confirm_multiline_termination
        end
      else
        line_editor.multiline_off
      end
      line_editor.output = output
      line_editor.completion_proc = completion_proc
      line_editor.output_modifier_proc = output_modifier_proc
      line_editor.prompt_proc = prompt_proc
      line_editor.auto_indent_proc = auto_indent_proc
      line_editor.dig_perfect_match_proc = dig_perfect_match_proc
      line_editor.pre_input_hook = pre_input_hook
      line_editor.rerender
    end
  end

  extend Forwardable
  extend SingleForwardable

  #--------------------------------------------------------
  # Documented API
  #--------------------------------------------------------

  (Core::ATTR_READER_NAMES + Core::ATTR_ACCESSOR_NAMES).each { |name|
    def_single_delegators :core, "#{name}", "#{name}="
  }
  def_single_delegators :core, :input=, :output=
  def_single_delegators :core, :vi_editing_mode, :emacs_editing_mode
  def_single_delegators :core, :readline
  def_instance_delegators self, :readline
  private :readline


  #--------------------------------------------------------
  # Undocumented API
  #--------------------------------------------------------

  # Testable in original
  def_single_delegators :core, :get_screen_size
  def_single_delegators :line_editor, :eof?
  def_instance_delegators self, :eof?
  def_single_delegators :line_editor, :delete_text
  def_single_delegator :line_editor, :line, :line_buffer
  def_single_delegator :line_editor, :byte_pointer, :point
  def_single_delegator :line_editor, :byte_pointer=, :point=

  def self.insert_text(*args, &block)
    line_editor.insert_text(*args, &block)
    self
  end

  # Untestable in original
  def_single_delegator :line_editor, :rerender, :redisplay
  def_single_delegators :core, :vi_editing_mode?, :emacs_editing_mode?
  def_single_delegators :core, :ambiguous_width

  def_single_delegators :core, :readmultiline
  def_instance_delegators self, :readmultiline
  private :readmultiline

  def self.core
    @core ||= Core.new { |core|
      core.config = Reline::Config.new
      core.key_stroke = Reline::KeyStroke.new(core.config)
      core.line_editor = Reline::LineEditor.new(core.config)

      core.basic_word_break_characters = " \t\n`><=;|&{("
      core.completer_word_break_characters = " \t\n`><=;|&{("
      core.basic_quote_characters = '"\''
      core.completer_quote_characters = '"\''
      core.filename_quote_characters = ""
      core.special_prefixes = ""
    }
  end

  def self.line_editor
    core.line_editor
  end

  HISTORY = History.new(core.config)
end

if Reline::Core::IS_WINDOWS
  require 'reline/windows'
  Reline::IOGate = Reline::Windows
else
  require 'reline/ansi'
  Reline::IOGate = Reline::ANSI
end
require 'reline/general_io'
