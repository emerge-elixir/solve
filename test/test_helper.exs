ExUnit.start()

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: SolveTest.PubSub)
{:ok, _} = SolveTest.Endpoint.start_link()
