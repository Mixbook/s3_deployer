require 'aws/s3'
require 'json'

require "s3_deployer/config"
require "s3_deployer/version"

class S3Deployer
  class << self
    attr_reader :config

    def configure(&block)
      @config = Config.new
      @config.instance_eval(&block)

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
      time = Time.now.strftime("%Y%m%d%H%M%S")
      [time, "current"].map { |dir| File.join(app_path_with_bucket, dir) }.each do |dir|
        source_files_list.each do |file|
          s3_file_dir = Pathname.new(File.dirname(file)).relative_path_from(Pathname.new(config.dist_dir)).to_s
          absolute_s3_file_dir = s3_file_dir == "." ? dir : File.join(dir, s3_file_dir)
          store_value(File.basename(file), File.read(file), absolute_s3_file_dir)
        end
      end
    end

    def rollback!
      puts "Rolling back to #{config.revision}"
      prefix = File.join(config.app_path, config.revision)
      AWS::S3::Bucket.objects(config.bucket, prefix: prefix).each do |object|
        path = File.join(config.bucket, object.key.gsub(prefix, File.join(config.app_path, "current")))
        store_value(File.basename(path), object.value, File.dirname(path))
      end
    end

    def update_revision!
      puts "Updating revision..."
      update_uri = URI.parse("#{config.mixbook_host}/services/dart/update_revision")
      res = Net::HTTP.post_form(update_uri, base: config.app_name, version: config.version)
      parsed_body = JSON.parse(res.body)
      puts "Update revision response: #{parsed_body}"
    end

    private

      def app_path_with_bucket
        File.join(config.bucket, config.app_path)
      end

      def get_value(key, path)
        puts "Retrieving value #{key} from #{path} on S3"
        AWS::S3::S3Object.value(key, path)
      end

      def store_value(key, value, path)
        puts "Storing value #{key} to #{path} on S3"
        AWS::S3::S3Object.store(key, value, path, access: :public_read)
      end

      def source_files_list
        Dir.glob(File.join(config.dist_dir, "**/*")).select { |f| File.file?(f) }
      end
  end
end
