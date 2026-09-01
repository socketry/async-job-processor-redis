# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

require "async/barrier"
require "async/idler"
require "async/job/coder"
require "async/job/processor/generic"
require "async/semaphore"

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
					# @parameter parent [Async::Task] The parent task for background processing.
					# @parameter limit [Integer | Nil] The maximum number of jobs claimed and processed at once, or nil for no limit.
					def initialize(delegate, client, prefix: "async-job", coder: Coder::DEFAULT, resolution: 10, parent: nil, limit: nil)
						super(delegate)

						@id = SecureRandom.uuid
						@client = client
						@prefix = prefix
						@coder = coder
						@resolution = resolution

						@job_store = JobStore.new(@client, "#{@prefix}:jobs")
						@delayed_jobs = DelayedJobs.new(@client, "#{@prefix}:delayed")
						@ready_list = ReadyList.new(@client, "#{@prefix}:ready")
						@processing_list = ProcessingList.new(@client, "#{@prefix}:processing", @id, @ready_list, @job_store)

						@parent = parent || Async::Idler.new

						# Limits how many jobs are claimed (moved into this server's pending list) and processed at once. Without a limit, jobs are fetched as fast as they arrive and buffered in this process, which hides the backlog from the ready list, grows memory with the backlog, and abandons every buffered job on shutdown.
						@semaphore = limit && Async::Semaphore.new(limit)

						# Jobs run on their own tasks, tracked separately from the fetch loop so that stopping the loop (see #drain) does not cancel jobs that are already running.
						@jobs = Async::Barrier.new
					end

					# @attribute [Async::Semaphore | Nil] The concurrency limit semaphore, if a limit was given.
					attr :semaphore
					
					# Start the job processing loop immediately.
					# @returns [Async::Task | false] The processing task or false if already started.
					def start!
						return false if @task

						@task = true

						# Host job tasks outside the fetch loop's task tree, so that stopping the loop (see #drain) does not cancel running jobs:
						@job_host ||= @parent.async(transient: true, annotation: "#{self.class.name} jobs") {sleep}

						@parent.async(transient: true, annotation: self.class.name) do |task|
							@task = task

							while true
								self.dequeue(task)
							end
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
					
					# Stop the server and all background processing tasks, including any running jobs.
					def stop
						@task&.stop
						@jobs.stop
						@job_host&.stop
						@job_host = nil

						super
					end

					# Stop fetching new jobs and wait for running jobs to finish.
					#
					# Jobs that do not finish within the timeout are left running; a subsequent {stop} cancels them and they will be recovered as abandoned jobs. Without a timeout, waits indefinitely.
					#
					# @parameter timeout [Numeric | Nil] The maximum time to wait for running jobs to finish.
					# @returns [Boolean] True if all running jobs finished.
					def drain(timeout: nil)
						@task&.stop

						if timeout
							Task.current.with_timeout(timeout) do
								@jobs.wait
								true
							rescue Async::TimeoutError
								false
							end
						else
							@jobs.wait
							true
						end
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
					
					# Dequeue a job from the ready list and process it.
					#
					# If a limit was given, waits for a slot before claiming the next job, so at most `limit` jobs are claimed at once and any backlog stays in the ready list.
					#
					# If the job fails for any reason, it will be retried.
					#
					# If you do not desire this behavior, you should catch exceptions in the delegate.
					def dequeue(parent)
						@semaphore&.acquire

						begin
							id = @processing_list.fetch

							@jobs.async(parent: @job_host) do
								job = @coder.load(@job_store.get(id))
								@delegate.call(job)
								@processing_list.complete(id)
							rescue => error
								Console.error(self, "Job failed with error!", id: id, exception: error)
								@processing_list.retry(id)
							ensure
								@semaphore&.release
							end
						rescue Exception
							# The job (if claimed) was never handed to a task; put it back and release the slot:
							@processing_list.retry(id) if id
							@semaphore&.release
							raise
						end
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
