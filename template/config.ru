# frozen_string_literal: true

#
# Start the server:
#   bundle exec falcon serve --bind http://localhost:9080
#
# Register with Restate:
#   restate deployments register http://localhost:9080
#
# Invoke:
#   curl localhost:8080/Greeter/greet \
#     -H 'content-type: application/json' \
#     -d '"World"'
#

require_relative 'greeter'

endpoint = Restate.endpoint(Greeter)

run endpoint.app
