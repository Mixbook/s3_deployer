require 's3_deployer'

namespace :s3_deployer do
  desc "Deploy"
  task :deploy do
    S3Deployer.deploy!
    Rake::Task["s3_deployer:update_revision"].invoke
  end

  desc "Rollback"
  task :rollback do
    S3Deployer.rollback!
    Rake::Task["s3_deployer:update_revision"].invoke
  end

  desc "Update revision"
  task :update_revision do
    S3Deployer.update_revision!
  end

  desc "Get the list of deployed revisions"
  task :list do
    S3Deployer.list
  end
end
