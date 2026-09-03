# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "async"
require "async/redis"

require "sus/fixtures/async/reactor_context"
require "sus/fixtures/console"

require "async/job/processor/redis/processing_list"
require "async/job/processor/redis/ready_list"
require "async/job/processor/redis/job_store"

describe Async::Job::Processor::Redis::ProcessingList do
	include Sus::Fixtures::Async::ReactorContext
	include Sus::Fixtures::Console::CapturedLogger
	
	let(:client) {Async::Redis::Client.new}
	let(:prefix) {"test-processing-#{SecureRandom.hex(8)}"}
	let(:server_id) {"server-#{SecureRandom.hex(4)}"}
	let(:ready_list) {Async::Job::Processor::Redis::ReadyList.new(client, "#{prefix}:ready")}
	let(:job_store) {Async::Job::Processor::Redis::JobStore.new(client, "#{prefix}:jobs")}
	let(:processing_list) {subject.new(client, "#{prefix}:processing", server_id, ready_list, job_store)}
	
	let(:test_job) {JSON.dump({"data" => "test processing job"})}
	let(:job_id) {"job-#{SecureRandom.hex(8)}"}
	
	with "a ready job" do
		before do
			# Add a test job to the job store
			client.hset(job_store.key, job_id, test_job)
			# Add the job to the ready list
			client.lpush(ready_list.key, job_id)
		end
		
		with "#fetch" do
			it "can fetch a job from ready list to pending list" do
				# Fetch should move job from ready list to pending list
				fetched_id = processing_list.fetch
				
				expect(fetched_id).to be == job_id
				
				# Verify job was removed from ready list
				ready_job = client.lpop(ready_list.key)
				expect(ready_job).to be_nil
				
				# Verify job was added to pending list
				pending_key = "#{prefix}:processing:#{server_id}:pending"
				pending_job = client.lpop(pending_key)
				expect(pending_job).to be == job_id
			end
		end
		
		with "#complete" do
			it "can complete a job by removing it from pending and job store" do
				# First, fetch the job to put it in pending
				processing_list.fetch
				
				# Complete the job
				processing_list.complete(job_id)
				
				# Verify job was removed from pending list
				pending_key = "#{prefix}:processing:#{server_id}:pending"
				pending_job = client.lpop(pending_key)
				expect(pending_job).to be_nil
				
				# Verify job was removed from job store
				stored_job = client.hget(job_store.key, job_id)
				expect(stored_job).to be_nil
			end
		end
		
		with "#retry" do
			it "can retry a job and emit console warning" do
				# First, fetch the job to put it in pending
				processing_list.fetch
				
				# Retry the job
				processing_list.retry(job_id)
				
				# Verify job was removed from pending list
				pending_key = "#{prefix}:processing:#{server_id}:pending"
				pending_job = client.lpop(pending_key)
				expect(pending_job).to be_nil
				
				# Verify job was moved back to ready list
				ready_job = client.lpop(ready_list.key)
				expect(ready_job).to be == job_id
				
				# Verify console warning was emitted
				expect_console.to have_logged(severity: be(:==, :warn), message: be(:include?, "Retrying job: #{job_id}"))
			end
		end
	end
	
	with "#requeue" do
		it "can set heartbeat and requeue abandoned jobs" do
			# Set up abandoned jobs to test requeue functionality
			dead_server_id = "dead-server-#{SecureRandom.hex(4)}"
			dead_pending_key = "#{prefix}:processing:#{dead_server_id}:pending"
			abandoned_job_id = "abandoned-#{SecureRandom.hex(8)}"
			client.lpush(dead_pending_key, abandoned_job_id)
			
			# Make sure the dead server has no heartbeat (simulating it being gone)
			client.del("#{prefix}:processing:#{dead_server_id}")
			
			# Call the requeue method directly with test parameters
			start_time = Time.now.to_f
			count = processing_list.requeue(start_time, 0.1, 2)
			
			# Verify it found and requeued the abandoned job
			expect(count).to be == 1
			
			# Verify heartbeat was set
			heartbeat_key = processing_list.heartbeat_key
			heartbeat_data = client.get(heartbeat_key)
			expect(heartbeat_data).not.to be_nil
			
			# Verify heartbeat structure
			heartbeat = JSON.parse(heartbeat_data)
			expect(heartbeat).to have_keys("uptime" => be_a(Numeric))
			expect(heartbeat["uptime"]).to be >= 0.0
			
			# Verify the abandoned job was moved to ready list
			ready_job = client.lpop(ready_list.key)
			expect(ready_job).to be == abandoned_job_id
		end
		
		it "returns zero when no jobs need requeuing" do
			# Call the requeue method with no abandoned jobs present
			start_time = Time.now.to_f
			count = processing_list.requeue(start_time, 0.1, 2)
			
			# Should return 0 when no jobs are requeued
			expect(count).to be == 0
		end
	end
	
	with "#start" do
		it "can requeue an abandoned job" do
			# Set up abandoned jobs to test requeue functionality
			dead_server_id = "dead-server-#{SecureRandom.hex(4)}"
			dead_pending_key = "#{prefix}:processing:#{dead_server_id}:pending"
			abandoned_job_id = "abandoned-#{SecureRandom.hex(8)}"
			client.lpush(dead_pending_key, abandoned_job_id)
			
			# Make sure the dead server has no heartbeat (simulating it being gone)
			client.del("#{prefix}:processing:#{dead_server_id}")
			
			task = processing_list.start(delay: 0.1, factor: 2)
			
			fetched_job = processing_list.fetch
			expect(fetched_job).to be == abandoned_job_id
		ensure
			processing_list.stop
		end
		
		it "owns a single background task" do
			task = processing_list.start(delay: 1)
			
			expect(task.alive?).to be == true
			expect(processing_list.start(delay: 1)).to be == false
			
			processing_list.stop
			expect(task.finished?).to be == true
			
			restarted_task = processing_list.start(delay: 1)
			expect(restarted_task).not.to be == false
		ensure
			processing_list.stop
		end
	end
end
