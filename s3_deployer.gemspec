# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 's3_deployer/version'

Gem::Specification.new do |spec|
  spec.name          = "s3_deployer"
  spec.version       = S3Deployer::VERSION
  spec.authors       = ["Anton Astashov"]
  spec.email         = ["anton.astashov@gmail.com"]
  spec.description   = "Simple gem for deploying client apps to S3"
  spec.summary       = "Simple gem for deploying client apps to S3"
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency 'aws-s3'
  spec.add_dependency 'json'

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
end
