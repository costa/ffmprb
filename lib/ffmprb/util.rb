require 'open3'

module Ffmprb

  class Error < StandardError; end

  module Util

    class BrokenPipeError < Error; end
    class TimeLimitError < Error; end

    class << self

      attr_accessor :ffmpeg_cmd, :ffmpeg_inputs_max, :ffprobe_cmd
      attr_accessor :cmd_timeout

      def ffprobe(*args, limit: nil, timeout: cmd_timeout)
        sh *ffprobe_cmd, *args, limit: limit, timeout: timeout
      end

      def ffmpeg(*args, limit: nil, timeout: cmd_timeout, ignore_broken_pipes: true)
        args = ['-loglevel', 'debug'] + args  if Ffmprb.ffmpeg_debug
        sh *ffmpeg_cmd, *args, output: :stderr, limit: limit, timeout: timeout, ignore_broken_pipes: ignore_broken_pipes
      end

      def sh(*cmd, input: nil, output: :stdout, limit: nil, timeout: cmd_timeout, ignore_broken_pipes: false)
        cmd = cmd.map &:to_s  unless cmd.size == 1
        cmd_str = cmd.size != 1 ? cmd.map{|c| sh_escape c}.join(' ') : cmd.first
        timeout = [timeout, limit].compact.min
        thr = Thread.new "`#{cmd_str}`" do
          Ffmprb.logger.info "Popening `#{cmd_str}`..."
          Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
            begin
              stdin.write input  if input
              stdin.close

              log_cmd = cmd.first.upcase
              stdout_r = Reader.new(stdout, store: output == :stdout, log_with: log_cmd)
              stderr_r = Reader.new(stderr, store: true, log_with: log_cmd, log_as: output == :stderr && Logger::DEBUG || Logger::INFO)

              Thread.timeout_or_live(limit, log: "while waiting for `#{cmd_str}`", timeout: timeout) do |time|
                value = wait_thr.value
                status = value.exitstatus  # NOTE blocking
                if status != 0
                  if value.signaled? && value.termsig == Signal.list['PIPE']
                    if ignore_broken_pipes
                      Ffmprb.logger.info "Ignoring broken pipe: #{cmd_str}"
                    else
                      fail BrokenPipeError, cmd_str
                    end
                  else
                    status ||= "sig##{value.termsig}"
                    fail Error, "#{cmd_str} (#{status}):\n#{stderr_r.read}"
                  end
                end
              end
              Ffmprb.logger.debug{"FINISHED: #{cmd_str}"}

              Thread.join_children! limit, timeout: timeout

              # NOTE only one of them will return non-nil, see above
              stdout_r.read || stderr_r.read
            ensure
              process_dead! wait_thr, cmd_str, limit
            end
          end
        end
        thr.value
      end

      def assert_options_empty!(opts)
        fail ArgumentError, "Unknown options: #{opts}"  unless opts.empty?
      end
      protected

      # NOTE a best guess kinda method
      def sh_escape(str)
        if str !~ /^[a-z0-9\/.:_-]*$/i && str !~ /"/
          "\"#{str}\""
        else
          str
        end
      end

      def process_dead!(wait_thr, cmd_str, limit)
        grace = limit ? limit/4 : 1
        return  unless wait_thr.alive?

        # NOTE a simplistic attempt to gracefully terminate a child process
        # the successful completion is via exception...
        begin
          Ffmprb.logger.info "Sorry it came to this, but I'm terminating `#{cmd_str}`(#{wait_thr.pid})..."
          ::Process.kill 'TERM', wait_thr.pid
          sleep grace
          Ffmprb.logger.info "Very sorry it came to this, but I'm terminating `#{cmd_str}`(#{wait_thr.pid}) again..."
          ::Process.kill 'TERM', wait_thr.pid
          sleep grace
          Ffmprb.logger.warn "Die `#{cmd_str}`(#{wait_thr.pid}), die!.. (killing amok)"
          ::Process.kill 'KILL', wait_thr.pid
          sleep grace
          Ffmprb.logger.warn "Checking if `#{cmd_str}`(#{wait_thr.pid}) finally dead..."
          ::Process.kill 0, wait_thr.pid
          Ffmprb.logger.error "Still alive -- `#{cmd_str}`(#{wait_thr.pid}), giving up..."
        rescue Errno::ESRCH
          Ffmprb.logger.info "Apparently `#{cmd_str}`(#{wait_thr.pid}) is dead..."
        end

        fail Error, "System error or something: waiting for the thread running `#{cmd_str}`(#{wait_thr.pid})..." unless
          wait_thr.join limit
      end

    end


    class Reader < Thread

      def initialize(input, store: false, log_with: nil, log_as: Logger::DEBUG)
        @output = ''
        @queue = Queue.new
        super "reader" do
          begin
            while s = input.gets
              Ffmprb.logger.log log_as, "#{log_with}: #{s.chomp}"  if log_with
              @output << s  if store
            end
            @queue.enq @output
          rescue Exception
            @queue.enq Error.new("Exception in a reader thread")
          end
        end
      end

      def read
        case res = @queue.deq
        when Exception
          fail res
        when ''
          nil
        else
          res
        end
      end

    end

  end

end

# require 'ffmprb/util/synchro'
require_relative 'util/proc_vis'
require_relative 'util/thread'
require_relative 'util/threaded_io_buffer'
