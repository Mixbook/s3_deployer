class S3Deployer
  class Config
    attr_reader :version, :revision
    def initialize
      @version = ENV["VERSION"] || ""
      @revision = ENV["REVISION"] || ""
    end

    %w{bucket app_name app_path mixbook_host dist_dir access_key_id secret_access_key}.each do |method|
      define_method method do |value = :omitted|
        instance_variable_set("@#{method}", value) unless value == :omitted
        instance_variable_get("@#{method}")
      end
    end
  end
end
