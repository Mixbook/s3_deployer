# S3Deployer

Tool for versioned deploying of client-side apps (or literally anything) to S3

## Installation

Add this line to your application's Gemfile:

    gem 's3_deployer'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install s3_deployer

## Features

* Versioned deploys
* Separated 'stage' (uploading code to S3) and 'switch' (switching to the right code version) tasks
  (with ability to combine them with the 'deploy' task)
* Parallel uploads
* Retries in case of upload failures
* Optional compression (by regexps, see example below)
* before/after hooks for every step
* Separate environments support
* Automatic maintaining of the list of versions and mapping them to the list of git commits
* Rollback via 'switch' command
* Colorized output :)

## Usage

You need to specify s3_deployer_config.rb file in your home directory, which may look like this:

```ruby
S3Deployer.configure do
  bucket "some-bucket"
  region 'us-east-1'
  app_name "devastator"
  app_path "path/to/#{app_name}#{"-#{version}" if version && version != ""}"
  dist_dir "dist"
  gzip [/\.js$/, /\.css$/] # or just use 'true' to gzip everything
  colorize true
  time_zone "America/Los_Angeles" # Useful when you develop from different timezones (e.g. for distributed team,
                                  # or when deploy from some build server), to be consistent with revision numbers

  before_stage ->(version) do
    # Some custom code to execute before deploy or stage
  end

  after_stage ->(version) do
    # Some custom code to execute after deploy or stage
  end

  before_switch ->(version) do
    # Some custom code to execute before deploy or switch
  end

  after_switch ->(version) do
    # Some custom code to execute after deploy or switch
  end

  before_deploy ->(version) do
    # Some custom code to execute before deploy
  end

  after_deploy ->(version) do
    # Some custom code to execute after deploy
  end

  # You also can specify environment-specific settings, the default environment is 'production'
  environment(:development) do
    bucket "some-bucket-dev"
  end

  access_key_id 'your S3 access key id'
  secret_access_key 'your S3 secret access key'
  session_token 'your s3 session token (optional)'
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

There are 3 main tasks - for deploy, switch and stage. When you stage, it gets all the files from the dist_dir,
and copies them to S3. It creates a directories structure on S3, like:

```
/path
  /to
    /app
      /20130809134509
      /20130809140328
      ...
      SHAS
```

These '20130809134509'-like directories are actually 'staged' versions of the app. Directory name is just
a revision name, in the format "%Y%m%d%H%M%S".

Then, you have to do 'switch', which just copies the selected revision directory into 'current'.
So, after 'switch' e.g. to 20130809134509, the directory structure will be like

```
/path
  /to
    /app
      /20130809134509
      /20130809140328
      ...
      /current
      CURRENT_REVISION
      SHAS
```

'current' contains the currently used copy of the app. Your app should use files from this directory.

You also could do "deploy", it is basically "stage", and then "switch" to just staged revision.

So, use it like this:

```bash
$ rake s3_deployer:stage # only creates timestamp dir, like 20130809134509, but doesn't override the 'current' dir
$ rake s3_deployer:switch REVISION=20130809140330
$ rake s3_deployer:deploy
$ rake s3_deployer:deploy VERSION=new-stuff # check the example of deployer.rb above to see how it is used
$ rake s3_deployer:current # get the currently deployed revision
$ rake s3_deployer:list # get the list of all deployed revisions and their SHAs and commit subjects
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
