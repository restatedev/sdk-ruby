# typed: true
# frozen_string_literal: true

#
# Example: Service Communication
#
# Shows how services call each other through Restate.
# All inter-service calls are durable — if the caller crashes,
# Restate replays the call and delivers the result.
#
# Features:
#   - ctx.service_call  — typed RPC that returns a DurableCallFuture
#   - ctx.service_send  — fire-and-forget (optionally delayed)
#   - Fan-out/fan-in    — launch concurrent calls, collect results
#   - ctx.wait_any      — race multiple futures, handle first completer
#   - ctx.awakeable     — pause until an external system calls back
#
# Try it:
#   curl localhost:8080/FanOut/run \
#     -H 'content-type: application/json' \
#     -d '["task_a", "task_b", "task_c"]'

require 'restate'

# A simple worker that simulates processing a task.
class Worker < Restate::Service
  handler def process(ctx, task)
    ctx.run_sync('do-work') do
      { 'task' => task, 'result' => "completed_#{task}" }
    end
  end
end

# Fan-out: dispatch tasks in parallel, collect all results.
class FanOut < Restate::Service
  handler def run(ctx, tasks)
    # Launch a call for each task
    futures = tasks.map do |task|
      ctx.service_call(Worker, :process, task)
    end

    # Fan-in: await all results
    results = futures.map(&:await)

    # Fire-and-forget: schedule a delayed cleanup (runs after 60 s)
    ctx.service_send(Worker, :process, 'cleanup', delay: 60.0)

    { 'results' => results }
  end

  # Race two calls and return the first result.
  handler def race(ctx, tasks)
    futures = tasks.map do |task|
      ctx.service_call(Worker, :process, task)
    end

    # wait_any returns [completed, remaining]
    completed, _remaining = ctx.wait_any(*futures)
    completed.first.await
  end

  # Awakeable: pause until an external system resolves the callback.
  handler def with_callback(ctx, task)
    awakeable_id, future = ctx.awakeable

    # Send the awakeable ID to an external system (via a side effect)
    ctx.run_sync('notify-external') do
      puts "External system should POST to Restate to resolve: #{awakeable_id}"
    end

    # Block until the external system resolves the awakeable
    callback_result = future.await

    { 'task' => task, 'callback_result' => callback_result }
  end
end
