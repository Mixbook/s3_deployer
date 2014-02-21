# S3Deployer

Tool for deploying our client apps (Dart, maybe Flash in future too) to S3

## Installation

Add this line to your application's Gemfile:

    gem 's3_deployer'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install s3_deployer

## Usage

You need to specify s3_deployer_config.rb file in your home directory, which may look like this (example from our 'previewer' Dart app)

```ruby
S3Deployer.configure do
  bucket "mixbook"
  app_name "previewer"
  app_path "taco/dart/#{app_name}#{"-#{version}" if version && version != ""}"
  mixbook_host "http://localhost:3000"
  dist_dir "dist"
  gzip [/\.js$/, /\.css$/] # or just use 'true' to gzip everything
  colorize true

  before_deploy ->(version) do
    # Some custom code to execute before deploy or rollback
  end

  after_deploy ->(version) do
    # Some custom code to execute after deploy or rollback
  end

  # You also can specify environment-specific settings, the default environment is 'production'
  environment(:development) do
    bucket "mixbook_dev"
  end

  access_key_id 'your S3 access key id'
  secret_access_key 'your S3 secret access key'
end
```

Note the 'dist_dir' setting, you should put all the necessary files to there, which should be sent to S3, before deploy.

Then, you need to include Deployer's tasks to your Rakefile, like:

```ruby
require 'rubygems'
require 'bundler'
Bundler.setup

require 's3_deployer/tasks'
require './s3_deployer_config'
```

There is 2 main tasks - for deploy, and for rollback. When you deploy, it creates a directories structure on S3, like:

```
/path
  /to
    /app
      CURRENT_REVISION
      SHAS
      /current
      /20130809134509
      /20130809140328
      ...
```

'current' contains the currently used copy of app. We use 'current' in Mixbook.com.
So, when you deploy, it copies the app both to 'current' and to the dir which looks like %Y%m%d%H%M%S.

When you rollback, it copies files from the REVISION directory you specified to the current directory.

So, use it like this:

```bash
$ rake s3_deployer:deploy
$ rake s3_deployer:rollback REVISION=20130809140330
$ rake s3_deployer:update_revision # makes a call to Mixbook.com to clear cache
$ rake s3_deployer:deploy VERSION=new-stuff # check the example of deployer.rb above to see how it is used
$ rake s3_deployer:list # get the list of all deployed revisions and their SHAs and commit subjects
$ rake s3_deployer:current # get the currently deployed revision
$ rake s3_deployer:stage # only creates timestamp dir, like 20130809134509, but doesn't override the 'current' dir
```

If you want to run s3_deployer in some specific environment, use ENV variable:

```bash
$ ENV=development rake s3_deployer:deploy
```

Default environment is 'production'

## Contributing

1. Clone it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request pointing to master
