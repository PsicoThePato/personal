defmodule KbaseBot.Manager do
  @moduledoc """
  The Manager is an LLM conversation layer — equivalent to aifred-web's actor_worker.
  It receives batched messages from Ingress, decides what to do via tool calls,
  and manages spawned tasks.

  The Manager itself IS an LLM conversation with tools for task management,
  journaling, scheduling, etc. No hardcoded routing.
  """
  use GenServer

  require Logger

  alias KbaseBot.LLM.{Client, Prompts}
  alias KbaseBot.Tasks.{Task, Session, Runner}
  alias KbaseBot.Tools.Registry

  @max_turns 10

  defstruct [
    :conversation_messages,
    :active_tasks,
    :chat_id
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # --- Public API (called from Ingress, returns immediately) ---

  def process(messages) do
    GenServer.cast(__MODULE__, {:process, messages})
  end

  def schedule_fire(payload) do
    GenServer.cast(__MODULE__, {:schedule_fire, payload})
  end

  # --- Server ---

  @impl true
  def init(_) do
    chat_id = Application.fetch_env!(:kbase_bot, :telegram_chat_id)
    conversation = load_conversation_history()

    Logger.info("Manager started with #{length(conversation)} messages in history")

    {:ok,
     %__MODULE__{
       conversation_messages: conversation,
       active_tasks: %{},
       chat_id: chat_id
     }}
  end

  @impl true
  def handle_cast({:process, messages}, state) do
    now = DateTime.now!("America/Sao_Paulo")
    time_str = Calendar.strftime(now, "%H:%M")
    day_name = day_of_week_name(Date.day_of_week(DateTime.to_date(now)))

    user_content =
      "[System] Current time: #{time_str} BRT (#{day_name})\n\n" <>
        Enum.map_join(messages, "\n", & &1)

    state = append_message(state, %{"role" => "user", "content" => user_content})
    state = run_manager_loop(state)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:schedule_fire, payload}, state) do
    user_content = "[System] Schedule fired:\n#{payload}"
    state = append_message(state, %{"role" => "user", "content" => user_content})
    state = run_manager_loop(state)

    {:noreply, state}
  end

  # Handle the Task.Supervisor.async_nolink ref message (ignore it)
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Handle DOWN messages from monitored tasks
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_complete, task_id, result}, state) do
    Logger.info("Task #{task_id} completed")

    {text, state} =
      case result do
        {:ok, session} ->
          text = Task.extract_last_assistant_text(session.task) || "(task completed with no text)"
          state = put_in(state.active_tasks, Map.delete(state.active_tasks, task_id))
          {text, state}

        {:error, reason} ->
          state = put_in(state.active_tasks, Map.delete(state.active_tasks, task_id))
          {"Task failed: #{inspect(reason)}", state}
      end

    # Inject task completion as a system notification and let manager respond
    notification = "[System] Background task #{task_id} completed.\nResult:\n#{text}"
    state = append_message(state, %{"role" => "user", "content" => notification})
    state = run_manager_loop(state)

    {:noreply, state}
  end

  # --- Manager LLM loop ---

  defp run_manager_loop(state, turn \\ 0) do
    if turn >= @max_turns do
      Logger.warning("Manager: max turns exceeded")
      state
    else
      tools = Registry.for_layer(:manager)
      system_prompt = Prompts.manager()

      case Client.chat(system_prompt, state.conversation_messages, tools: tools) do
        {:ok, response} ->
          state = append_message(state, %{"role" => "assistant", "content" => response["content"]})

          tool_calls = Client.extract_tool_calls(response)

          if tool_calls == [] do
            # LLM is done — no more tool calls
            state
          else
            # Execute tools, send results back, loop
            {results, state} = execute_manager_tools(tool_calls, state)

            tool_results =
              Enum.map(results, fn result ->
                block = %{
                  "type" => "tool_result",
                  "tool_use_id" => result.tool_use_id,
                  "content" => result.content
                }

                if result[:is_error], do: Map.put(block, "is_error", true), else: block
              end)

            state = append_message(state, %{"role" => "user", "content" => tool_results})
            run_manager_loop(state, turn + 1)
          end

        {:error, reason} ->
          Logger.error("Manager LLM call failed: #{inspect(reason)}")
          KbaseBot.Telegram.send_message(state.chat_id, "Something went wrong. Try again.")
          state
      end
    end
  end

  defp execute_manager_tools(tool_calls, state) do
    context = %{chat_id: state.chat_id, manager_pid: self(), active_tasks: state.active_tasks}

    {results, state} =
      Enum.map_reduce(tool_calls, state, fn %{id: id, name: name, input: input}, acc_state ->
        Logger.info("Manager tool: #{name}")

        case name do
          "spawn_task" ->
            {result, acc_state} = handle_spawn_task(input, acc_state)
            {%{tool_use_id: id, content: result}, acc_state}

          "cancel_task" ->
            {result, acc_state} = handle_cancel_task(input, acc_state)
            {%{tool_use_id: id, content: result}, acc_state}

          "message_task" ->
            {result, acc_state} = handle_message_task(input, acc_state)
            {%{tool_use_id: id, content: result}, acc_state}

          _ ->
            case Registry.execute(name, input, context) do
              {:ok, result} ->
                {%{tool_use_id: id, content: result}, acc_state}

              {:error, reason} ->
                {%{tool_use_id: id, content: "Error: #{reason}", is_error: true}, acc_state}
            end
        end
      end)

    {results, state}
  end

  defp handle_spawn_task(%{"description" => description}, state) do
    user_profile = KbaseBot.Context.Server.get_user_profile()
    system_prompt = Prompts.task_execution(user_profile)

    task = Task.new(:one_shot, description)
    session = Session.new(task, system_prompt)
    Task.save(task)

    # Spawn under TaskSupervisor
    manager_pid = self()

    Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
      Runner.run(session, manager_pid)
    end)

    state = put_in(state.active_tasks, Map.put(state.active_tasks, task.id, task))
    {"Task #{task.id} spawned.", state}
  end

  defp handle_cancel_task(%{"task_id" => task_id}, state) do
    case Map.get(state.active_tasks, task_id) do
      nil ->
        {"Task #{task_id} not found in active tasks.", state}

      _task ->
        # Mark as failed in DB
        case Task.find(task_id) do
          {:ok, task} ->
            task = Task.fail(task, "cancelled")
            Task.save(task)

          _ ->
            :ok
        end

        state = put_in(state.active_tasks, Map.delete(state.active_tasks, task_id))
        {"Task #{task_id} cancelled.", state}
    end
  end

  defp handle_message_task(%{"task_id" => task_id, "message" => message}, state) do
    case Task.find(task_id) do
      {:ok, task} when task.state in [:done, :failed] ->
        # Resume with follow-up
        user_profile = KbaseBot.Context.Server.get_user_profile()
        system_prompt = Prompts.task_execution(user_profile)

        task = Task.follow_up(task, message)
        session = Session.new(task, system_prompt)
        Task.save(task)

        manager_pid = self()

        Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
          Runner.run(session, manager_pid)
        end)

        state = put_in(state.active_tasks, Map.put(state.active_tasks, task_id, task))
        {"Message sent to task #{task_id}, resuming.", state}

      {:ok, _task} ->
        {"Task #{task_id} is currently running. Message will be processed when it completes.", state}

      {:error, :not_found} ->
        {"Task #{task_id} not found.", state}
    end
  end

  # --- Message persistence ---

  defp append_message(state, message) do
    messages = state.conversation_messages ++ [message]

    # Persist to SQLite
    content =
      case message["content"] do
        c when is_binary(c) -> c
        c -> Jason.encode!(c)
      end

    KbaseBot.Repo.Store.execute(
      "INSERT INTO manager_messages (role, content) VALUES (?1, ?2)",
      [message["role"], content]
    )

    %{state | conversation_messages: messages}
  end

  defp load_conversation_history do
    case KbaseBot.Repo.Store.query(
           "SELECT role, content FROM manager_messages ORDER BY id ASC LIMIT 100"
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [role, content] ->
          parsed_content =
            case Jason.decode(content) do
              {:ok, decoded} -> decoded
              {:error, _} -> content
            end

          %{"role" => role, "content" => parsed_content}
        end)

      _ ->
        []
    end
  end

  # --- Helpers ---

  defp day_of_week_name(1), do: "Segunda-feira"
  defp day_of_week_name(2), do: "Terca-feira"
  defp day_of_week_name(3), do: "Quarta-feira"
  defp day_of_week_name(4), do: "Quinta-feira"
  defp day_of_week_name(5), do: "Sexta-feira"
  defp day_of_week_name(6), do: "Sabado"
  defp day_of_week_name(7), do: "Domingo"
end
