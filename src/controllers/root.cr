require "../config"

class RootController < Application
  base "/"

  get "/ping", :ping do
    render text: "pong"
  end

  get "/version", :version do
    render json: {
      version: VERSION,
    }
  end
end
