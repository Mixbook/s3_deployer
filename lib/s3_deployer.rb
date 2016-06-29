require 'json'
require 'zlib'
require 'stringio'
require 'tzinfo'
require 'rexml/document'
require 'parallel'
require 'aws-sdk'
require 'aws-sdk-core/endpoint_provider' # it's needed by some reason for Ruby 2.2.3
require 'mime-types'

require "s3_deployer/config"
require "s3_deployer/color"
require "s3_deployer/version"

class S3Deployer
  DATE_FORMAT = "%Y%m%d%H%M%S"
  CURRENT_REVISION = "CURRENT_REVISION"
  RETRY_TIMES = [1, 3, 8].freeze

  class << self
    attr_reader :config

    def configure(&block)
      @config = Config.new
      @config.instance_eval(&block)
      @config.apply_environment_settings!

      Aws.config.update({
        region: config.region,
        credentials: Aws::Credentials.new(config.access_key_id, config.secret_access_key),
      })
    end

    def execute(cmd)
      puts "Running '#{cmd}'"
      system(cmd, out: $stdout, err: :out)
    end

    def deploy!
      revision = config.revision || time_zone.now.strftime(DATE_FORMAT)
      config.before_deploy[revision] if config.before_deploy
      stage!(revision)
      switch!(revision)
      config.after_deploy[revision] if config.after_deploy
    end

    def stage!(revision = (config.revision || time_zone.now.strftime(DATE_FORMAT)))
      puts "Staging #{colorize(:green, revision)}"
      config.before_stage[revision] if config.before_stage
      copy_files_to_s3(revision)
      store_git_hash(revision)
      config.after_stage[revision] if config.after_stage
    end

    def switch!(revision = config.revision)
      current_revision = get_current_revision
      current_sha = sha_of_revision(current_revision)
      sha = sha_of_revision(revision)
      puts "Switching from #{colorize(:green, current_revision)} (#{colorize(:yellow, current_sha && current_sha[0..7])}) " +
        "to #{colorize(:green, revision)} (#{colorize(:yellow, sha && sha[0..7])})"
      if !revision || revision.strip.empty?
        warn "You must specify the revision by REVISION env variable"
        exit(1)
      end
      config.before_switch[current_revision, revision] if config.before_switch
      prefix = config.app_path.empty? ? revision : File.join(revisions_path, revision)
      list_of_objects = []
      Aws::S3::Resource.new.bucket(config.bucket).objects(prefix: prefix).each do |object_summary|
        list_of_objects << object_summary
      end
      Parallel.each(list_of_objects, in_threads: 20) do |object_summary|
        object = object_summary.object
        target_path = config.app_path.empty? ? @config.current_path : File.join(config.app_path, @config.current_path)
        path = object.key.gsub(prefix, target_path)
        value = object.get.body.read
        value = object.content_encoding == "gzip" ? decompress(value) : value
        store_value(path, value)
      end
      store_current_revision(revision)
      config.after_switch[current_revision, revision] if config.after_switch
    end

    def current
      current_revision = get_current_revision
      if current_revision
        puts "Current revision: #{current_revision} - #{get_datetime_from_revision(current_revision)}"
      else
        puts "There is no information about the current revision"
      end
    end

    def normalize_revision(revision)
      if revision && !revision.empty?
        datetime = get_datetime_from_revision(revision)
        if datetime
          revision
        else
          shas_by_revisions.detect { |k, v| v.start_with?(revision) }.first
        end
      end
    end

    def list
      puts "Getting the list of deployed revisions..."
      current_revision = get_current_revision
      get_list_of_revisions.each do |rev|
        datetime = get_datetime_from_revision(rev)
        sha = shas_by_revisions[rev]
        title = sha ? `git show -s --format=%s #{sha}`.strip : nil
        string = "#{rev} - #{datetime} #{sha ? " - #{sha[0..7]}" : ""} #{title ? "(#{title})" : ""} #{" <= current" if rev == current_revision}"
        puts string
      end
    end

    def changes(from, to)
      from_sha = sha_of_revision(from)
      to_sha = sha_of_revision(to)
      if from_sha && to_sha
        `git log --oneline --reverse #{from_sha}...#{to_sha}`.split("\n").map(&:strip)
      else
        []
      end
    end

    def sha_of_revision(revision)
      shas_by_revisions[revision]
    end

    private

      def copy_files_to_s3(rev)
        dir = File.join(revisions_path, rev)
        Parallel.each(source_files_list, in_threads: 20) do |file|
          s3_file = Pathname.new(file).relative_path_from(Pathname.new(config.dist_dir)).to_s
          store_value(File.join(dir, s3_file), File.read(file))
        end
      end

      def get_list_of_revisions
        prefix = revisions_path
        body = Aws::S3::Client.new.list_objects({bucket: config.bucket, delimiter: '/', prefix: prefix + "/"})
        body.common_prefixes.map(&:prefix).map { |e| e.gsub(prefix, "").gsub("/", "") }.sort
      end

      def app_path_with_bucket
        File.join(config.bucket, config.app_path)
      end

      def get_datetime_from_revision(revision)
        date = Time.strptime(revision, DATE_FORMAT) rescue nil
        date.strftime("%m/%d/%Y %H:%M") if date
      end

      def shas_by_revisions
        @shas_by_revisions ||= get_value(File.join(config.app_path, "SHAS")).split("\n").inject({}) do |memo, line|
          revision, sha = line.split(" - ").map(&:strip)
          memo[revision] = sha
          memo
        end
      rescue Aws::S3::Errors::NoSuchKey
        {}
      end

      def current_revision_path
        File.join(config.app_path, CURRENT_REVISION)
      end

      def revisions_path
        File.join(config.app_path, "revisions")
      end

      def get_value(key)
        puts "Retrieving value #{key} on S3"
        retry_block(RETRY_TIMES.dup) do
          Aws::S3::Resource.new.bucket(config.bucket).object(key).get.body.read
        end
      end

      def store_current_revision(revision)
        store_value(current_revision_path, revision, cache_control: "max-age=0, no-cache")
      end

      def store_git_hash(time)
        value = shas_by_revisions.
          merge(time => `git rev-parse HEAD`.strip).
          map { |sha, rev| "#{sha} - #{rev}" }.join("\n")
        store_value(File.join(config.app_path, "SHAS"), value, cache_control: "max-age=0, no-cache")
        @shas_by_revisions = nil
      end

      def get_current_revision
        get_value(current_revision_path)
      rescue Aws::S3::Errors::NoSuchKey
        nil
      end

      def store_value(key, value, options = {})
        options = {acl: "public-read"}.merge(options)
        if config.cache_control && !config.cache_control.empty?
          options[:cache_control] = config.cache_control
        end
        if should_compress?(key)
          options[:content_encoding] = "gzip"
          value = compress(value)
        end
        mime_type = MIME::Types.of(key).first
        options[:content_type] = mime_type ? mime_type.content_type : "binary/octet-stream"
        retry_block(RETRY_TIMES.dup) do
          puts "Storing value #{colorize(:yellow, key)} on S3#{", #{colorize(:green, 'gzipped')}" if should_compress?(key)}"
          Aws::S3::Resource.new.bucket(config.bucket).object(key).put(options.merge(body: value))
        end
      end

      def retry_block(sleep_times, &block)
        block.call
      rescue Exception => e
        puts "#{colorize(:red, "Error!")} #{e}\n\n#{e.backtrace.take(3).join("\n")}"
        no_retry_exceptions = [Aws::S3::Errors::NoSuchKey]
        if no_retry_exceptions.any? { |exc| e.is_a?(exc) }
          raise e
        elsif !sleep_times.empty?
          sleep_time = sleep_times.shift
          puts "Still have #{colorize(:yellow, "#{sleep_times.count} retries")}, so waiting for #{colorize(:yellow, "#{sleep_time} seconds")} and retrying..."
          sleep sleep_time
          retry_block(sleep_times, &block)
        else
          puts "Out of retries, failing..."
          raise e
        end
      end

      def should_compress?(key)
        if [true, false, nil].include?(config.gzip)
          !!config.gzip
        else
          key != CURRENT_REVISION && Array(config.gzip).any? { |regexp| key.match(regexp) }
        end
      end

      def compress(source)
        output = Stream.new
        gz = Zlib::GzipWriter.new(output, Zlib::DEFAULT_COMPRESSION, Zlib::DEFAULT_STRATEGY)
        gz.write(source)
        gz.close
        output.string
      end

      def decompress(source)
        begin
          Zlib::GzipReader.new(StringIO.new(source)).read
        rescue Zlib::GzipFile::Error
          source
        end
      end

      def source_files_list
        Dir.glob(File.join(config.dist_dir, "**/*")).select { |f| File.file?(f) }
      end

      def colorize(color, text)
        config.colorize ? Color.send(color, text) : text
      end

      def time_zone
        TZInfo::Timezone.get(config.time_zone)
      end

      class Stream < StringIO
        def initialize(*)
          super
          set_encoding "BINARY"
        end

        def close
          rewind
        end
      end

  end
end
