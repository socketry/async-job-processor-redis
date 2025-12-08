# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

require "async"
require "async/redis"
require "async/semaphore"

require "sus/fixtures/async/reactor_context"
require "sus/fixtures/console"

require "async/job/buffer"
require "async/job/processor/redis"

describe Async::Job::Processor::Redis do
	include Sus::Fixtures::Async::ReactorContext
	include Sus::Fixtures::Console::CapturedLogger
	
	let(:buffer) {Async::Job::Buffer.new}
	
	let(:prefix) {"async:job:#{SecureRandom.hex(8)}"}
	let(:server) {subject.new(buffer, prefix:, resolution: 1)}
	
	before do
		server.start
	end
	
	after do
		server.stop
	end
	
	let(:job) {{"data" => "test job"}}
	
	it "can schedule a job and have it processed immediately" do
		server.call(job)
		
		expect(buffer.pop).to be == job
	end
	
	with "delayed job" do
		it "can schedule a job and have it processed after a delay" do
			now = Time.now
			delayed_job = job.merge("scheduled_at" => now + 1)
			
			server.call(delayed_job)
			
			expect(buffer.pop).to have_keys(
				"data" => be == job["data"],
			)
		end
	end
	
	with "a failed job" do
		it "can retry a job" do
			server.call(job)
			failed = false
			
			mock(buffer) do |mock|
				mock.before(:call) do |job|
					# The first time the job is called, it will fail, and we record that:
					unless failed
						failed = true
						raise "test error"
					end
				end
			end
			
			# The job was retried:
			processed_job = buffer.pop
			expect(processed_job).to have_keys(
				"data" => be == job["data"],
			)
			
			expect(failed).to be == true
		end
	end
	
	with "#status_string" do
		it "returns a string with the current job counts" do
			expect(server.status_string).to be == "R=0 D=0 P=0/0"
			
			server.call(job)
			sleep 0.1 # Allow some time for the job to be processed.
			
			expect(server.status_string).to be == "R=0 D=0 P=0/1"
		end
	end
	
	with "concurrency limit" do
		# Delegate that sleeps for 5 seconds to simulate slow job processing
		let(:slow_delegate) do
			Class.new do
				def start
				end
				
				def stop
				end
				
				def call(job)
					sleep 5
				end
			end.new
		end
		
		with "Async::Idler" do
			let(:idler_server) {subject.new(slow_delegate, prefix:, resolution: 1)}
			
			it "can process all jobs concurrently" do
				idler_server.start
				
				# Enqueue 10 jobs
				10.times do |i|
					idler_server.call({"data" => "job #{i}"})
				end
				
				# Give time for all jobs to be picked up
				sleep 0.5
				
				# With Async::Idler (unlimited concurrency), all 10 jobs should be in processing status
				status = idler_server.status_string
				expect(status).to be =~ /P=(10|[5-9])\//
				
				idler_server.stop
			end
		end
		
		with "Async::Semaphore" do
			let(:semaphore_server) {subject.new(slow_delegate, prefix:, resolution: 1, parent: Async::Semaphore.new(2))}
			
			it "can limit concurrent job processing to 2" do
				semaphore_server.start
				
				# Enqueue 10 jobs
				10.times do |i|
					semaphore_server.call({"data" => "job #{i}"})
				end
				
				# Give time for jobs to be picked up
				sleep 0.5
				
				# Only 2 jobs should be in processing status
				status = semaphore_server.status_string
				expect(status).to be =~ /P=2\//
				
				semaphore_server.stop
			end
		end
	end
end
