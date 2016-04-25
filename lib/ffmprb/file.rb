require 'json'
require 'mkfifo'
require 'tempfile'

module Ffmprb

  class File  # NOTE I would rather rename it to Stream at the moment
    include Util::ProcVis::Node

    class << self

      # NOTE careful when subclassing, it doesn't inherit the attr values
      attr_accessor :image_extname_regex, :sound_extname_regex, :movie_extname_regex

      # NOTE must be timeout-safe
      def opener(file, mode=nil)
        ->{
          path = file.respond_to?(:path)? file.path : file
          mode ||= file.respond_to?(mode)? file.mode.to_s[0] : 'r'
          Ffmprb.logger.debug{"Trying to open #{path} (for #{mode}-buffering or something)"}
          ::File.open(path, mode)
        }
      end

      def create(path)
        new(path: path, mode: :write).tap do |file|
          Ffmprb.logger.debug{"Created file with path: #{file.path}"}
        end
      end

      def open(path)
        new(path: path, mode: :read).tap do |file|
          Ffmprb.logger.debug{"Opened file with path: #{file.path}"}
        end
      end

      def temp(extname)
        file = create(Tempfile.new(['', extname]))
        path = file.path
        Ffmprb.logger.debug{"Created temp file with path: #{path}"}

        return file  unless block_given?

        begin
          yield file
        ensure
          begin
            file.unlink
          rescue
            Ffmprb.logger.warn "#{$!.class.name} removing temp file with path #{path}: #{$!.message}"
          end
          Ffmprb.logger.debug{"Removed temp file with path: #{path}"}
        end
      end

      def temp_fifo(extname='.tmp', &blk)
        path = temp_fifo_path(extname)
        ::File.mkfifo path
        fifo_file = create(path)

        return fifo_file  unless block_given?

        path = fifo_file.path
        begin
          yield fifo_file
        ensure
          begin
            fifo_file.unlink
          rescue
            Ffmprb.logger.warn "#{$!.class.name} removing temp file with path #{path}: #{$!.message}"
          end
          Ffmprb.logger.debug{"Removed temp file with path: #{path}"}
        end
      end

      def temp_fifo_path(extname)
        ::File.join Dir.tmpdir, Dir::Tmpname.make_tmpname('', 'p' + extname)
      end

      def image?(extname)
        !!(extname =~ File.image_extname_regex)
      end

      def sound?(extname)
        !!(extname =~ File.sound_extname_regex)
      end

      def movie?(extname)
        !!(extname =~ File.movie_extname_regex)
      end

    end

    attr_reader :mode

    def initialize(path:, mode:)
      @mode = mode.to_sym
      fail Error, "Open for read, create for write, ??? for #{@mode}"  unless %i[read write].include?(@mode)
      @path = path
      @path.close  if @path && @path.respond_to?(:close)  # NOTE we operate on closed files
      path!  # NOTE early (exception) raiser
    end

    def label
      basename
    end

    def path
      path!
    end

    # Info

    def exist?
      ::File.exist? path
    end

    def basename
      @basename ||= ::File.basename(path)
    end

    def extname
      @extname ||= ::File.extname(path)
    end

    def channel?(medium)
      case medium
      when :video
        self.class.image?(extname) || self.class.movie?(extname)
      when :audio
        self.class.sound?(extname) || self.class.movie?(extname)
      end
    end

    def length(force=false)
      @duration = nil  if force
      return @duration  if @duration

      # NOTE first attempt
      @duration = probe(force)['format']['duration']
      @duration &&= @duration.to_f
      return @duration  if @duration

      # NOTE a harder try
      @duration = probe(true)['frames'].reduce(0) do |sum, frame|
        sum + frame['pkt_duration_time'].to_f
      end
    end

    def resolution
      v_stream = probe['streams'].first
      "#{v_stream['width']}x#{v_stream['height']}"
    end


    # Manipulation

    def read
      ::File.read path
    end
    def write(s)
      ::File.write path, s
    end

    def unlink
      if path.respond_to? :unlink
        path.unlink
      else
        FileUtils.remove_entry path
      end
      Ffmprb.logger.debug{"Removed file with path: #{path}"}
      @path = nil
    end

    private

    def path!
      (
        @path.respond_to?(:path)? @path.path : @path
      ).tap do |path|
        # TODO ensure readabilty/writability/readiness
        fail Error, "'#{path}' is un#{@mode.to_s[0..3]}able"  unless path && !path.empty?
      end
    end

    def probe(harder=false)
      return @probe  unless !@probe || harder
      cmd = ['-v', 'quiet', '-i', path, '-print_format', 'json', '-show_format', '-show_streams']
      cmd << '-show_frames'  if harder
      @probe = JSON.parse(Util::ffprobe *cmd).tap do |probe|
        fail Error, "This doesn't look like a ffprobable file"  unless probe['streams']
      end
    end

  end

end

require_relative 'file/sample'
require_relative 'file/threaded_buffered'
