module Ffmprb

  class Process

    class Output

      class << self

        # XXX check for unknown options

        def video_args(video=nil)
          video = Process.output_video_options.merge(video.to_h)
          [].tap do |args|
            encoder = pixel_format = nil  # NOTE ah, ruby
            args.concat %W[-c:v #{encoder}]  if (encoder = video.delete(:encoder))
            args.concat %W[-pix_fmt #{pixel_format}]  if (pixel_format = video.delete(:pixel_format))
            video.delete :resolution  # NOTE is handled otherwise
            video.delete :fps  # NOTE is handled otherwise
            Util.assert_options_empty! video
          end
        end

        def audio_args(audio=nil)
          audio = Process.output_audio_options.merge(audio.to_h)
          [].tap do |args|
            encoder = nil
            args.concat %W[-c:a #{encoder}]  if (encoder = audio.delete(:encoder))
            args.concat %W[-ar #{sampling_freq}]  if (sampling_freq = audio.delete(:sampling_freq))
            Util.assert_options_empty! audio
          end
        end

        def resolve(io)
          return io  unless io.is_a? String  # XXX XXX

          File.create(io).tap do |file|
            Ffmprb.logger.warn "Output file exists (#{file.path}), will probably overwrite"  if file.exist?
          end
        end

      end

      attr_reader :io
      attr_reader :process

      def initialize(io, process, video:, audio:)
        @io = self.class.resolve(io)
        @process = process
        @channels = {
          video: video && @io.channel?(:video) && OpenStruct.new(video),
          audio: audio && @io.channel?(:audio) && OpenStruct.new(audio)
        }
        if channel?(:video)
          channel(:video).resolution.to_s.split('x').each do |dim|
            fail Error, "Both dimensions of a resolution must be divisible by 2, sorry about that"  unless dim.to_i % 2 == 0
          end
        end
      end

      # XXX This method is exceptionally long at the moment. This is not too grand.
      # However, structuring the code should be undertaken with care, as not to harm the composition clarity.
      def filters
        fail Error, "Nothing to roll..."  unless @reels
        fail Error, "Supporting just full_screen for now, sorry."  unless @reels.all?(&:full_screen?)
        return @filters  if @filters

        idx = process.output_index(self)

        @filters = []

        # Concatting
        segments = []

        @reels.each_with_index do |curr_reel, i|

          lbl = nil

          if curr_reel.reel

            # NOTE mapping input to this lbl

            lbl = "o#{idx}rl#{i}"

            # NOTE Image-Padding to match the target resolution
            # TODO full screen only at the moment (see exception above)

            Ffmprb.logger.debug{"#{self} asking for filters of #{curr_reel.reel.io.inspect} video: #{channel(:video)}, audio: #{channel(:audio)}"}
            @filters.concat(
              curr_reel.reel.filters_for lbl, video: channel(:video), audio: channel(:audio)
            )
          end

          trim_prev_at = curr_reel.after || (curr_reel.transition && 0)
          transition_length = curr_reel.transition ? curr_reel.transition.length : 0

          if trim_prev_at

            # NOTE make sure previous reel rolls _long_ enough AND then _just_ enough

            prev_lbl = segments.pop

            lbl_pad = "bl#{prev_lbl}#{i}"
            # NOTE generously padding the previous segment to support for all the cases
            @filters.concat(
              Filter.blank_source trim_prev_at + transition_length,
              channel(:video).resolution, channel(:video).fps, "#{lbl_pad}:v"
            )  if channel?(:video)
            @filters.concat(
              Filter.silent_source trim_prev_at + transition_length, "#{lbl_pad}:a"
            )  if channel?(:audio)

            if prev_lbl
              lbl_aux = lbl_pad
              lbl_pad = "pd#{prev_lbl}#{i}"
              @filters.concat(
                Filter.concat_v ["#{prev_lbl}:v", "#{lbl_aux}:v"], "#{lbl_pad}:v"
              )  if channel?(:video)
              @filters.concat(
                Filter.concat_a ["#{prev_lbl}:a", "#{lbl_aux}:a"], "#{lbl_pad}:a"
              )  if channel?(:audio)
            end

            if curr_reel.transition

              # NOTE Split the previous segment for transition

              if trim_prev_at > 0
                @filters.concat(
                  Filter.split "#{lbl_pad}:v", ["#{lbl_pad}a:v", "#{lbl_pad}b:v"]
                )  if channel?(:video)
                @filters.concat(
                  Filter.asplit "#{lbl_pad}:a", ["#{lbl_pad}a:a", "#{lbl_pad}b:a"]
                )  if channel?(:audio)
                lbl_pad, lbl_pad_ = "#{lbl_pad}a", "#{lbl_pad}b"
              else
                lbl_pad, lbl_pad_ = nil, lbl_pad
              end
            end

            if lbl_pad

              # NOTE Trim the previous segment finally

              new_prev_lbl = "tm#{prev_lbl}#{i}a"

              @filters.concat(
                Filter.trim 0, trim_prev_at, "#{lbl_pad}:v", "#{new_prev_lbl}:v"
              )  if channel?(:video)
              @filters.concat(
                Filter.atrim 0, trim_prev_at, "#{lbl_pad}:a", "#{new_prev_lbl}:a"
              )  if channel?(:audio)

              segments << new_prev_lbl
              Ffmprb.logger.debug{"Concatting segments: #{new_prev_lbl} pushed"}
            end

            if curr_reel.transition

              # NOTE snip the end of the previous segment and combine with this reel

              lbl_end1 = "o#{idx}tm#{i}b"
              lbl_reel = "o#{idx}tn#{i}"

              if !lbl  # no reel
                lbl_aux = "o#{idx}bk#{i}"
                @filters.concat(
                  Filter.blank_source transition_length, channel(:video).resolution, channel(:video).fps, "#{lbl_aux}:v"
                )  if channel?(:video)
                @filters.concat(
                  Filter.silent_source transition_length, "#{lbl_aux}:a"
                )  if channel?(:audio)
              end  # NOTE else hope lbl is long enough for the transition

              @filters.concat(
                Filter.trim trim_prev_at, trim_prev_at + transition_length, "#{lbl_pad_}:v", "#{lbl_end1}:v"
              )  if channel?(:video)
              @filters.concat(
                Filter.atrim trim_prev_at, trim_prev_at + transition_length, "#{lbl_pad_}:a", "#{lbl_end1}:a"
              )  if channel?(:audio)

              # TODO the only supported transition, see #*lay
              @filters.concat(
                Filter.blend_v transition_length, channel(:video).resolution, channel(:video).fps, ["#{lbl_end1}:v", "#{lbl || lbl_aux}:v"], "#{lbl_reel}:v"
              ) if channel?(:video)
              @filters.concat(
                Filter.blend_a transition_length, ["#{lbl_end1}:a", "#{lbl || lbl_aux}:a"], "#{lbl_reel}:a"
              ) if channel?(:audio)

              lbl = lbl_reel
            end

          end

          segments << lbl  # NOTE can be nil
        end

        segments.compact!

        lbl_out = segments[0]

        if segments.size > 1
          lbl_out = "o#{idx}o"

          @filters.concat(
            Filter.concat_v segments.map{|s| "#{s}:v"}, "#{lbl_out}:v"
          )  if channel?(:video)
          @filters.concat(
            Filter.concat_a segments.map{|s| "#{s}:a"}, "#{lbl_out}:a"
          )  if channel?(:audio)
        end

        # Overlays

        # NOTE in-process overlays first

        @overlays.to_a.each_with_index do |over_reel, i|
          next  if over_reel.duck  # NOTE this is currently a single case of multi-process... process

          fail Error, "Video overlays are not implemented just yet, sorry..."  if over_reel.reel.channel?(:video)

          # Audio overlaying

          lbl_nxt = "o#{idx}o#{i}"

          lbl_over = "o#{idx}l#{i}"
          @filters.concat(  # NOTE audio only, see above
            over_reel.reel.filters_for lbl_over, video: false, audio: channel(:audio)
          )
          @filters.concat(
            Filter.copy "#{lbl_out}:v", "#{lbl_nxt}:v"
          )  if channel?(:video)
          @filters.concat(
            Filter.amix_to_first_same_volume ["#{lbl_out}:a", "#{lbl_over}:a"], "#{lbl_nxt}:a"
          )  if channel?(:audio)

          lbl_out = lbl_nxt
        end

        # NOTE multi-process overlays last

        @channel_lbl_ios = {}  # XXX this is a spaghetti machine
        @channel_lbl_ios["#{lbl_out}:v"] = io  if channel?(:video)
        @channel_lbl_ios["#{lbl_out}:a"] = io  if channel?(:audio)

        # TODO supporting just "full" overlays for now, see exception in #add_reel
        @overlays.to_a.each_with_index do |over_reel, i|

          # NOTE this is currently a single case of multi-process... process
          if over_reel.duck
            fail Error, "Don't know how to duck video... yet"  if over_reel.duck != :audio

            Ffmprb.logger.info "ATTENTION: ducking audio (due to the absence of a simple ffmpeg filter) does not support streaming main input. yet."

            # So ducking just audio here, ye?
            # XXX check if we're on audio channel

            main_av_o = @channel_lbl_ios["#{lbl_out}:a"]
            fail Error, "Main output does not contain audio to duck"  unless main_av_o

            intermediate_extname = Process.intermediate_channel_extname video: main_av_o.channel?(:video), audio: main_av_o.channel?(:audio)
            main_av_inter_i, main_av_inter_o = File.threaded_buffered_fifo(intermediate_extname, reader_open_on_writer_idle_limit: Util::ThreadedIoBuffer.timeout * 2, proc_vis: process)
            @channel_lbl_ios.each do |channel_lbl, io|
              @channel_lbl_ios[channel_lbl] = main_av_inter_i  if io == main_av_o  # XXX ~~~spaghetti
            end
            process.proc_vis_edge process, main_av_o, :remove
            process.proc_vis_edge process, main_av_inter_i
            Ffmprb.logger.debug{"Re-routed the main audio output (#{main_av_inter_i.path}->...->#{main_av_o.path}) through the process of audio ducking"}

            over_a_i, over_a_o = File.threaded_buffered_fifo(Process.intermediate_channel_extname(audio: true, video: false), proc_vis: process)
            lbl_over = "o#{idx}l#{i}"
            @filters.concat(
              over_reel.reel.filters_for lbl_over, video: false, audio: channel(:audio)
            )
            @channel_lbl_ios["#{lbl_over}:a"] = over_a_i
            process.proc_vis_edge process, over_a_i
            Ffmprb.logger.debug{"Routed and buffering auxiliary output fifos (#{over_a_i.path}>#{over_a_o.path}) for overlay"}

            inter_i, inter_o = File.threaded_buffered_fifo(intermediate_extname, proc_vis: process)
            Ffmprb.logger.debug{"Allocated fifos to buffer media (#{inter_i.path}>#{inter_o.path}) while finding silence"}

            ignore_broken_pipes_was = process.ignore_broken_pipes  # XXX maybe throw an exception instead?
            process.ignore_broken_pipes = true  # NOTE audio ducking process may break the overlay pipe

            Util::Thread.new "audio ducking" do
              process.proc_vis_edge main_av_inter_o, inter_i  # XXX mark it better
              silence = Ffmprb.find_silence(main_av_inter_o, inter_i)

              Ffmprb.logger.debug{
                silence_map = silence.map{|s| "#{s.start_at}-#{s.end_at}"}
                "Audio ducking with silence: [#{silence_map.join ', '}]"
              }

              Process.duck_audio inter_o, over_a_o, silence, main_av_o,
                process_options: {parent: process, ignore_broken_pipes: ignore_broken_pipes_was, timeout: process.timeout},
                video: channel(:video), audio: channel(:audio)
            end
          end

        end

        @filters
      end

      def args
        fail Error, "Must generate filters first."  unless @channel_lbl_ios

        [].tap do |args|
          io_channel_lbls = {}  # XXX ~~~spaghetti
          @channel_lbl_ios.each do |channel_lbl, io|
            (io_channel_lbls[io] ||= []) << channel_lbl
          end
          io_channel_lbls.each do |io, channel_lbls|
            channel_lbls.each do |channel_lbl|
              args.concat ['-map', "[#{channel_lbl}]"]
            end
            args.concat self.class.video_args(channel :video)  if channel? :video
            args.concat self.class.audio_args(channel :audio)  if channel? :audio
            args << io.path
          end
        end
      end

      def input(io, video: true, audio: true)
        process.input io, video: video, audio: audio
      end

      def roll(
        reel,
        onto: :full_screen,
        after: nil,
        transition: nil
      )
        fail Error, "Nothing to roll..."  unless reel
        fail Error, "Supporting :transition with :after only at the moment, sorry."  unless
          !transition || after || @reels.to_a.empty?

        add_reel reel, after, transition, (onto == :full_screen)
      end
      alias :lay :roll

      def overlay(
        reel,
        at: 0,
        duck: nil
      )
        fail Error, "Nothing to overlay..."  unless reel
        fail Error, "Nothing to lay over yet..."  if @reels.to_a.empty?
        fail Error, "Ducking overlays should come last... for now"  if !duck && @overlays.to_a.last && @overlays.to_a.last.duck

        add_snip reel, at, duck
      end

      def channel(medium)
        @channels[medium]
      end

      def channel?(medium)
        !!channel(medium)
      end

      private

      def reels_channel?(medium)
        @reels.to_a.all?{|r| !r.reel || r.reel.channel?(medium)}
      end

      def add_reel(reel, after, transition, full_screen)
        fail Error, "No time to roll..."  if after && after.to_f <= 0
        fail Error, "Partial (not coming last in process) overlays are currently unsupported, sorry."  unless @overlays.to_a.empty?

        # NOTE limited functionality: transition = {effect => duration}
        # TODO temporary obviously, see rendering
        trans =
          if transition
            fail "Unsupported (yet) transition, sorry."  unless
              transition.size == 1 && transition[:blend]
            OpenStruct.new length: transition[:blend].to_f
          end

        (@reels ||= []) <<
          OpenStruct.new(reel: reel, after: after, transition: trans, full_screen?: full_screen)
      end

      def add_snip(reel, at, duck)
        (@overlays ||= []) <<
          OpenStruct.new(reel: reel, at: at, duck: duck)
      end

    end

  end

end
