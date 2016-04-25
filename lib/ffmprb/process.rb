module Ffmprb

  class Process
    include Util::ProcVis::Node

    class << self

      attr_accessor :duck_audio_volume_hi, :duck_audio_volume_lo,
        :duck_audio_silent_min
      attr_accessor :duck_audio_transition_length,
        :duck_audio_transition_in_start, :duck_audio_transition_out_start

      attr_accessor :input_video_auto_rotate
      attr_accessor :input_video_fps

      attr_accessor :output_video_resolution
      attr_accessor :output_video_fps
      attr_accessor :output_audio_encoder
      attr_accessor :output_audio_sampling_freq

      attr_accessor :timeout

      def intermediate_channel_extname(video:, audio:)
        if video
          if audio
            '.flv'  # TODO optimise this by using http://superuser.com/a/522853 or something
          else
            '.y4m'
          end
        else
          if audio
            '.wav'
          else
            fail Error, "I don't know how to channel [#{media.join ', '}]"
          end
        end
      end

      def input_video_options
        {
          auto_rotate: input_video_auto_rotate,
          fps: input_video_fps
        }
      end
      def input_audio_options
        {
        }
      end
      def output_video_options
        {
          fps: output_video_fps,
          resolution: output_video_resolution
        }
      end
      def output_audio_options
        {
          encoder: output_audio_encoder,
          sampling_freq: output_audio_sampling_freq
        }
      end

      # NOTE Temporarily, av_main_i/o and not a_main_i/o
      def duck_audio(av_main_i, a_overlay_i, silence, av_main_o,
        volume_lo: duck_audio_volume_lo,
        volume_hi: duck_audio_volume_hi,
        silent_min: duck_audio_silent_min,
        process_options: {},
        video:,  # NOTE Temporarily, video should not be here
        audio:
        )
        Ffmprb.process **process_options do

          in_main = input(av_main_i)
          in_over = input(a_overlay_i)
          output(av_main_o, video: video, audio: audio) do
            roll in_main

            ducked_overlay_volume = {0.0 => volume_lo}
            silence.each do |silent|
              next  if silent.end_at && silent.start_at && (silent.end_at - silent.start_at) < silent_min

              if silent.start_at
                transition_in_start = silent.start_at + Process.duck_audio_transition_in_start
                ducked_overlay_volume.merge!(
                  [transition_in_start, 0.0].max => volume_lo,
                  (transition_in_start + Process.duck_audio_transition_length) => volume_hi
                )
              end

              if silent.end_at
                transition_out_start = silent.end_at + Process.duck_audio_transition_out_start
                ducked_overlay_volume.merge!(
                  [transition_out_start, 0.0].max => volume_hi,
                  (transition_out_start + Process.duck_audio_transition_length) => volume_lo
                )
              end
            end
            overlay in_over.volume ducked_overlay_volume

            Ffmprb.logger.debug {
              volumes = ducked_overlay_volume.map{|t,v| "#{t}: #{v}"}.join ', '  unless Ffmprb.logger.level
              "Ducking audio with volumes: {#{volumes}}"
            }
          end

        end
      end

    end

    attr_accessor :timeout
    attr_accessor :name
    attr_reader :parent
    attr_accessor :ignore_broken_pipes

    def initialize(*args, **opts)
      self.timeout = opts.delete(:timeout) || Process.timeout
      @name = opts.delete(:name)
      @parent = opts.delete(:parent)
      parent.proc_vis_node self  if parent
      self.ignore_broken_pipes = opts.delete(:ignore_broken_pipes)
      Util.assert_options_empty! opts
      @inputs, @outputs = [], []
    end

    def input(io, video: true, audio: true)
      Input.new(io, self,
        video: channel_params(video, Process.input_video_options),
        audio: channel_params(audio, Process.input_audio_options)
      ).tap do |inp|
        fail Error, "Too many inputs to the process, try breaking it down somehow"  if @inputs.size > Util.ffmpeg_inputs_max
        @inputs << inp
        proc_vis_edge inp.io, self
      end
    end

    def input_label(input)
      @inputs.index input
    end

    def output(io, video: true, audio: true, &blk)
      Output.new(io, self,
        video: channel_params(video, Process.output_video_options),
        audio: channel_params(audio, Process.output_audio_options)
      ).tap do |outp|
        @outputs << outp
        proc_vis_edge self, outp.io
        outp.instance_exec &blk  if blk
      end
    end

    def output_index(output)
      @outputs.index output
    end

    # NOTE the one and the only entry-point processing function which spawns threads etc
    def run(limit: nil)  # TODO (async: false)
      # NOTE this is both for the future async: option and according to
      # the threading policy (a parent death will be noticed and handled by children)
      thr = Util::Thread.new main: !parent do
        proc_vis_node Thread.current
        # NOTE yes, an exception can occur anytime, and we'll just die, it's ok, see above
        # XXX just to return something -- no apparent practical use
        cmd = command
        opts = {limit: limit, timeout: timeout}
        opts[:ignore_broken_pipes] = ignore_broken_pipes  unless ignore_broken_pipes.nil?
        Util.ffmpeg(*cmd, **opts).tap do |res|
          Util::Thread.join_children! limit, timeout: timeout
        end
        proc_vis_node Thread.current, :remove
      end
      thr.value  if thr.join limit  # NOTE should not block for more than limit
    end

    private

    def command
      input_args + filter_args + output_args
    end

    def input_args
      filter_args  # NOTE must run first
      @input_args ||= @inputs.map(&:args).reduce(:+)
    end

    # NOTE must run first
    def filter_args
      @filter_args ||= Filter.complex_args(
        @outputs.map(&:filters).reduce(:+)
      )
    end

    def output_args
      filter_args  # NOTE must run first
      @output_args ||= @outputs.map(&:args).reduce(:+)
    end

    def channel_params(value, default)
      if value
        default.merge(value == true ? {} : value.to_h)
      elsif value != false
        {}
      end
    end
  end

end

require_relative 'process/input'
require_relative 'process/output'
