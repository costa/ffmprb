module Ffmprb

  class << self

    # NOTE not for streaming just yet
    def find_silence(input_file, output_file)
      logger.debug {
        path = "#{input_file.path}->#{output_file.path}"
        "Finding silence (#{path})"
      }
      [].tap do |silence|
        Util.ffmpeg('-i', input_file.path, *find_silence_detect_args, output_file.path).
          scan(SILENCE_DETECT_REGEX).each do |mark, time|
          time = time.to_f

          case mark
          when 'start'
            silence << OpenStruct.new(start_at: time)
          when 'end'
            if silence.empty?
              silence << OpenStruct.new(start_at: 0.0, end_at: time)
            else
              fail Error, "ffmpeg is being stupid: silence_end with no silence_start"  if silence.last.end_at
              silence.last.end_at = time
            end
          else
            Ffmprb.warn "Unknown silence mark: #{mark}"
          end
        end
        logger.debug {
          path = "#{input_file.path}->#{output_file.path}"
          silence.map{|t,v| "#{t}: #{v}"}
          "Found silence (#{path}): [#{silence_res}]"
        }
      end
    end

    private

    SILENCE_DETECT_REGEX = /\[silencedetect\s.*\]\s*silence_(\w+):\s*(\d+\.?\d*)/

    def find_silence_detect_args
      Filter.complex_args Filter.silencedetect
    end

  end

end
