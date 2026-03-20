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
#   - Service.call.handler(arg)  — fluent typed RPC (returns DurableCallFuture)
#   - Service.send!.handler(arg) — fluent fire-and-forget (optionally delayed)
#   - Restate.service_call / Restate.service_send — explicit RPC (same thing, verbose)
#   - Fan-out/fan-in             — launch concurrent calls, collect results
#   - Restate.wait_any           — race multiple futures, handle first completer
#   - Restate.awakeable          — pause until an external system calls back
#
# Try it:
#   curl localhost:8080/FanOut/run \
#     -H 'content-type: application/json' \
#     -d '["task_a", "task_b", "task_c"]'

require 'restate'

# A simple worker that simulates processing a task.
class Worker < Restate::Service
  handler def process(task)
    Restate.run_sync('do-work') do
      { 'task' => task, 'result' => "completed_#{task}" }
    end
  end
end

# Fan-out: dispatch tasks in parallel, collect all results.
class FanOut < Restate::Service
  handler def run(tasks)
    # Fluent API: launch a call for each task
    futures = tasks.map do |task|
      Worker.call.process(task)
    end

    # Fan-in: await all results
    results = futures.map(&:await)

    # Fluent fire-and-forget: schedule a delayed cleanup (runs after 60 s)
    Worker.send!(delay: 60).process('cleanup')

    { 'results' => results }
  end

  # Race two calls and return the first result.
  handler def race(tasks)
    futures = tasks.map do |task|
      Worker.call.process(task)
    end

    # wait_any returns [completed, remaining]
    completed, _remaining = Restate.wait_any(*futures)
    completed.first.await
  end

  # Awakeable: pause until an external system resolves the callback.
  handler def with_callback(task)
    awakeable_id, future = Restate.awakeable

    # Send the awakeable ID to an external system (via a side effect)
    Restate.run_sync('notify-external') do
      puts "External system should POST to Restate to resolve: #{awakeable_id}"
    end

    # Block until the external system resolves the awakeable
    callback_result = future.await

    { 'task' => task, 'callback_result' => callback_result }
  end
end
