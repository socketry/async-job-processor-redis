# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

module Async
	module Job
		module Processor
			module Redis
				# Stores job data using Redis hashes.
				# Provides persistent storage for job payloads indexed by job ID.
				class JobStore
					# Initialize a new job store.
					# @parameter client [Async::Redis::Client] The Redis client instance.
					# @parameter key [String] The Redis key for the job data hash.
					def initialize(client, key)
						@client = client
						@key = key
					end
					
					# @attribute [String] The Redis key for this job store.
					attr :key
					
					# Retrieve job data by ID.
					# @parameter id [String] The job ID to retrieve.
					# @returns [String, nil] The serialized job data, or nil if not found.
					def get(id)
						@client.hget(@key, id)
					end
				end
			end
		end
	end
end
