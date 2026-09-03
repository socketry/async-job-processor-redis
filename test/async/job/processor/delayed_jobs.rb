# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "async"
require "async/redis"

require "sus/fixtures/async/reactor_context"
require "sus/fixtures/console"

require "async/job/processor/redis/delayed_jobs"
require "async/job/processor/redis/ready_list"
require "async/job/processor/redis/job_store"

describe Async::Job::Processor::Redis::DelayedJobs do
	include Sus::Fixtures::Async::ReactorContext
	include Sus::Fixtures::Console::CapturedLogger
	
	let(:client) {Async::Redis::Client.new}
	let(:prefix) {"test-delayed-#{SecureRandom.hex(8)}"}
	let(:delayed_jobs) {subject.new(client, "#{prefix}:delayed")}
	let(:job_store) {Async::Job::Processor::Redis::JobStore.new(client, "#{prefix}:jobs")}
	let(:ready_list) {Async::Job::Processor::Redis::ReadyList.new(client, "#{prefix}:ready")}
	
	let(:test_job) {JSON.dump({"data" => "test delayed job"})}
	
	with "#add" do
		it "can add a job with a timestamp" do
			future_time = Time.now + 60  # 1 minute from now
			
			job_id = delayed_jobs.add(test_job, future_time, job_store)
			
			expect(job_id).to be_a(String)
			expect(job_id).not.to be(:empty?)
			
			# Verify the job was stored in the job store
			stored_job = client.hget(job_store.key, job_id)
			expect(stored_job).to be == test_job
			
			# Verify the job was added to the delayed queue with correct timestamp
			score = client.zscore(delayed_jobs.key, job_id)
			expect(score.to_f).to be == future_time.to_f
		end
	end
	
	with "#move" do
		it "can move ready jobs from delayed queue to ready list" do
			# Add a job that's ready to be processed (past timestamp)
			past_time = Time.now - 60  # 1 minute ago
			job_id = delayed_jobs.add(test_job, past_time, job_store)
			
			# Move jobs that are ready
			count = delayed_jobs.move(destination: ready_list.key)
			
			expect(count).to be == 1
			
			# Verify the job was moved to the ready list
			ready_job_id = client.lpop(ready_list.key)
			expect(ready_job_id).to be == job_id
			
			# Verify the job was removed from the delayed queue
			remaining_score = client.zscore(delayed_jobs.key, job_id)
			expect(remaining_score).to be_nil
		end
		
		it "does not move jobs that aren't ready yet" do
			# Add a job scheduled for the future
			future_time = Time.now + 60  # 1 minute from now
			job_id = delayed_jobs.add(test_job, future_time, job_store)
			
			# Try to move jobs
			count = delayed_jobs.move(destination: ready_list.key)
			
			expect(count).to be == 0
			
			# Verify the job is still in the delayed queue
			score = client.zscore(delayed_jobs.key, job_id)
			expect(score.to_f).to be == future_time.to_f
			
			# Verify no jobs were added to the ready list
			ready_job_id = client.lpop(ready_list.key)
			expect(ready_job_id).to be_nil
		end
		
		it "can move multiple ready jobs at once" do
			past_time = Time.now - 60
			
			# Add multiple jobs that are ready
			job_id_1 = delayed_jobs.add(JSON.dump({"data" => "job 1"}), past_time, job_store)
			job_id_2 = delayed_jobs.add(JSON.dump({"data" => "job 2"}), past_time, job_store)
			job_id_3 = delayed_jobs.add(JSON.dump({"data" => "job 3"}), past_time, job_store)
			
			count = delayed_jobs.move(destination: ready_list.key)
			
			expect(count).to be == 3
			
			# Verify all jobs were moved to ready list
			ready_jobs = []
			3.times do
				job_id = client.lpop(ready_list.key)
				ready_jobs << job_id if job_id
			end
			
			expect(ready_jobs).to have_attributes(size: be == 3)
			expect(ready_jobs).to be(:include?, job_id_1)
			expect(ready_jobs).to be(:include?, job_id_2)
			expect(ready_jobs).to be(:include?, job_id_3)
		end
		
		it "reloads the move script after Redis flushes its script cache" do
			past_time = Time.now - 60
			job_id = delayed_jobs.add(test_job, past_time, job_store)
			destination = ready_list.key
			client.script(:flush)
			
			count = delayed_jobs.move(destination:)
			
			expect(count).to be == 1
			expect(client.lpop(destination)).to be == job_id
		end
		
		it "retries NOSCRIPT only once" do
			failing_client = Class.new do
				attr :evalsha_count
				attr :script_load_count
				
				def initialize
					@evalsha_count = 0
					@script_load_count = 0
				end
				
				def script(subcommand, source = nil)
					@script_load_count += 1
					source
				end
				
				def evalsha(*)
					@evalsha_count += 1
					raise Protocol::Redis::ServerError, "NOSCRIPT No matching script."
				end
			end.new
			failing_delayed_jobs = subject.new(failing_client, "#{prefix}:failing")
			
			expect do
				failing_delayed_jobs.move(destination: ready_list.key)
			end.to raise_exception(Protocol::Redis::ServerError)
			
			expect(failing_client.evalsha_count).to be == 2
			expect(failing_client.script_load_count).to be == 3
		end
	end
	
	with "#start" do
		it "can start the background processing task" do
			# Add a job that will become ready during the test
			near_future = Time.now + 0.5  # Half second from now
			job_id = delayed_jobs.add(test_job, near_future, job_store)
			
			# Start the delayed job processor with high resolution for fast testing
			task = delayed_jobs.start(ready_list, resolution: 0.1)
			
			_, ready_job_id = client.blpop(ready_list.key, 1)
			expect(ready_job_id).to be == job_id
			
			# Verify the job was moved (it should no longer be in delayed queue)
			remaining_score = client.zscore(delayed_jobs.key, job_id)
			expect(remaining_score).to be_nil
		ensure
			task&.stop
		end
		
		it "logs debug messages when moving jobs" do
			# Add a ready job
			past_time = Time.now - 60
			job_id = delayed_jobs.add(test_job, past_time, job_store)
			
			# Start the processor briefly to capture console output
			task = delayed_jobs.start(ready_list, resolution: 0.1)
			
			# Wait for one processing cycle
			sleep(0.2)
			
			# Stop the task
			task.stop
			
			# Check for debug log message
			expect_console.to have_logged(
				severity: be == :debug,
				message: be(:include?, "Moved 1 delayed jobs to ready list")
			)
		end
		
		it "retries failed promotions and reports recovery" do
			attempts = 0
			events = []
			instrumentation = proc{|event, **details| events << [event, details]}
			
			delayed_jobs.define_singleton_method(:move) do |destination:|
				attempts += 1
				raise "Redis unavailable" if attempts == 1
				
				0
			end
			
			task = delayed_jobs.start(ready_list, resolution: 60, instrumentation:)
			
			Async::Task.current.with_timeout(2) do
				sleep(0.01) until attempts >= 2
			end
			task.stop
			
			expect(events).to have_attributes(size: be == 2)
			expect(events[0]).to have_attributes(
				first: be == :failure,
				last: have_keys(
					error: be_a(RuntimeError),
					consecutive_failures: be == 1,
					retry_in_seconds: be == 0.25,
				),
			)
			expect(events[1]).to be == [:recovered, {consecutive_failures: 1}]
			
			expect_console.to have_logged(
				severity: be == :warn,
				message: be(:include?, "Delayed job promotion failed"),
			)
			expect_console.to have_logged(
				severity: be == :info,
				message: be(:include?, "Delayed job promotion recovered"),
			)
		ensure
			task&.stop
		end
		
		it "continues when instrumentation fails" do
			attempts = 0
			instrumentation = proc do
				raise "Instrumentation unavailable"
			end
			
			delayed_jobs.define_singleton_method(:move) do |destination:|
				attempts += 1
				raise "Redis unavailable" if attempts == 1
				
				0
			end
			
			task = delayed_jobs.start(ready_list, resolution: 60, instrumentation:)
			
			Async::Task.current.with_timeout(2) do
				sleep(0.01) until attempts >= 2
			end
			expect(task).not.to be(:finished?)
		ensure
			task&.stop
		end
		
		it "caps exponential retry delays" do
			expect(delayed_jobs.send(:retry_delay, 1)).to be == 0.25
			expect(delayed_jobs.send(:retry_delay, 2)).to be == 0.5
			expect(delayed_jobs.send(:retry_delay, 10)).to be == 5
		end
		
		it "does not report task cancellation as a promoter failure" do
			events = []
			task = delayed_jobs.start(
				ready_list,
				resolution: 60,
				instrumentation: proc{|event, **details| events << [event, details]},
			)
			
			sleep(0.01)
			task.stop
			
			expect(events).to be(:empty?)
		ensure
			task&.stop
		end
	end
end
