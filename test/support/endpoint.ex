defmodule SolveTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :solve

  @session_options [
    store: :cookie,
    key: "_solve_test",
    signing_salt: "test_salt"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(SolveTest.Router)
end
