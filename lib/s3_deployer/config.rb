class S3Deployer
  class Config
    attr_reader :version, :revision, :env

    def initialize
      @version = ENV["VERSION"] || ""
      @revision = ENV["REVISION"] || ""
      @env = ENV["ENV"] || "production"
      @env_settings = {}
    end

    %w{bucket app_name app_path mixbook_host dist_dir access_key_id secret_access_key}.each do |method|
      define_method method do |value = :omitted|
        instance_variable_set("@#{method}", value) unless value == :omitted
        instance_variable_get("@#{method}")
      end
    end

    def environment(name, &block)
      @env_settings[name.to_s] = block
    end

    def apply_environment_settings!
      instance_eval(@env_settings[@env.to_s])
    end
  end
end
