# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

require_relative "redis/server"
require "async/redis/client"

# @namespace
module Async
	# @namespace
	module Job
		# @namespace
		module Processor
			# Redis-based job processor implementation.
			# Provides distributed job processing capabilities using Redis as the backend.
			module Redis
				# Create a new Redis job processor server.
				# @parameter delegate [Object] The delegate object that will process jobs.
				# @parameter endpoint [Async::Redis::Endpoint] The Redis endpoint to connect to.
				# @parameter options [Hash] Additional options passed to the server.
				# @returns [Server] A new Redis job processor server instance.
				def self.new(delegate, endpoint: Async::Redis.local_endpoint, **options)
					client = Async::Redis::Client.new(endpoint)
					return Server.new(delegate, client, **options)
				end
			end
		end
	end
end
