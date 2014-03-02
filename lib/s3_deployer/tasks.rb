require 's3_deployer'

namespace :s3_deployer do
  desc "Deploy"
  task :deploy do
    S3Deployer.deploy!
    Rake::Task["s3_deployer:update_revision"].invoke
  end

  desc "Deploy the revision, but don't change it to the 'current' revision"
  task :stage do
    S3Deployer.stage!
  end

  desc "Switch"
  task :switch do
    S3Deployer.switch!
    Rake::Task["s3_deployer:update_revision"].invoke
  end

  desc "Update revision"
  task :update_revision do
    S3Deployer.update_revision!
  end

  desc "Get current revision number"
  task :current do
    S3Deployer.current
  end

  desc "Get the list of deployed revisions"
  task :list do
    S3Deployer.list
  end
end
