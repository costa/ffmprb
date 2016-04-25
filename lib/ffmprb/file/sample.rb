module Ffmprb

  class File

    def sample(
      at: 0.01,
      video: true,
      audio: true,
      &blk
    )
      audio = File.temp('.wav')  if audio == true
      video = File.temp('.png')  if video == true

      Ffmprb.logger.debug{"Snap shooting files, video path: #{video ? video.path : 'NONE'}, audio path: #{audio ? audio.path : 'NONE'}"}

      fail Error, "Incorrect output extname (must be image)"  unless !video || video.channel?(:video) && !video.channel?(:audio)
      fail Error, "Incorrect audio extname (must be sound)"  unless !audio || audio.channel?(:audio) && !audio.channel?(:video)
      fail Error, "Can sample either video OR audio UNLESS a block is given"  unless block_given? || !!audio != !!video

      cmd = %W[-i #{path}]
      cmd.concat %W[-deinterlace -an -ss #{at} -vframes 1 #{video.path}]  if video
      cmd.concat %W[-vn -ss #{at} -t 1 #{audio.path}]  if audio
      Util.ffmpeg *cmd

      return video || audio  unless block_given?

      begin
        yield *[video || nil, audio || nil].compact
      ensure
        begin
          video.unlink  if video
          audio.unlink  if audio
          Ffmprb.logger.debug{"Removed sample files"}
        rescue
          Ffmprb.logger.warn "#{$!.class.name} removing sample files: #{$!.message}"
        end
      end
    end
    def sample_video(*video, at: 0.01, &blk)
      sample at: at, video: (video.first || true), audio: false, &blk
    end
    def sample_audio(*audio, at: 0.01, &blk)
      sample at: at, video: false, audio: (audio.first || true), &blk
    end

  end

end
