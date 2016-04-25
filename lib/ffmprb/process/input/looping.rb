module Ffmprb

  class Process

    class Input

      def loop(times=Util.ffmpeg_inputs_max)
        Ffmprb.logger.warn "Looping more than #{Util.ffmpeg_inputs_max} times is 'unstable': either use double looping or ask for this feature"  if times > Util.ffmpeg_inputs_max
        Looping.new self, times
      end

      class Looping < ChainBase

        attr_reader :times

        def initialize(unfiltered, times)
          super unfiltered

          @times = times

          @raw = @_unfiltered = unfiltered
          # NOTE find the actual input io (not a filter)
          @raw = @raw.unfiltered  while @raw.respond_to? :unfiltered
        end

        def filters_for(lbl, video:, audio:)

          # The plan:
          # 1) Create and route an aux input which would hold the filtered, looped and parameterised stream off the raw input (keep the raw input)
          # 2) Tee+buffer the original raw input io: one stream goes back into the process throw the raw input io replacement fifo; the other is fed into the filtering process
          # 3) Which uses the same underlying filters to produce a filtered and parameterised stream, which is fed into the looping process through a N-Tee+buffer
          # 4) Invoke the looping process which just concatenates its N inputs and produces the new raw input (the aux input)

          # Looping
          # NOTE all the processing is done before looping

          aux_input(video: video, audio: audio).filters_for lbl,
            video: video && OpenStruct.new, audio: audio && OpenStruct.new
        end

        protected

        def aux_input(video:, audio:)

          # NOTE (2)
          # NOTE replace the raw input io with a copy io, getting original fifo/file
          intermediate_extname = Process.intermediate_channel_extname(video: @raw.io.channel?(:video), audio: @raw.io.channel?(:audio))
          src_io = @raw.temporise_io!(intermediate_extname)
          if src_io.extname != intermediate_extname  # NOTE kinda like src_io is not suitable for piping
            meh_src_io, src_io = src_io, File.temp_fifo(intermediate_extname)
            Util::Thread.new "source converter" do
              Ffmprb.process do

                inp = input(meh_src_io)
                output(src_io, video: nil, audio: nil) do  # XXX this is not properly tested, unfortunately
                  lay inp
                end

              end
            end
          end
          cpy_io = File.temp_fifo(src_io.extname)
          Ffmprb.logger.debug{"(L2) Temporising the raw input (#{src_io.path}) and creating copy (#{cpy_io.path})"}

          src_io.threaded_buffered_copy_to @raw.io, cpy_io

          # NOTE (3)
          # NOTE preprocessed and filtered fifo
          dst_io = File.temp_fifo(intermediate_extname)
          @raw.process.proc_vis_node dst_io

          Util::Thread.new "looping input processor" do
            # Ffmprb.logger.debug{"Processing before looping"}

            Ffmprb.logger.debug{"(L3) Pre-processing into (#{dst_io.path})"}
            Ffmprb.process @_unfiltered, parent: @raw.process do |unfiltered|  # TODO limit:

              inp = input(cpy_io)
              output(dst_io, video: video, audio: audio) do
                lay inp.copy(unfiltered)
              end

            end
          end

          buff_ios = (1..times).map{File.temp_fifo intermediate_extname}
          Ffmprb.logger.debug{"Preprocessed #{dst_io.path} will be teed to #{buff_ios.map(&:path).join '; '}"}
          Util::Thread.new "cloning buffer watcher" do
            dst_io.threaded_buffered_copy_to(*buff_ios).tap do |io_buff|
              Util::Thread.join_children!
              Ffmprb.logger.warn "Looping  ~from #{src_io.path} finished before its consumer: if you just wanted to loop input #{Util.ffmpeg_inputs_max} times, that's fine, but if you expected it to loop indefinitely... #{Util.ffmpeg_inputs_max} is the maximum #loop can do at the moment, and it may just not be enough in this case (workaround by concatting or file a complaint at #{Ffmprb::GEM_GITHUB_URL}/issues please)."  if times == Util.ffmpeg_inputs_max && io_buff.stats.blocks_buff == 0
            end
          end

          Ffmprb.logger.debug{"Concatenation of #{buff_ios.map(&:path).join '; '} will go to #{@io.io.path} to be fed to this process"}

          # NOTE additional (filtered, processed and looped) input io
          aux_io = File.temp_fifo(intermediate_extname)

          # NOTE (4)

          Util::Thread.new "looper" do
            Ffmprb.logger.debug{"Looping #{buff_ios.size} times"}

            Ffmprb.logger.debug{"(L4) Looping (#{buff_ios.map &:path}) into (#{aux_io.path})"}
            begin  # NOTE may not write its entire output, it's ok
              Ffmprb.process parent: @raw.process, ignore_broken_pipes: false do

                ins = buff_ios.map{ |i| input i }
                output(aux_io, video: nil, audio: nil) do
                  ins.each{ |i| lay i }
                end

              end
            rescue Util::BrokenPipeError
              looping_max = false  # NOTE see the above warning
            end
          end

          # NOTE (1)

          Ffmprb.logger.debug{"(L1) Creating a new input (#{aux_io.path}) to the process"}
          @raw.process.input(aux_io)
        end

      end

    end

  end

end
