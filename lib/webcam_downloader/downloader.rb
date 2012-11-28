$:.unshift(File.dirname(__FILE__))

require 'digest/md5'
require 'logger'

module WebcamDownloader
  class Downloader
    DEV_MODE = false
    DEV_MODE_LIMIT = 5
    LOGGER_LEVEL = Logger::DEBUG
    DEFAULT_WORKERS_COUNT = 2

    def initialize(_options={ })
      Thread.abort_on_exception = true

      @options = _options

      @logger = _options[:logger] || Logger.new(STDOUT)
      @logger.level = _options[:logger_level] || LOGGER_LEVEL
      @workers_count = _options[:workers_count] || DEFAULT_WORKERS_COUNT

      @defs = Array.new
      @webcams = Array.new

      @sleep_interval = _options[:sleep_interval] || 5
      @loop_count = 1

      @storage = WebcamDownloader::Storage.new(self, _options)
      @image_processor = WebcamDownloader::ImageProcessor.new(self, _options)
      @presentation = WebcamDownloader::Presentation.new(self, _options)
      WebcamDownloader::WgetProxy.instance.setup(self, _options)
    end

    attr_reader :storage, :image_processor, :logger, :presentation
    attr_reader :webcams, :started_at

    def make_it_so
      # prepare Array for worker plans
      @webcam_by_worker = Hash.new
      @threads_by_worker = Hash.new
      (0...@workers_count).each do |wrk_id|
        @webcam_by_worker[wrk_id] = Array.new
      end

      # create WebCam instances
      @defs.each_with_index do |d, i|
        w = WebcamDownloader::Webcam.new(d, self)
        w.webcam_id = i
        @webcams << w

        # choose worker and place webcam there
        wrk_id = i % @workers_count
        w.worker_id = wrk_id
        @webcam_by_worker[wrk_id] << w

        @logger.debug("Created Webcam for #{w.desc}, id #{i}, worker #{wrk_id}")
      end

      @logger.info("Start!")
      @started_at = Time.now
      @storage.descs = @webcams.collect { |w| w.desc }
      @storage.prepare_file_structure
      @storage.prepare_monthly_directories

      @logger.info("Start loop!")
      start_loop
    end

    def start_loop
      loop do
        @logger.info("Loop #{@loop_count}")

        @webcam_by_worker.keys.each do |wrk_id|
          @logger.info("Starting thread #{wrk_id} with #{@webcam_by_worker[wrk_id].size} webcams")
          @threads_by_worker[wrk_id] = Thread.new do
            @webcam_by_worker[wrk_id].each do |webcam|
              webcam.make_it_so
            end
          end
          @logger.info("Started thread #{wrk_id} with #{@webcam_by_worker[wrk_id].size} webcams")
        end

        # wait for threads to finish
        @logger.debug("Waiting for threads to finish their job")
        loop do
          alive_threads = @threads_by_worker.values.select { |t| t.alive? }
          @logger.debug("Threads alive - #{alive_threads.size}")
          sleep 0.5
          
          break if alive_threads.size == 0
        end
        @logger.info("All threads are dead! yeaah!")

        # single thread, oldschool
        #@webcams.each do |webcam|
        #  Thread.new{ webcam.make_it_so }
        #end

        @presentation.after_loop_cycle

        @loop_count += 1
        @logger.debug("Sleep after loop #{@sleep_interval}")
        sleep(@sleep_interval)
      end
    end


    def load_all_definition_files(path = 'config')
      Dir.new(path).each do |f|
        if f =~ /\.yml/
          load_definition_file(File.join(path, f))
        end
      end
      @logger.info("Loaded total #{@defs.size} definitions")
      check_def_uniq
    end

    def load_definition_file(file = File.join('config', 'defs.yml'))
      defs = YAML::load(File.open(file))
      flat_defs = Array.new
      defs.each do |u|
        array = u[:array]
        array.each do |a|
          a[:group] = u[:group]
          a[:def_file] = file
        end
        flat_defs += array
      end

      if DEV_MODE
        @logger.warn("DEVELOPMENT MODE, from 0 to #{DEV_MODE_LIMIT}")
        flat_defs = flat_defs[0..DEV_MODE_LIMIT]
      end

      @logger.info("Loaded #{flat_defs.count} definitions")


      @defs += flat_defs
    end

    def check_def_uniq
      @defs.each do |d|
        url = d[:url]
        unless url.nil?
          similar = @defs.select{|e| e[:url] == url}
          if similar.size > 1
            @logger.error("DOUBLED #{d[:desc]} - #{d[:url]}")
            @logger.error("\n#{similar.to_yaml}")
          end
        end
      end
    end

  end
end