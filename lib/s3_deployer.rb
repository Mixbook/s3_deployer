require 'aws/s3'
require 'json'
require 'zlib'
require 'stringio'
require 'tzinfo'

require "s3_deployer/config"
require "s3_deployer/color"
require "s3_deployer/version"

class S3Deployer
  DATE_FORMAT = "%Y%m%d%H%M%S"
  CURRENT_REVISION = "CURRENT_REVISION"
  class << self
    attr_reader :config

    def configure(&block)
      @config = Config.new
      @config.instance_eval(&block)
      @config.apply_environment_settings!

      AWS::S3::Base.establish_connection!(
        access_key_id: config.access_key_id,
        secret_access_key: config.secret_access_key
      )
    end

    def execute(cmd)
      puts "Running '#{cmd}'"
      system(cmd, out: $stdout, err: :out)
    end

    def deploy!
      revision = time_zone.now.strftime(DATE_FORMAT)
      config.before_deploy[revision] if config.before_deploy
      stage!(revision)
      switch!(revision)
      config.after_deploy[revision] if config.after_deploy
    end

    def stage!(revision = time_zone.now.strftime(DATE_FORMAT))
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
      revision = normalize_revision(revision)
      config.before_switch[current_revision, revision] if config.before_switch
      prefix = config.app_path.empty? ? revision : File.join(config.app_path, revision)
      AWS::S3::Bucket.objects(config.bucket, prefix: prefix).each do |object|
        target_path = config.app_path.empty? ? @config.current_path : File.join(config.app_path, @config.current_path)
        path = File.join(config.bucket, object.key.gsub(prefix, target_path))
        value = object.about["content-encoding"] == "gzip" ? decompress(object.value) : object.value
        store_value(File.basename(path), value, File.dirname(path))
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
      shas_by_revisions[normalize_revision(revision)]
    end

    private

      def copy_files_to_s3(rev)
        dir = File.join(app_path_with_bucket, rev)
        source_files_list.each do |file|
          s3_file_dir = Pathname.new(File.dirname(file)).relative_path_from(Pathname.new(config.dist_dir)).to_s
          absolute_s3_file_dir = s3_file_dir == "." ? dir : File.join(dir, s3_file_dir)
          store_value(File.basename(file), File.read(file), absolute_s3_file_dir)
        end
      end

      def get_list_of_revisions
        prefix = File.join(config.app_path)
        url = "/#{config.bucket}?prefix=#{prefix}/&delimiter=/"
        xml = REXML::Document.new(AWS::S3::Base.get(url).body)
        xml.elements.collect("//CommonPrefixes/Prefix") { |e| e.text.gsub(prefix, "").gsub("/", "") }.select do |dir|
          !!(Time.strptime(dir, DATE_FORMAT) rescue nil)
        end.sort
      end

      def app_path_with_bucket
        File.join(config.bucket, config.app_path)
      end

      def get_datetime_from_revision(revision)
        date = Time.strptime(revision, DATE_FORMAT) rescue nil
        date.strftime("%m/%d/%Y %H:%M") if date
      end

      def shas_by_revisions
        @shas_by_revisions ||= get_value("SHAS", app_path_with_bucket).split("\n").inject({}) do |memo, line|
          revision, sha = line.split(" - ").map(&:strip)
          memo[revision] = sha
          memo
        end
      rescue AWS::S3::NoSuchKey
        {}
      end

      def current_revision_path
        File.join(app_path_with_bucket, CURRENT_REVISION)
      end

      def get_value(key, path)
        puts "Retrieving value #{key} from #{path} on S3"
        AWS::S3::S3Object.value(key, path)
      end

      def store_current_revision(revision)
        store_value(File.basename(current_revision_path), revision, File.dirname(current_revision_path))
      end

      def store_git_hash(time)
        value = shas_by_revisions.
          merge(time => `git rev-parse HEAD`.strip).
          map { |sha, rev| "#{sha} - #{rev}" }.join("\n")
        store_value("SHAS", value, app_path_with_bucket)
        @shas_by_revisions = nil
      end

      def get_current_revision
        get_value(File.basename(current_revision_path), File.dirname(current_revision_path))
      rescue AWS::S3::NoSuchKey
        nil
      end

      def store_value(key, value, path)
        puts "Storing value #{colorize(:yellow, key)} to #{colorize(:yellow, path)} on S3#{", #{colorize(:green, 'gzipped')}" if should_compress?(key)}"
        options = {access: :public_read}
        if config.cache_control && !config.cache_control.empty?
          options[:cache_control] = config.cache_control
        end
        if should_compress?(key)
          options[:content_encoding] = "gzip"
          value = compress(value)
        end
        AWS::S3::S3Object.store(key, value, path, options)
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
