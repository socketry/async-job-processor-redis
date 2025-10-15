# Redis Queue

This guide gives a brief overview of the implementation of the Redis queue.

## Overview

The Redis queue plays a pivotal role in facilitating a sophisticated and reliable job queue architecture, designed to handle diverse processing needs with efficiency and resilience. The architecture is thoughtfully split into three distinct components, each serving a critical function in the lifecycle of a job: the ready queue, the delayed queue, and the processing queue.

## Ready Queue

The ready queue is where jobs that are immediately available for processing are stored. When a job is submitted and is ready to be executed without any delay, it is placed into this queue. Worker processes constantly listen for new jobs on the ready queue, dequeuing and executing them as soon as they become available. This queue operates on a FIFO (First In, First Out) basis, ensuring that jobs are processed in the order they were received.

## Delayed Queue

The delayed queue holds jobs that are not meant to be executed immediately but at a specified future time. This functionality is crucial for tasks that need to be executed at a later stage, such as scheduled notifications or time-dependent processes. Jobs in the delayed queue are sorted according to their execution time. When possible, they are moved to the ready queue to be executed by the next available worker. This transition is managed through Redis's sorted sets, allowing efficient retrieval and management of timed events.

## Processing Queue

Once a job is dequeued from the ready queue, it enters the processing queue, signifying that it is currently being executed by a worker. The processing queue is crucial for tracking the progress of jobs and for ensuring that jobs can be retried or recovered in case of worker failure. Each worker emits a heartbeat, and if a worker fails to emit a heartbeat within a specified time, any jobs associated with that worker are automatically moved back to the ready queue for reprocessing.

## UI/Observability Keys (Optional)

For dashboards and operational UIs, the server can emit minimal, bounded metadata when jobs fail and when they are processed successfully:

- `async-job:dead` (ZSET) — failed jobs, newest first. Members are compact JSON with `jid`, `queue`, `class`, `args`, `error_class`, `error_message`, `error_backtrace[]`, `failed_at`.
- `async-job:stat:processed` (STRING) — total number of successfully processed jobs.
- `async-job:stat:failed` (STRING) — total number of failed job executions.

You can enable and configure this when constructing the server instance:

```ruby
server = Async::Job::Processor::Redis::Server.new(
		delegate, client,
		prefix: "async-job",
		stats: true,
		dead_enabled: true,
		dead_max: 1000,
		dead_timeout: nil,
		failure_backtrace_limit: 10
)
```

Example queries for a UI:

```bash
ZREVRANGE async-job:dead 0 19 WITHSCORES
GET async-job:stat:processed
GET async-job:stat:failed
SCAN 0 MATCH async-job:processing:* COUNT 100
```

Note: When used via the Active Job adapter, make sure the job executor re-raises exceptions so the processor can observe failures.
