defmodule KbaseBot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KbaseBot.Repo.Store,
      KbaseBot.Context.Server,
      KbaseBot.Memory.Embedder,
      KbaseBot.Ingress,
      KbaseBot.Manager,
      {Elixir.Task.Supervisor, name: KbaseBot.TaskSupervisor},
      ExGram,
      {KbaseBot.Telegram.Bot, [method: :polling, token: ExGram.Config.get(:ex_gram, :token)]},
      KbaseBot.Scheduler.Scheduler
    ]

    opts = [strategy: :one_for_one, name: KbaseBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
