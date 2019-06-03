# Application dependencies
require "action-controller"
require "active-model"

# Application code
require "./controllers/application"
require "./controllers/*"

# Server required after application controllers
require "action-controller/server"

# Add handlers that should run before your application
ActionController::Server.before(
  HTTP::LogHandler.new(STDOUT),
  HTTP::ErrorHandler.new(ENV["SG_ENV"]? != "production"),
  HTTP::CompressHandler.new
)

APP_NAME = "hound-dog"
VERSION  = "1.0.0"
