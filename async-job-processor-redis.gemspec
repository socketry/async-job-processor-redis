# frozen_string_literal: true

require_relative "lib/async/job/processor/redis/version"

Gem::Specification.new do |spec|
	spec.name = "async-job-processor-redis"
	spec.version = Async::Job::Processor::Redis::VERSION
	
	spec.summary = "A asynchronous job queue for Ruby."
	spec.authors = ["Samuel Williams"]
	spec.license = "MIT"
	
	spec.cert_chain  = ['release.cert']
	spec.signing_key = File.expand_path('~/.gem/release.pem')
	
	spec.metadata = {
		"documentation_uri" => "https://socketry.github.io/async-job-processor-redis/",
		"source_code_uri" => "https://github.com/socketry/async-job-processor-redis",
	}
	
	spec.files = Dir['{lib}/**/*', '*.md', base: __dir__]
	
	spec.required_ruby_version = ">= 3.1"
	
	spec.add_dependency "async-job", "~> 0.10"
	spec.add_dependency "async-redis"
end
