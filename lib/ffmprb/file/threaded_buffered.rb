module Ffmprb

  class File  # NOTE I would rather rename it to Stream at the moment

    class << self

      def threaded_buffered_fifo(extname='.tmp', reader_open_on_writer_idle_limit: nil, proc_vis: nil)
        input_fifo_file = temp_fifo(extname)
        output_fifo_file = temp_fifo(extname)
        Ffmprb.logger.debug{"Opening #{input_fifo_file.path}>#{output_fifo_file.path} for buffering"}
        Util::Thread.new do
          begin
            io_buff = Util::ThreadedIoBuffer.new(opener(input_fifo_file, 'r'), opener(output_fifo_file, 'w'), keep_outputs_open_on_input_idle_limit: reader_open_on_writer_idle_limit)
            if proc_vis
              proc_vis.proc_vis_edge input_fifo_file, io_buff
              proc_vis.proc_vis_edge io_buff, output_fifo_file
            end
            begin
              # yield input_fifo_file, output_fifo_file, io_buff  if block_given?
            ensure
              Util::Thread.join_children!
            end
            Ffmprb.logger.debug{"IoBuffering from #{input_fifo_file.path} to #{output_fifo_file.path} ended"}
          ensure
            input_fifo_file.unlink  if input_fifo_file
            output_fifo_file.unlink  if output_fifo_file
          end
        end
        Ffmprb.logger.debug{"IoBuffering from #{input_fifo_file.path} to #{output_fifo_file.path} started"}

        [input_fifo_file, output_fifo_file]
      end

    end

    def threaded_buffered_copy_to(*dsts)
      Util::ThreadedIoBuffer.new(
        self.class.opener(self, 'r'),
        *dsts.map{|io| self.class.opener io, 'w'}
      ).tap do |io_buff|
        proc_vis_edge self, io_buff
        dsts.each{ |dst| proc_vis_edge io_buff, dst }
      end
    end

  end

end
