require 'logger'
require 'ostruct'
require 'timeout'

# IMPORTANT NOTE ffmprb uses threads internally, however, it is not "thread-safe"

require_relative 'ffmprb/version'
require_relative 'ffmprb/util'  # NOTE utils are like (micro-)gem candidates, errors are also there

module Ffmprb

  ENV_VAR_FALSE_REGEX = /^(0|no?|false)?$/i

  CGA = '320x200'
  QVGA = '320x240'
  HD_720p = '1280x720'
  HD_1080p = '1920x1080'

  class << self

    # TODO limit:
    def process(*args, name: nil, **opts, &blk)
      fail Error, "process: nothing ;( gimme a block!"  unless blk

      name ||=  blk.source_location.map(&:to_s).map{ |s| ::File.basename s.to_s, ::File.extname(s) }.join(':')
      process = Process.new(name: name, **opts)
      proc_vis_node process  if respond_to? :proc_vis_node  # XXX simply include the ProcVis if it makes into a gem
      logger.debug{"Starting process with #{args} #{opts} in #{blk.source_location}"}

      process.instance_exec *args, &blk
      logger.debug{"Initialized process with #{args} #{opts} in #{blk.source_location}"}

      process.run.tap do
        logger.debug{"Finished process with #{args} #{opts} in #{blk.source_location}"}
      end
    end
    alias :action! :process  # ;)

    attr_accessor :debug, :ffmpeg_debug, :log_level

    def logger
      @logger ||= Logger.new(STDERR).tap do |logger|
        logger.level = debug ? Logger::DEBUG : Ffmprb.log_level
      end
    end

    def logger=(logger)
      @logger.close  if @logger
      @logger = logger
    end

  end

  include Util::ProcVis  if FIREBASE_AVAILABLE
end


require_relative 'ffmprb/execution'
require_relative 'ffmprb/file'
require_relative 'ffmprb/filter'
require_relative 'ffmprb/find_silence'
require_relative 'ffmprb/process'

require 'defaults'
