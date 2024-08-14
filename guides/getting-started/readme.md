# Getting Started

This guide gives you an overview of the `async-job-processor-redis` gem.

## Installation

Add the gem to your project:

``` shell
$ bundle add async-job-processor-redis
```

## Usage

Here is a full example of the job queue:

``` ruby
require 'async'
require 'async/job'
require 'async/job/processor/redis'

Async do
	buffer = Async::Job::Buffer.new

	queue = Async::Job::Builder.build(buffer) do
		dequeue Async::Job::Processor::Redis
	end
	
	# Run the server:
	server = Async{queue.start}
	
	# Enqueue a job:
	queue.call({message: "Hello, World!"})
	
	# Wait for the job to complete:
	job = buffer.pop
	pp job: job
	
	server.stop
end
```