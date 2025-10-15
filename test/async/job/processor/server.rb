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

    it "records failure in <prefix>:dead and increments counters" do
      # Enqueue a job which fails once, then succeeds (same as previous test):
      server.call(job)
      failed = false

      mock(buffer) do |mock|
        mock.before(:call) do |job|
          unless failed
            failed = true
            raise "test error for observability"
          end
        end
      end

      # Consume the retried job so the loop progresses:
      buffer.pop

      # Give a moment for failure recording to be written:
      sleep 0.05

      client = Async::Redis::Client.new
      dead_key = "#{prefix}:dead"
      stat_failed = "#{prefix}:stat:failed"
      stat_processed = "#{prefix}:stat:processed"

      # Dead set should have at least one entry:
      count = client.call('ZCARD', dead_key).to_i
      expect(count).to be > 0

      # Latest entry should include error_class and error_message:
      entry = client.call('ZREVRANGE', dead_key, 0, 0)&.first
      data = JSON.parse(entry)
      expect(data).to have_keys(
        'error_class' => be == 'RuntimeError',
        'error_message' => be(:include?, 'test error for observability')
      )

      # Failed counter should be >= 1, processed >= 1 (after retry succeeds):
      failed_count = (client.call('GET', stat_failed) || '0').to_i
      processed_count = (client.call('GET', stat_processed) || '0').to_i
      expect(failed_count).to be >= 1
      expect(processed_count).to be >= 1
    end
  end
	
	with "#status_string" do
		it "returns a string with the current job counts" do
			expect(server.status_string).to be == "R=0 D=0 P=0/0"
			
			server.call(job)
			
			expect(server.status_string).to be == "R=0 D=0 P=0/1"
		end
	end
end
