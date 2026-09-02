# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

require "async"
require "async/redis"

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
			
			expect(server.status_string).to be == "R=0 D=0 P=0/1"
		end
		
		it "formats large counts" do
			expect(server.send(:format_count, 1_234)).to be == "1.23K"
			expect(server.send(:format_count, 1_234_567)).to be == "1.23M"
		end
	end
end

describe Async::Job::Processor::Redis::Server do
	include Sus::Fixtures::Console::CapturedLogger
	
	let(:client) do
		Object.new.tap do |client|
			def client.script(...)
				"script"
			end
		end
	end
	
	let(:server) {subject.new(nil, client, retry_delay: 1.0, retry_delay_limit: 4.0)}
	
	with "#run" do
		it "retries dequeue failures with bounded exponential backoff" do
			attempts = 0
			delays = []
			
			mock(server) do |mock|
				mock.replace(:dequeue) do |_parent|
					attempts += 1
					
					throw :finished if attempts > 4
					raise IOError, "Redis connection failed!"
				end
				
				mock.replace(:rand) {1.0}
				mock.replace(:sleep) {|delay| delays << delay}
			end
			
			catch(:finished) do
				server.send(:run, nil)
			end
			
			expect(delays).to be == [1.0, 2.0, 4.0, 4.0]
			expect_console.to have_logged(severity: be(:==, :error), message: be(:include?, "Failed to dequeue job"))
		end
		
		it "resets the retry delay after a successful dequeue" do
			attempts = 0
			delays = []
			
			mock(server) do |mock|
				mock.replace(:dequeue) do |_parent|
					attempts += 1
					
					case attempts
					when 1, 3
						raise IOError, "Redis connection failed!"
					when 4
						throw :finished
					end
				end
				
				mock.replace(:rand) {1.0}
				mock.replace(:sleep) {|delay| delays << delay}
			end
			
			catch(:finished) do
				server.send(:run, nil)
			end
			
			expect(delays).to be == [1.0, 1.0]
		end
	end
end
