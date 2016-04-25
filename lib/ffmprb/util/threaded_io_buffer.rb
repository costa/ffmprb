require 'ostruct'

module Ffmprb

  module Util

    # TODO the events mechanism is currently unused (and commented out) => synchro mechanism not needed
    class ThreadedIoBuffer
      # XXX include Synchro
      include ProcVis::Node

      class << self

        attr_accessor :blocks_max
        attr_accessor :block_size
        attr_accessor :timeout
        attr_accessor :timeout_limit
        attr_accessor :io_wait_timeout

      end


      attr_reader :stats


      # NOTE input/output can be lambdas for single asynchronic io evaluation
      #      the lambdas must be timeout-interrupt-safe (since they are wrapped in timeout blocks)
      # NOTE all ios are being opened and closed as soon as possible
      def initialize(input, *outputs, keep_outputs_open_on_input_idle_limit: nil)
        super()  # NOTE for the monitor, apparently

        Ffmprb.logger.debug{"ThreadedIoBuffer initializing with (#{ThreadedIoBuffer.blocks_max}x#{ThreadedIoBuffer.block_size})"}

        @input = input
        @outputs = outputs.map do |outp|
          OpenStruct.new _io: outp, q: SizedQueue.new(ThreadedIoBuffer.blocks_max)
        end
        @stats = Stats.new(self)
        @keep_outputs_open_on_input_idle_limit = keep_outputs_open_on_input_idle_limit
        # @events = {}

        Thread.new "io buffer main" do
          init_reader!
          @outputs.each do |output|
            init_writer_output! output
            init_writer! output
          end

          Thread.join_children!.tap do
            Ffmprb.logger.debug{"ThreadedIoBuffer (#{@input.path}->#{@outputs.map(&:io).map(&:path)}) terminated successfully (#{stats})"}
          end
        end
      end
      #
      # def once(event, &blk)
      #   event = event.to_sym
      #   wait_for_handler!
      #   if @events[event].respond_to? :call
      #     fail Error, "Once upon a time (one #once(event) at a time) please"
      #   elsif @events[event]
      #     Ffmprb.logger.debug{"ThreadedIoBuffer (post-)reacting to #{event}"}
      #     @handler_thr = Util::Thread.new "#{event} handler", &blk
      #   else
      #     Ffmprb.logger.debug{"ThreadedIoBuffer subscribing to #{event}"}
      #     @events[event] = blk
      #   end
      # end
      # handle_synchronously :once
      #
      # def reader_done!
      #   Ffmprb.logger.debug{"ThreadedIoBuffer reader terminated (#{stats})"}
      #   fire! :reader_done
      # end
      #
      # def terminated!
      #   fire! :terminated
      # end
      #
      # def timeout!
      #   fire! :timeout
      # end

      # protected
      #
      # def fire!(event)
      #   wait_for_handler!
      #   Ffmprb.logger.debug{"ThreadedIoBuffer firing #{event}"}
      #   if blk = @events.to_h[event.to_sym]
      #     @handler_thr = Util::Thread.new "#{event} handler", &blk
      #   end
      #   @events[event.to_sym] = true
      # end
      # handle_synchronously :fire!
      #

      def label
        "IObuff: Curr/Peak/Max=#{stats.blocks_buff}/#{stats.blocks_max}/#{ThreadedIoBuffer.blocks_max} In/Out=#{stats.bytes_in}/#{stats.bytes_out}"
      end

      private

      class AllOutputsBrokenError < Error
      end

      def reader_input!  # NOTE just for reader thread
        if @input.respond_to?(:call)
          Ffmprb.logger.debug{"Opening buffer input"}
          @input = @input.call
          Ffmprb.logger.debug{"Opened buffer input: #{@input.path}"}
        end
        @input
      end

      # NOTE to be called after #init_writer_output! only
      def writer_output!(output)  # NOTE just for writer thread
        if output.thr
          output.thr.join
          output.thr = nil
        end
        output.io
      end

      # NOTE reads roughly as much input as writers can write, then closes the stream; times out on buffer overflow
      def init_reader!
        Thread.new("buffer reader") do
          begin
            input_io = reader_input!
            loop do  # NOTE until EOFError, see below
              s = ''
              while s.length < ThreadedIoBuffer.block_size
                timeouts = 0
                logged_timeouts = 1
                begin
                  ss = input_io.read_nonblock(ThreadedIoBuffer.block_size - s.length)
                  stats.add_bytes_in ss.length
                  s += ss
                rescue IO::WaitReadable
                  if @keep_outputs_open_on_input_idle_limit && stats.bytes_in > 0 && stats.blocks_buff == 0 && timeouts * ThreadedIoBuffer.io_wait_timeout > @keep_outputs_open_on_input_idle_limit
                    if s.length > 0  # NOTE let's see if it helps outputting an incomplete block
                      Ffmprb.logger.debug{"ThreadedIoBuffer reader (from #{input_io.path}) giving a chance to write #{s.length}/#{ThreadedIoBuffer.block_size}b after waiting >#{@keep_outputs_open_on_input_idle_limit}s, after reading #{stats.bytes_in}b"}
                      break
                    else
                      Ffmprb.logger.debug{"ThreadedIoBuffer reader (from #{input_io.path}) giving up after waiting >#{@keep_outputs_open_on_input_idle_limit}s, after reading #{stats.bytes_in}b, closing outputs"}
                      raise EOFError
                    end
                  else
                    Thread.current.live!
                    timeouts += 1
                    if timeouts > 2 * logged_timeouts
                      Ffmprb.logger.debug{"ThreadedIoBuffer reader (from #{input_io.path}) retrying... (#{timeouts} reads): #{$!.class}"}
                      logged_timeouts = timeouts
                    end
                    IO.select [input_io], nil, nil, ThreadedIoBuffer.io_wait_timeout
                    retry
                  end
                rescue EOFError
                  output_enq! s
                  raise
                rescue IO::WaitWritable  # NOTE should not really happen, so just for conformance
                  Ffmprb.logger.error "ThreadedIoBuffer reader (from #{input_io.path}) gets a #{$!} - should not really happen."
                  IO.select nil, [input_io], nil, ThreadedIoBuffer.io_wait_timeout
                  retry
                end
              end
              output_enq! s
            end
          rescue EOFError
            Ffmprb.logger.debug{"ThreadedIoBuffer reader (from #{input_io.path}) breaking off"}
          rescue AllOutputsBrokenError
            Ffmprb.logger.info "All outputs broken"
          rescue Exception
            @reader_failed = Error.new("Reader failed: #{$!}")
            raise
          ensure
            begin
              output_enq! nil  # NOTE EOF signal
            rescue
            end
            begin
              input_io.close  if input_io.respond_to?(:close)
            rescue
              Ffmprb.logger.error "#{$!.class.name} closing ThreadedIoBuffer input: #{$!.message}"
            end
            # reader_done!
            Ffmprb.logger.debug{"ThreadedIoBuffer reader terminated (#{stats})"}
          end
        end
      end

      def init_writer_output!(output)
        return output.io = output._io  unless output._io.respond_to?(:call)

        output.thr = Thread.new("buffer writer output helper") do
          Ffmprb.logger.debug{"Opening buffer output"}
          output.io =
            Thread.timeout_or_live nil, log: "in the buffer writer helper thread", timeout: ThreadedIoBuffer.timeout do |time|
              fail Error, "giving up buffer writer init since the reader has failed (#{@reader_failed.message})"  if @reader_failed
              output._io.call
            end
          Ffmprb.logger.debug{"Opened buffer output: #{output.io.path}"}
        end
      end

      # NOTE writes as much output as possible, then terminates when the reader dies
      def init_writer!(output)
        Thread.new("buffer writer") do
          begin
            output_io = writer_output!(output)
            while s = output_deq!(output)  # NOTE until EOF signal
              timeouts = 0
              logged_timeouts = 1
              begin
                fail @reader_failed  if @reader_failed  # NOTE otherwise, output_io should not be nil
                written = output_io.write_nonblock(s)
                stats.add_bytes_out written

                if written != s.length
                  s = s[written..-1]
                  raise IO::EAGAINWaitWritable
                end

              rescue IO::WaitWritable
                Thread.current.live!
                timeouts += 1
                if timeouts > 2 * logged_timeouts
                  Ffmprb.logger.debug{"ThreadedIoBuffer writer (to #{output_io.path}) retrying... (#{timeouts} writes): #{$!.class}"}
                  logged_timeouts = timeouts
                end
                IO.select nil, [output_io], nil, ThreadedIoBuffer.io_wait_timeout
                retry
              rescue IO::WaitReadable  # NOTE should not really happen, so just for conformance
                Ffmprb.logger.error "ThreadedIoBuffer writer (to #{output_io.path}) gets a #{$!} - should not really happen."
                IO.select [output_io], nil, ThreadedIoBuffer.io_wait_timeout
                retry
              end
            end
            Ffmprb.logger.debug{"ThreadedIoBuffer writer (to #{output_io.path}) breaking off"}
          rescue Errno::EPIPE
            Ffmprb.logger.debug{"ThreadedIoBuffer writer (to #{output_io.path}) broken"}
            output.broken = true
          ensure
            # terminated!
            begin
              output_io.close  if !output.broken && output_io && output_io.respond_to?(:close)
            rescue
              Ffmprb.logger.error "#{$!.class.name} closing ThreadedIoBuffer output: #{$!.message}"
            end
            output.broken = true
            Ffmprb.logger.debug{"ThreadedIoBuffer writer (to #{output_io && output_io.path}) terminated (#{stats})"}
          end
        end
      end
      #
      # def wait_for_handler!
      #   @handler_thr.join  if @handler_thr
      #   @handler_thr = nil
      # end

      def output_enq!(item)
        fail AllOutputsBrokenError  if
          @outputs.select do |output|
            next  if output.broken

            timeouts = 0
            logged_timeouts = 1
            begin
              # NOTE let's assume there's no race condition here between the possible timeout exception and enq
              Timeout.timeout(ThreadedIoBuffer.timeout) do
                output.q.enq item
              end
              stats.blocks_for output

            rescue Timeout::Error
              next  if output.broken

              timeouts += 1
              if timeouts == 2 * logged_timeouts
                Ffmprb.logger.warn "A little bit of timeout (>#{timeouts*ThreadedIoBuffer.timeout}s idle) with #{ThreadedIoBuffer.blocks_max}x#{ThreadedIoBuffer.block_size}b blocks (buffering #{reader_input!.path}->...; #{@outputs.reject(&:io).size}/#{@outputs.size} unopen/total)"
                logged_timeouts = timeouts
              end

              retry  unless timeouts >= ThreadedIoBuffer.timeout_limit # NOTE the queue has probably overflown

              @reader_failed ||= Error.new("the writer has failed with timeout limit while queuing")  # NOTE screw the race condition
              # timeout!
              fail Error, "Looks like we're stuck (>#{ThreadedIoBuffer.timeout_limit*ThreadedIoBuffer.timeout}s idle) with #{ThreadedIoBuffer.blocks_max}x#{ThreadedIoBuffer.block_size}b blocks (buffering #{reader_input!.path}->...)..."
            end
        end.empty?
      end

      def output_deq!(outp)
        outp.q.deq.tap do
          stats.blocks_for outp
        end
      end

      class Stats < OpenStruct
        include MonitorMixin

        def initialize(proc)
          @proc = proc
          @output_blocks = {}
          super blocks_buff: 0, blocks_max: 0, bytes_in: 0, bytes_out: 0
        end

        def add_bytes_in(n)
          synchronize do
            self.bytes_in += n
            @proc.proc_vis_node @proc  # NOTE update
          end
        end

        def add_bytes_out(n)
          synchronize do
            self.bytes_out += n
            @proc.proc_vis_node @proc  # NOTE update
          end
        end

        def blocks_for(outp)
          synchronize do
            blocks = @output_blocks[outp.object_id] = outp.q.length
            if blocks > blocks_max
              self.blocks_max = blocks
              @proc.proc_vis_node @proc  # NOTE update
            end
            self.blocks_buff = @output_blocks.values.reduce(0, :+)
          end
        end

      end

    end

  end

end
