# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

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
	let(:server) {subject.new(buffer, prefix:, resolution: 1, limit: 1)}

	before do
		server.start
	end

	after do
		server.stop
	end

	let(:job) {{"data" => "test job"}}

	with "a concurrency limit" do
		it "claims at most limit jobs at a time" do
			current = 0
			peak = 0

			mock(buffer) do |mock|
				mock.before(:call) do |job|
					current += 1
					peak = [peak, current].max
					sleep(0.01)
					current -= 1
				end
			end

			4.times {|index| server.call(job.merge("index" => index))}

			4.times {buffer.pop}

			expect(peak).to be == 1
		end
	end

	with "#drain" do
		it "stops fetching but waits for running jobs to finish" do
			started = 0

			mock(buffer) do |mock|
				mock.before(:call) do |job|
					started += 1
					sleep(0.05)
				end
			end

			4.times {|index| server.call(job.merge("index" => index))}

			# Wait for the first job to start:
			until started == 1
				sleep(0.001)
			end

			expect(server.drain(timeout: 5)).to be == true

			# The running job finished:
			expect(buffer.pop).to have_keys("data" => be == job["data"])

			# No further jobs were claimed after the drain:
			sleep(0.1)
			expect(started).to be == 1
		end
	end
end
