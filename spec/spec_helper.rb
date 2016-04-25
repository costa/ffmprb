require 'simplecov'
SimpleCov.start

require 'byebug'
$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'ffmprb'

RSpec.configure do |config|

  # NOTE generated media files

  # XXX https://github.com/rspec/rspec-core/issues/1031#issuecomment-121144883
  # the workaround/microgem doesn't work this far
  # config.around :all do |example|

  config.before :all do
    @sample_files = []
    @sample_files << (@av_file_c_gor_9 = Ffmprb::File.temp('.mp4'))
    Ffmprb::Util.ffmpeg *Ffmprb::Filter.complex_args('color=red:r=60:d=9:s=320x240 [red]', 'color=green:r=60:d=9:s=280x200 [green]', '[red] [green] overlay=20:20', "sine=#{NOTES.C6}:d=9"), *Ffmprb::Process::Output.audio_args, @av_file_c_gor_9.path
    @sample_files << (@av_file_e_bow_9 = Ffmprb::File.temp('.flv'))
    Ffmprb::Util.ffmpeg *Ffmprb::Filter.complex_args('color=white:r=60:d=9:s=320x240 [red]', 'color=black:r=60:d=9:s=280x200 [green]', '[red] [green] overlay=20:20', "sine=#{NOTES.E6}:d=9"), *Ffmprb::Process::Output.audio_args, @av_file_e_bow_9.path
    @sample_files << (@av_file_btn_wtb_16 = Ffmprb::File.temp('.mp4'))
    Ffmprb::Util.ffmpeg *Ffmprb::Filter.complex_args('color=white:s=320x240:r=60:d=4, split [wh1a] [wh1b]', 'color=black:s=320x240:r=60:d=4, split [bl1a] [bl1b]', "sine=#{NOTES.B6}:d=4, asplit [na5a] [na5b]", 'aevalsrc=0:d=4, asplit [si1a] [si1b]', '[wh1a] [na5a] [bl1a] [si1a] [wh1b] [na5b] [bl1b] [si1b] concat=4:v=1:a=1'), *Ffmprb::Process::Output.audio_args, @av_file_btn_wtb_16.path
    # @av_file_ro7_14 = Ffmprb::File.temp('.flv'))
    # Ffmprb::Util.ffmpeg *Ffmprb::Filter.complex_args('color=red:r=60:d=2:s=320x240 [red]', 'color=orange:r=60:d=2:s=320x240 [orange]', 'color=yellow:r=60:d=2:s=320x240 [yellow]', 'color=green:r=60:d=2:s=320x240 [green]', 'color=blue:r=60:d=2:s=320x240 [blue]', 'color=indigo:r=60:d=2:s=320x240 [indigo]', 'color=violet:r=60:d=2:s=320x240 [violet]', 'sine=1046.50:d=2 [c6]', 'sine=1174.66:d=2 [d6]', 'sine=1318.51:d=2 [e6]', 'sine=1396.91:d=2 [f6]', 'sine=1567.98:d=2 [g6]', 'sine=1760.00:d=2 [a6]', 'sine=1975.53:d=2 [b6]', '[red] [c6] [orange] [d6] [yellow] [e6] [green] [f6] [blue] [g6] [indigo] [a6] [violet] [b6] concat=7:v=1:a=1'), *Ffmprb::Process::Output.audio_args, @av_file_ro7_14.path
    @sample_files << (@v_file_6 = Ffmprb::File.temp('.y4m'))
    # XXX produces warning: [yuv4mpegpipe @ 0xXXXX] Encoder did not produce proper pts, making some up.
    Ffmprb::Util.ffmpeg *Ffmprb::Filter.complex_args('color=red:r=30:d=6:s=320x240, setpts=PTS-STARTPTS [red]', 'color=green:r=30:d=6:s=280x200 [green]', '[red] [green] overlay=20:20'), '-pix_fmt', 'yuv420p', @v_file_6.path
    @sample_files << (@a_file_g_16 = Ffmprb::File.temp('.mp3'))
    Ffmprb::Util.ffmpeg *Ffmprb::Filter.complex_args("sine=#{NOTES.G6}:d=16"), @a_file_g_16.path
  end
  config.after :all do
    @sample_files.each &:unlink
    @sample_files = nil
  end

end

NOTES = OpenStruct.new(
  C6: 1046.50,
  D6: 1174.66,
  E6: 1318.51,
  F6: 1396.91,
  G6: 1567.98,
  A6: 1760.00,
  B6: 1975.53
)

APPROXIMATE_RATIO = 0.06


RSpec::Matchers.define :be_approximately do |expected|
  define_method :is_approximately? do |actual|
    ((actual - expected)/(expected != 0 ? expected : 1)).abs < APPROXIMATE_RATIO
  end
  match {|actual| is_approximately? actual}

  failure_message do |actual|
    "expected that #{actual} would be within #{APPROXIMATE_RATIO * 100}% of #{expected}"
  end
end

RSpec::Matchers.define :be_ascending do
  define_method :is_ascending? do |actual|
    actual.reduce do |prev_vol, vol|
      return false  unless !prev_vol || vol > prev_vol
      vol
    end
    true
  end
  match {|actual| is_ascending? actual}

  failure_message do |actual|
    "expected that #{actual} would be in ascending order"
  end
end
