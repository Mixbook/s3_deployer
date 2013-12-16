require 'aws/s3'
require 'json'
require 'zlib'
require 'stringio'

require "s3_deployer/config"
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
      time = Time.now.strftime(DATE_FORMAT)
      [time, "current"].map { |dir| File.join(app_path_with_bucket, dir) }.each do |dir|
        source_files_list.each do |file|
          s3_file_dir = Pathname.new(File.dirname(file)).relative_path_from(Pathname.new(config.dist_dir)).to_s
          absolute_s3_file_dir = s3_file_dir == "." ? dir : File.join(dir, s3_file_dir)
          store_value(File.basename(file), File.read(file), absolute_s3_file_dir)
        end
      end
      store_current_revision(time)
    end

    def current
      current_revision = get_current_revision
      if current_revision
        puts "Current revision: #{current_revision} - #{get_datetime_from_revision(current_revision)}"
      else
        puts "There is no information about the current revision"
      end
    end

    def rollback!
      puts "Rolling back to #{config.revision}"
      if !config.revision || config.revision.strip.empty?
        warn "You must specify the revision by REVISION env variable"
        exit(1)
      end
      prefix = File.join(config.app_path, config.revision)
      AWS::S3::Bucket.objects(config.bucket, prefix: prefix).each do |object|
        path = File.join(config.bucket, object.key.gsub(prefix, File.join(config.app_path, "current")))
        store_value(File.basename(path), object.value, File.dirname(path))
      end
      store_current_revision(config.revision)
    end

    def update_revision!
      puts "Updating revision..."
      update_uri = URI.parse("#{config.mixbook_host}/services/dart/update_revision")
      res = Net::HTTP.post_form(update_uri, base: config.app_name, version: config.version)
      parsed_body = JSON.parse(res.body)
      puts "Update revision response: #{parsed_body}"
    end

    def list
      puts "Getting the list of deployed revisions..."
      current_revision = get_current_revision
      get_list_of_revisions.each do |dir|
        string = "#{dir} - #{get_datetime_from_revision(dir)}#{" <= current" if dir == current_revision}"
        puts string
      end
    end

    private

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

      def get_current_revision
        get_value(File.basename(current_revision_path), File.dirname(current_revision_path))
      rescue AWS::S3::NoSuchKey
        nil
      end

      def store_value(key, value, path)
        puts "Storing value #{key} to #{path} on S3#{", gzipped" if should_compress?(key)}"
        options = {access: :public_read}
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

      def source_files_list
        Dir.glob(File.join(config.dist_dir, "**/*")).select { |f| File.file?(f) }
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
