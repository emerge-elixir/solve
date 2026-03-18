import Config

config :phoenix, :json_library, Jason

config :solve, SolveTest.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test_salt"],
  pubsub_server: SolveTest.PubSub,
  server: false
