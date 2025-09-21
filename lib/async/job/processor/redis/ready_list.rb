# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

module Async
	module Job
		module Processor
			module Redis
				# Manages the queue of jobs ready for immediate processing.
				# Jobs are stored in Redis lists with FIFO (first-in, first-out) ordering.
				class ReadyList
					ADD = <<~LUA
						redis.call('HSET', KEYS[1], ARGV[1], ARGV[2])
						redis.call('LPUSH', KEYS[2], ARGV[1])
					LUA
					
					# Initialize a new ready list manager.
					# @parameter client [Async::Redis::Client] The Redis client instance.
					# @parameter key [String] The Redis key for the ready job list.
					def initialize(client, key)
						@client = client
						@key = key
						
						@add = @client.script(:load, ADD)
					end
					
					# @attribute [String] The Redis key for this ready list.
					attr :key
					
					# @returns [Integer] The number of jobs currently in the ready list.
					def size
						@client.llen(@key)
					end
					
					# Add a new job to the ready queue.
					# @parameter job [String] The serialized job data.
					# @parameter job_store [JobStore] The job store to save the job data.
					# @returns [String] The unique job ID.
					def add(job, job_store)
						id = SecureRandom.uuid
						
						@client.evalsha(@add, 2, job_store.key, @key, id, job)
						
						return id
					end
				end
			end
		end
	end
end
