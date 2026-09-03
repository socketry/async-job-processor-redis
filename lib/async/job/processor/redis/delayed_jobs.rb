# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

module Async
	module Job
		module Processor
			module Redis
				# Manages delayed job scheduling using Redis sorted sets.
				# Jobs are stored with their execution timestamps and automatically moved
				# to the ready queue when their scheduled time arrives.
				class DelayedJobs
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
						@task = nil
					end
					
					# @returns [Integer] The number of jobs currently in the delayed queue.
					def size
						@client.zcard(@key)
					end
					
					# Start the background task that moves ready delayed jobs to the ready queue.
					# @parameter ready_list [ReadyList] The ready list to move jobs to.
					# @parameter resolution [Integer] The check interval in seconds.
					# @parameter parent [Async::Task] The parent task to run the background loop in.
					# @returns [Async::Task | false] The background processing task, or false if already started.
					def start(ready_list, resolution: 10, parent: Async::Task.current)
						return false if @task
						
						# Reserve ownership before spawning because Async tasks may begin eagerly.
						@task = true
						
						task = parent.async do |task|
							@task = task
							
							while true
								count = move(destination: ready_list.key)
								
								if count > 0
									Console.debug(self, "Moved #{count} delayed jobs to ready list.")
								end
								
								sleep(resolution)
							end
						ensure
							@task = nil if @task.equal?(task)
						end
						
						# A non-greedy parent may return before the child assigns its handle.
						@task = task if @task == true
						return task
					rescue
						@task = nil
						raise
					end
					
					# Stop the owned delayed job promotion task.
					def stop
						task = @task
						@task = nil
						return unless task.respond_to?(:stop)
						
						task.stop
						task.wait if task.alive?
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
					end
				end
			end
		end
	end
end
