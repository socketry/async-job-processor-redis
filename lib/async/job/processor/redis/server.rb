# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

require "async/idler"
require "async/job/coder"
require "async/job/processor/generic"

require "securerandom"

require_relative "delayed_jobs"
require_relative "job_store"
require_relative "processing_list"
require_relative "ready_list"

module Async
	module Job
		module Processor
			module Redis
				# Redis-backed job processor server.
				# Manages job queues using Redis for distributed job processing across multiple workers.
				# Handles immediate jobs, delayed jobs, and job retry/recovery mechanisms.
				class Server < Generic
					# Initialize a new Redis job processor server.
					# @parameter delegate [Object] The delegate object that will process jobs.
					# @parameter client [Async::Redis::Client] The Redis client instance.
					# @parameter prefix [String] The Redis key prefix for job data.
					# @parameter coder [Async::Job::Coder] The job serialization codec.
					# @parameter resolution [Integer] The resolution in seconds for delayed job processing.
					# @parameter retry_delay [Numeric] The initial delay before retrying a failed dequeue operation.
					# @parameter retry_delay_limit [Numeric] The maximum delay between failed dequeue operations.
					# @parameter parent [Async::Task] The parent task for background processing.
					def initialize(delegate, client, prefix: "async-job", coder: Coder::DEFAULT, resolution: 10, retry_delay: 1, retry_delay_limit: 30, parent: nil)
						super(delegate)
						
						@id = SecureRandom.uuid
						@client = client
						@prefix = prefix
						@coder = coder
						@resolution = resolution
						@retry_delay = retry_delay
						@retry_delay_limit = retry_delay_limit
						
						@job_store = JobStore.new(@client, "#{@prefix}:jobs")
						@delayed_jobs = DelayedJobs.new(@client, "#{@prefix}:delayed")
						@ready_list = ReadyList.new(@client, "#{@prefix}:ready")
						@processing_list = ProcessingList.new(@client, "#{@prefix}:processing", @id, @ready_list, @job_store)
						
						@parent = parent || Async::Idler.new
					end
					
					# Start the job processing loop immediately.
					# @returns [Async::Task | false] The processing task or false if already started.
					def start!
						return false if @task
						
						@task = true
						
						@parent.async(transient: true, annotation: self.class.name) do |task|
							@task = task
							
							self.run(task)
						ensure
							@task = nil
						end
					end
					
					# Start the server and all background processing tasks.
					# Initializes delayed job processing, abandoned job recovery, and the main processing loop.
					def start
						super
						
						# Start the delayed processor, which will move jobs to the ready processor when they are ready:
						@delayed_jobs.start(@ready_list, resolution: @resolution)
						
						# Start the processing processor, which will move jobs to the ready processor when they are abandoned:
						@processing_list.start
						
						self.start!
					end
					
					# Stop the server and all background processing tasks.
					def stop
						@task&.stop
						
						super
					end
					
					# Generates a human-readable string representing the current statistics.
					#
					# e.g. `R=3.42K D=1.23K P=7/2.34K``
					#
					# This can be interpreted as:
					#
					# - R: Number of jobs in the ready list
					# - D: Number of jobs in the delayed queue
					# - P: Number of jobs currently being processed / total number of completed jobs.
					#
					# @returns [String] A string representing the current statistics.
					def status_string
						"R=#{format_count(@ready_list.size)} D=#{format_count(@delayed_jobs.size)} P=#{format_count(@processing_list.size)}/#{format_count(@processing_list.complete_count)}"
					end
					
					# Submit a new job for processing.
					# Jobs with a scheduled_at time are queued for delayed processing, while immediate jobs are added to the ready queue.
					# @parameter job [Hash] The job data to process.
					def call(job)
						scheduled_at = Coder::Time(job["scheduled_at"])
						
						if scheduled_at
							@delayed_jobs.add(@coder.dump(job), scheduled_at, @job_store)
						else
							@ready_list.add(@coder.dump(job), @job_store)
						end
					end
					
				protected
					
					# Run the dequeue loop, retrying transient failures with bounded exponential backoff.
					# @parameter parent [Async::Task] The parent task used to process dequeued jobs.
					def run(parent)
						retry_delay = @retry_delay
						
						while true
							begin
								self.dequeue(parent)
								retry_delay = @retry_delay
							rescue => error
								delay = retry_delay * (0.5 + rand * 0.5)
								
								Console.error(self, "Failed to dequeue job; retrying.", retry_in: delay, exception: error)
								sleep(delay)
								
								retry_delay = [retry_delay * 2, @retry_delay_limit].min
							end
						end
					end
					
					# Dequeue a job from the ready list and process it.
					#
					# If the job fails for any reason, it will be retried.
					#
					# If you do not desire this behavior, you should catch exceptions in the delegate.
					def dequeue(parent)
						_id = @processing_list.fetch
						
						parent.async do
							id = _id; _id = nil
							
							job = @coder.load(@job_store.get(id))
							@delegate.call(job)
							@processing_list.complete(id)
						rescue => error
							Console.error(self, "Job failed with error!", id: id, exception: error)
							@processing_list.retry(id)
						end
					ensure
						@processing_list.retry(_id) if _id
					end
					
					private
					
					def format_count(value)
						if value > 1_000_000
							"#{(value/1_000_000.0).round(2)}M"
						elsif value > 1_000
							"#{(value/1_000.0).round(2)}K"
						else
							value
						end
					end
				end
			end
		end
	end
end
