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
	end
	
	with "#stop" do
		it "stops every server-owned task" do
			dispatcher_task = server.instance_variable_get(:@task)
			processing_list = server.instance_variable_get(:@processing_list)
			processing_task = processing_list.instance_variable_get(:@task)
			delayed_jobs = server.instance_variable_get(:@delayed_jobs)
			delayed_task = delayed_jobs.instance_variable_get(:@task)
			
			server.stop
			
			expect(dispatcher_task.finished?).to be == true
			expect(processing_task.finished?).to be == true
			expect(delayed_task.finished?).to be == true
			
			# Shutdown remains safe when both the owner and its parent call it.
			server.stop
		end
		
		it "can restart after stopping all server-owned tasks" do
			server.stop
			server.start
			server.call(job)
			
			expect(buffer.pop).to be == job
		end
	end
end
