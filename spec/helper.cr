require "spec"
require "json"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/hound-dog"
require "../src/hound-dog/*"

Spec.before_suite do
  ::Log.setup "*", :trace
end
