require "../config"

class RootController < Application
  base "/"

  get "/healthz", :healthz do
    head :ok
  end

  get "/version", :version do
    render json: {
      app:     APP_NAME,
      version: VERSION,
    }
  end
end
