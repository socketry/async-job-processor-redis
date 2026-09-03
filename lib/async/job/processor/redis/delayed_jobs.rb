# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

require "protocol/redis/error"

module Async
	module Job
		module Processor
			module Redis
				# Manages delayed job scheduling using Redis sorted sets.
				# Jobs are stored with their execution timestamps and automatically moved
				# to the ready queue when their scheduled time arrives.
				class DelayedJobs
					INITIAL_RETRY_DELAY = Float(ENV.fetch("ASYNC_JOB_PROCESSOR_REDIS_DELAYED_JOBS_INITIAL_RETRY_DELAY", 0.25))
					MAXIMUM_RETRY_DELAY = Float(ENV.fetch("ASYNC_JOB_PROCESSOR_REDIS_DELAYED_JOBS_MAXIMUM_RETRY_DELAY", 5))
					
					ADD = <<~LUA
						redis.call('HSET', KEYS[1], ARGV[1], ARGV[2])
						redis.call('ZADD', KEYS[2], ARGV[3], ARGV[1])
					LUA
					
					MOVE = <<~LUA
						local jobs = redis.call('ZRANGEBYSCORE', KEYS[1], 0, ARGV[1])
						redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, ARGV[1])
						if #jobs > 0 then
							redis.call('LPUSH', KEYS[2], unpack(jobs))
						end
						return #jobs
					LUA
					
					# Initialize a new delayed jobs manager.
					# @parameter client [Async::Redis::Client] The Redis client instance.
					# @parameter key [String] The Redis key for the delayed jobs sorted set.
					def initialize(client, key)
						@client = client
						@key = key
						
						@add = @client.script(:load, ADD)
						@move = @client.script(:load, MOVE)
					end
					
					# @returns [Integer] The number of jobs currently in the delayed queue.
					def size
						@client.zcard(@key)
					end
					
					# Start the background task that moves ready delayed jobs to the ready queue.
					# @parameter ready_list [ReadyList] The ready list to move jobs to.
					# @parameter resolution [Integer] The check interval in seconds.
					# @parameter parent [Async::Task] The parent task to run the background loop in.
					# @parameter instrumentation [Interface(:call) | Nil] An optional callback for promoter failure and recovery events.
					# @returns [Async::Task] The background processing task.
					def start(ready_list, resolution: 10, parent: Async::Task.current, instrumentation: nil)
						parent.async do
							consecutive_failures = 0
							
							loop do
								count = move(destination: ready_list.key)
								
								if consecutive_failures > 0
									report_recovery(instrumentation, consecutive_failures)
									consecutive_failures = 0
								end
								
								if count > 0
									Console.debug(self, "Moved #{count} delayed jobs to ready list.")
								end
								
								sleep(resolution)
							rescue Async::Stop
								raise
							rescue => error
								consecutive_failures += 1
								retry_in_seconds = retry_delay(consecutive_failures)
								report_failure(instrumentation, error, consecutive_failures, retry_in_seconds)
								sleep(retry_in_seconds)
							end
						end
					end
					
					# @attribute [String] The Redis key for this delayed jobs queue.
					attr :key
					
					# Add a job to the delayed queue with a specified execution time.
					# @parameter job [String] The serialized job data.
					# @parameter timestamp [Time] When the job should be executed.
					# @parameter job_store [JobStore] The job store to save the job data.
					# @returns [String] The unique job ID.
					def add(job, timestamp, job_store)
						id = SecureRandom.uuid
						
						@client.evalsha(@add, 2, job_store.key, @key, id, job, timestamp.to_f)
						
						return id
					end
					
					# Move jobs that are ready to be processed from the delayed queue to the destination.
					# @parameter destination [String] The Redis key of the destination queue.
					# @parameter now [Integer] The current timestamp to check against.
					# @returns [Integer] The number of jobs moved.
					def move(destination:, now: Time.now.to_f)
						@client.evalsha(@move, 2, @key, destination, now)
					rescue Protocol::Redis::ServerError => error
						raise unless error.message.start_with?("NOSCRIPT")
						
						@move = @client.script(:load, MOVE)
						@client.evalsha(@move, 2, @key, destination, now)
					end
					
					private
					
					def retry_delay(consecutive_failures)
						[INITIAL_RETRY_DELAY * (2 ** (consecutive_failures - 1)), MAXIMUM_RETRY_DELAY].min
					end
					
					def report_failure(instrumentation, error, consecutive_failures, retry_in_seconds)
						Console.warn(
							self,
							"Delayed job promotion failed; retrying in #{retry_in_seconds} seconds.",
							error,
							consecutive_failures:,
							retry_in_seconds:,
						)
					rescue
						# Logging must not terminate the promoter:
					ensure
						instrument(instrumentation, :failure, error:, consecutive_failures:, retry_in_seconds:)
					end
					
					def report_recovery(instrumentation, consecutive_failures)
						Console.info(self, "Delayed job promotion recovered.", consecutive_failures:)
					rescue
						# Logging must not terminate the promoter:
					ensure
						instrument(instrumentation, :recovered, consecutive_failures:)
					end
					
					def instrument(instrumentation, event, **details)
						instrumentation&.call(event, **details)
					rescue
						# Instrumentation must not terminate the promoter:
					end
				end
			end
		end
	end
end
